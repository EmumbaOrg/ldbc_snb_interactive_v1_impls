# Plan: Make AGE LDBC validation 10–15× faster

**Audience**: an AI agent (Sonnet 4.6 or similar) tasked with implementing the two performance fixes described below. The plan is opinionated about specific files, lines, and code shapes to remove ambiguity. Read the entire plan before writing any code.

**Out of scope**: query semantics, IC13/IC14 stubs, agefreighter migration. Do NOT change `.sql` query bodies or `AgeQueryStore.java` parameter substitution. Do NOT touch the `cypher/` directory.

---

## 1. Goals and success metrics

We currently observe **~0.86 ops/sec** on the validate_database run for SF0.1. The 138K-op full validation projects to ~38 hours; the 10K-op subset took 3h 25m. Observed: setting `thread_count=8` did not help — process spawned 28 JVM threads but PostgreSQL CPU stayed near 0.

After this change we expect:

| Metric | Current (thread_count=1) | Target (thread_count=8) |
|---|---|---|
| ops/sec | ~0.86 | **≥ 8** |
| 10K subset wall clock | 3h 25m | **≤ 25 min** |
| Full SF0.1 (138K ops) wall clock | ~38 hr | **≤ 5 hr** |
| Correctness vs current | — | **identical**: subset must report only IC13 (50% of `n`) and IC14 (50% of `n`) Incorrect, where `n` is the count of `personIdQ13/14` ops in the params file. **No new Incorrect operation types.** |

Both Change A (drop SET search_path) and Change B (HikariCP pool) are required to hit the target. Change A alone gives ~2×; Change B alone gives ~thread_count× IF Change A is also done (otherwise the `synchronized` block dominates).

---

## 2. Background — why it's slow

Three independent issues contribute, ranked by impact:

1. **Single shared connection + synchronized block.** `AgeDbConnectionState.java:23` holds one `Connection`. Every operation handler wraps its work in `synchronized (state.getConnection()) { ... }`. So `thread_count=N` runs N JVM threads but they all serialize on the same monitor. The class self-documents this limitation in lines 17–20:
   > *Thread safety note: a single JDBC connection is not thread-safe. For benchmarks with thread_count > 1 consider replacing this with a HikariCP connection pool (pool size = thread_count). See README for details.*
2. **Two round trips per query.** Every .sql file (27 of 29; IC13/IC14 are stub Java handlers) starts with `SET search_path = ag_catalog, public;`. `AgeListOperationHandler.executeTwoPartSql` splits at the first non-`$$` semicolon and calls `Statement.execute()` twice — once for the SET, once for the SELECT. The SET is already done at connection init (`AgeDbConnectionState.java:48`), so it's pure overhead.
3. **No prepared statement caching.** `AgeQueryStore.prepare()` substitutes `$personId`, `$maxDate`, etc. as text into the SQL template, so the resulting SQL string differs every call. PostgreSQL's plan cache keys on text. AGE re-parses the embedded Cypher and re-plans on every call. **Fixing this is out of scope for this plan** — it would require a much larger refactor of `AgeQueryStore` and reverification of every query against expected results. Mention only.

This plan addresses #1 and #2.

---

## 3. Change A — drop `SET search_path` from per-query SQL

### 3.1 What
Move the search-path setup out of every .sql file into the connection-init path that's already executing it once per connection. Then simplify the per-call execution to a single `Statement.execute()`.

### 3.2 Files to edit

#### 3.2.1 SQL files (27 files)
Run **once**, not per-file:
```bash
cd /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/queries
for f in *.sql; do
  # Remove the leading SET line + the blank line that follows (if present)
  awk 'NR==1 && /^SET search_path = ag_catalog, public;[[:space:]]*$/ {next}
       prev_skipped && NF==0 {prev_skipped=0; next}
       {prev_skipped=0; print}
       NR==1 && /^SET search_path = ag_catalog, public;[[:space:]]*$/ {prev_skipped=1}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
```

Then **verify**:
```bash
grep -l '^SET search_path' /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/queries/*.sql
# Expected: empty output (zero matches).

ls /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/queries/*.sql | wc -l
# Expected: 29 files (unchanged count).
```

If the awk above is too clever for the agent, the simpler equivalent is:
```bash
for f in /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/queries/*.sql; do
  sed -i '' '/^SET search_path = ag_catalog, public;$/d' "$f"
done
# On Linux drop the empty '' after -i.
```

The blank line that may follow the SET line is harmless to leave; do not over-engineer the cleanup.

#### 3.2.2 `AgeListOperationHandler.java`
Replace the body of `executeOperation` (lines 24–45) and remove the helper methods `executeTwoPartSql` and `findSplitPoint` (lines 51–73).

The new file should look like:
```java
package org.ldbcouncil.snb.impls.workloads.age.operationhandlers;

import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.Operation;
import org.ldbcouncil.snb.driver.ResultReporter;
import org.ldbcouncil.snb.impls.workloads.age.AgeDbConnectionState;
import org.ldbcouncil.snb.impls.workloads.operationhandlers.ListOperationHandler;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;

public abstract class AgeListOperationHandler<TOperation extends Operation<List<TOperationResult>>, TOperationResult>
        implements ListOperationHandler<TOperationResult, TOperation, AgeDbConnectionState> {

    protected abstract TOperationResult toResult(ResultSet row) throws SQLException;

    @Override
    public void executeOperation(TOperation operation, AgeDbConnectionState state,
                                 ResultReporter resultReporter) throws DbException {
        String sql = getQueryString(state, operation);
        state.logQuery(operation.getClass().getSimpleName(), sql);
        try (Connection conn = state.getConnection();
             Statement stmt = conn.createStatement()) {
            List<TOperationResult> results = new ArrayList<>();
            if (stmt.execute(sql)) {
                try (ResultSet rs = stmt.getResultSet()) {
                    while (rs.next()) {
                        results.add(toResult(rs));
                    }
                }
            }
            resultReporter.report(results.size(), results, operation);
        } catch (SQLException e) {
            throw new DbException(e);
        }
    }
}
```

Three substantive changes vs. the current file:
1. `state.getConnection()` is now wrapped in try-with-resources (Change B makes it pool-issued).
2. No `synchronized` (Change B makes it unnecessary).
3. `stmt.execute(sql)` returns a boolean — `true` if a ResultSet is available. Use it instead of unconditionally calling `getResultSet()`.

#### 3.2.3 `AgeSingletonOperationHandler.java`
Same pattern. The current body has the same two-part split and the same synchronized-on-connection wrapping. The shape after change (preserving the count + result semantics it already has):

```java
@Override
public void executeOperation(TOperation operation, AgeDbConnectionState state,
                             ResultReporter resultReporter) throws DbException {
    String sql = getQueryString(state, operation);
    state.logQuery(operation.getClass().getSimpleName(), sql);
    try (Connection conn = state.getConnection();
         Statement stmt = conn.createStatement()) {
        TOperationResult result = null;
        int count = 0;
        if (stmt.execute(sql)) {
            try (ResultSet rs = stmt.getResultSet()) {
                if (rs.next()) {
                    count = 1;
                    result = toResult(rs);
                }
            }
        }
        resultReporter.report(count, result, operation);
    } catch (SQLException e) {
        throw new DbException(e);
    }
}
```

Drop the `import` of `AgeListOperationHandler` (no longer needs `executeTwoPartSql`).

#### 3.2.4 `AgeUpdateOperationHandler.java`
Same pattern, but it has explicit transaction handling (`setAutoCommit(false)` / `commit()` / `rollback()`). Keep the transaction. The shape:

```java
@Override
public void executeOperation(TOperation operation, AgeDbConnectionState state,
                             ResultReporter resultReporter) throws DbException {
    String sql = getQueryString(state, operation);
    state.logQuery(operation.getClass().getSimpleName(), sql);
    try (Connection conn = state.getConnection()) {
        conn.setAutoCommit(false);
        try (Statement stmt = conn.createStatement()) {
            stmt.execute(sql);
            conn.commit();
        } catch (SQLException e) {
            conn.rollback();
            throw e;
        } finally {
            conn.setAutoCommit(true);
        }
        // Existing post-execute reporting behavior — preserve verbatim.
        // (Look at the current file for what to call here. Do not change the
        // public report() invocation pattern; only rewire it through the
        // pooled connection scope.)
    } catch (SQLException e) {
        throw new DbException(e);
    }
}
```

**Read the existing file in full before rewriting it** — there is post-update reporting (e.g. `LdbcNoResult.INSTANCE`) that must be preserved. The intent here is only to remove `synchronized` and switch to try-with-resources.

#### 3.2.5 IC13/IC14 handlers
`AgeIC13OperationHandler.java` and `AgeIC14OperationHandler.java` are the stubs that always return `-1` / `[]`. They likely don't open a Connection at all, but read them before deciding. If they do open one, apply the same pattern. If they synthesize results without DB I/O, leave them alone.

### 3.3 Edge cases / gotchas

- The two `.sql` files without `SET search_path` are `interactive-complex-13.sql` and `interactive-complex-14.sql` (stubs). Don't add SET to them; they aren't executed.
- The trailing semicolon at the end of every .sql file is harmless to PostgreSQL JDBC. Do not strip it.
- `Statement.execute()` with a multi-statement string is a no-op past the first statement in PostgreSQL JDBC by default. After Change A there is exactly one statement per file, so this doesn't matter, but if you ever re-introduce multi-statement files you'll need `setAutoSplit` or equivalent.

### 3.4 Done criteria for Change A

```bash
grep -l '^SET search_path' /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/queries/*.sql
# Expected: empty.

grep -rn 'executeTwoPartSql\|findSplitPoint' /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/src
# Expected: empty (helpers fully removed).

cd /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age && mvn -q clean package -DskipTests
# Expected: BUILD SUCCESS.
```

---

## 4. Change B — replace shared `Connection` with HikariCP pool

### 4.1 What
Replace the single `java.sql.Connection` field in `AgeDbConnectionState` with a `HikariDataSource`. Pool size matches `thread_count`. Each pooled connection is initialized with `LOAD 'age'` and `SET search_path = ag_catalog, public` via Hikari's `connectionInitSql`.

### 4.2 pom.xml

`age/pom.xml` currently has:
```xml
<dependencies>
    <dependency>
        <groupId>org.ldbcouncil.snb</groupId>
        <artifactId>common</artifactId>
        <version>1.2.0-SNAPSHOT</version>
    </dependency>
    <dependency>
        <groupId>org.postgresql</groupId>
        <artifactId>postgresql</artifactId>
        <version>42.7.3</version>
    </dependency>
</dependencies>
```

Add `HikariCP` after the postgresql dependency:
```xml
<dependency>
    <groupId>com.zaxxer</groupId>
    <artifactId>HikariCP</artifactId>
    <version>5.1.0</version>
</dependency>
```

`5.1.0` is the last version that supports Java 11 (project's `maven.compiler.source` is 11). Do NOT use 6.x (requires Java 17).

### 4.3 `AgeDbConnectionState.java`

Replace the entire file. The new file:

```java
package org.ldbcouncil.snb.impls.workloads.age;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.impls.workloads.BaseDbConnectionState;

import java.io.IOException;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.Map;

/**
 * Holds a HikariCP pool of JDBC connections to Apache AGE (PostgreSQL with the
 * AGE extension). Pool size is sized to the driver's thread_count so each
 * worker can run independently without lock contention.
 *
 * Each pooled connection is initialized once with `LOAD 'age'` and the
 * search_path is set via the JDBC URL's `options` parameter (so it survives
 * the connection's lifetime without a per-checkout round trip).
 */
public class AgeDbConnectionState extends BaseDbConnectionState<AgeQueryStore> {

    private final HikariDataSource dataSource;
    private final boolean printQueryNames;
    private final boolean printQueryStrings;
    private final boolean printQueryResults;

    public AgeDbConnectionState(Map<String, String> properties, AgeQueryStore queryStore)
            throws DbException {
        super(properties, queryStore);

        String endpoint = properties.getOrDefault("age_endpoint", "localhost:5432/ldbc");
        String user = properties.getOrDefault("age_user", "postgres");
        String password = properties.getOrDefault("age_password", "");

        printQueryNames = Boolean.parseBoolean(properties.getOrDefault("printQueryNames", "false"));
        printQueryStrings = Boolean.parseBoolean(properties.getOrDefault("printQueryStrings", "false"));
        printQueryResults = Boolean.parseBoolean(properties.getOrDefault("printQueryResults", "false"));

        // thread_count is what the LDBC driver uses for worker threads. Match
        // pool size to it so we never block on connection acquisition.
        int threadCount = Integer.parseInt(properties.getOrDefault("thread_count", "1"));

        // Set search_path via JDBC `options` so it's part of the startup packet
        // and applies for the connection's lifetime — no per-checkout round trip.
        // %20 is required: the value is parsed as a single shell-style token.
        String jdbcUrl = "jdbc:postgresql://" + endpoint + "?options=-c%20search_path%3Dag_catalog%2Cpublic";

        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        config.setUsername(user);
        config.setPassword(password);
        config.setMaximumPoolSize(threadCount);
        config.setMinimumIdle(threadCount);
        config.setAutoCommit(true);
        // LOAD 'age' is per-session and must run before any cypher() call.
        // Hikari's connectionInitSql runs once per new physical connection.
        config.setConnectionInitSql("LOAD 'age'");
        config.setPoolName("age-ldbc");
        // Tight timeouts — fail fast if the DB is wedged rather than masking
        // the issue.
        config.setConnectionTimeout(30_000);
        config.setValidationTimeout(5_000);

        try {
            Class.forName("org.postgresql.Driver");
            this.dataSource = new HikariDataSource(config);
        } catch (ClassNotFoundException e) {
            throw new DbException(e);
        }
    }

    /**
     * Borrow a connection from the pool. The caller must close it
     * (try-with-resources) to return it to the pool.
     */
    public Connection getConnection() throws SQLException {
        return dataSource.getConnection();
    }

    public boolean isPrintQueryNames() { return printQueryNames; }
    public boolean isPrintQueryStrings() { return printQueryStrings; }
    public boolean isPrintQueryResults() { return printQueryResults; }

    public void logQuery(String operationName, String queryString) {
        if (printQueryNames) System.out.println("[AGE] " + operationName);
        if (printQueryStrings) System.out.println("[AGE] " + queryString);
    }

    @Override
    public void close() throws IOException {
        dataSource.close();
    }
}
```

### 4.4 Operation handlers (already updated in Change A)

After Change A, the handlers do `try (Connection conn = state.getConnection(); ...)`. The `getConnection()` signature changes from "returns the shared connection" to "throws SQLException, returns a pooled connection". The try-with-resources auto-closes (returning to pool) on success and on exception.

The handlers' `try` block in Change A's spec needs to wrap the `getConnection()` call in the same `try`:

```java
try (Connection conn = state.getConnection();
     Statement stmt = conn.createStatement()) {
    ...
} catch (SQLException e) {
    throw new DbException(e);
}
```

The catch already covers any `SQLException` thrown from `getConnection()`. Good.

### 4.5 Edge cases / gotchas

- `connectionInitSql` runs once when Hikari opens a new physical connection. Idle connections in the pool keep the init applied. No need to re-issue `LOAD 'age'` on every checkout.
- The JDBC `options` query parameter encodes a space as `%20` and an `=` as `%3D`. Get this wrong and the URL parses but the option is silently ignored — `search_path` defaults to `"$user", public` and AGE label tables aren't found. **Verify by querying `current_setting('search_path')` against a freshly checked-out connection**.
- Setting `minimumIdle = maximumPoolSize` keeps connections warm so the first 8 queries don't pay the connection-establishment cost. For `thread_count=1` this is a 1-connection pool, identical behavior to the current single-connection model except via Hikari indirection.
- The driver's `thread_count` property is the source of truth. Do NOT introduce a separate `age_pool_size` property — that's a footgun (mismatch leads to either contention or wasted connections).
- Update operations explicitly use transactions (autoCommit=false). With pooled connections, ensure `setAutoCommit(true)` is restored before the connection returns to the pool. Use `finally` (already in the existing code).

### 4.6 Done criteria for Change B

```bash
grep -rn 'synchronized.*getConnection\|synchronized\s*(\s*conn\s*)' \
  /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/src
# Expected: empty.

grep -rn 'HikariDataSource' /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/src
# Expected: at least one match in AgeDbConnectionState.java.

cd /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age && mvn -q clean package -DskipTests
# Expected: BUILD SUCCESS.

# After build, sanity-check that search_path is applied:
java -Xmx2g -cp target/age-1.2.0-SNAPSHOT.jar -e \
  '...' # alternative: write a tiny Main that opens AgeDbConnectionState,
        # checks SELECT current_setting('search_path') from a pooled connection.
```

If the agent does not want to write a tiny Main, run validation against the 2K subset (§5.3) — it will fail loudly if `search_path` isn't applied.

---

## 5. Implementation order, testing, and rollback

### 5.1 Order
1. **Change A only** first (SQL files + handler simplification). Build. Test correctness against the 2K subset. This isolates the SET-removal blast radius.
2. **Change B** next (pom + AgeDbConnectionState rewrite + handler getConnection wrapping). Build. Test correctness against 2K subset. Then test perf at thread_count=8.

If you do them together and something breaks, you don't know which change caused it. Sequential is non-negotiable.

### 5.2 Restore the snapshot before EACH test run
The validation driver mutates the DB via Update operations. Re-running on top of a previous run causes duplicate Comments/Memberships/KNOWS edges and produces false-positive failures. The README "Snapshot and Restore" section warns about this; comply.

```bash
CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres" \
  bash /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/scripts/restore-database.sh
```

### 5.3 Correctness test (after Change A and after Change B)

Both validation runs should produce identical "Incorrect results" counts: only IC13 and IC14, both equal to the number of `personIdQ13/Q14*` ops in the params file.

```bash
cd /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age

# Use the 2K subset for fast iteration (~30 min on current code).
sed -i.bak 's|^validate_database=.*|validate_database=/tmp/ldbc_sf01/validation_params-sf0.1-subset.csv|' \
  driver/validate.properties

# (after each change) restore + run + diagnose
bash scripts/restore-database.sh
rm -f /tmp/ldbc_sf01/validation_params-sf0.1-subset-failed-actual.json
rm -f /tmp/ldbc_sf01/validation_params-sf0.1-subset-failed-expected.json
java -Xmx8g -cp target/age-1.2.0-SNAPSHOT.jar org.ldbcouncil.snb.driver.Client -P driver/validate.properties

python3 scripts/diagnose-failures.py \
  /tmp/ldbc_sf01/validation_params-sf0.1-subset-failed-actual.json \
  /tmp/ldbc_sf01/validation_params-sf0.1-subset-failed-expected.json
```

**Pass criterion**: the `Per-query diagnosis` output shows only `Q13` and `Q14`. Any other query type with non-zero failures is a regression caused by your change. Stop and debug before continuing.

### 5.4 Performance test (after Change B only)

```bash
# Confirm thread_count is set in validate.properties
grep '^thread_count' driver/validate.properties

# Bump to 8 for the perf test
sed -i.bak 's|^thread_count=.*|thread_count=8|' driver/validate.properties

# Restore + run a 2K subset and time it
bash scripts/restore-database.sh
time java -Xmx8g -cp target/age-1.2.0-SNAPSHOT.jar \
  org.ldbcouncil.snb.driver.Client -P driver/validate.properties

# While running, in another terminal:
# - `top -pid $(pgrep -f validate.properties)` should show JVM CPU > 100% (using multiple cores).
# - `ps -M $(pgrep -f validate.properties) | wc -l` should report ~30+ threads.
# - In psql: `SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '%age-ldbc%';`
#   should be ~8 (matches pool size).
```

**Pass criterion**: 2K subset completes in **≤ 5 minutes** at thread_count=8. (Was 30 min at thread_count=1.) If it's still ~30 min, either the synchronized block wasn't fully removed, the pool isn't sized correctly, or PostgreSQL is the bottleneck (unlikely at SF0.1 with only 8 connections).

### 5.5 Rollback
```bash
cd /Users/waleed/repositories/ldbc_snb_interactive_v1_impls
git diff age/                                      # review all changes
git checkout -- age/queries age/src age/pom.xml    # revert if broken
```

### 5.6 Restore validate.properties
After all testing, restore to the 138K full file and thread_count appropriate for the target environment. Don't commit the subset path or thread_count=8 in `driver/validate.properties`; those are test-time overrides.

```bash
sed -i 's|^validate_database=.*|validate_database=/tmp/ldbc_sf01/validation_params-sf0.1.csv|' \
  driver/validate.properties
sed -i 's|^thread_count=.*|thread_count=1|' driver/validate.properties
```

(`thread_count=1` is the safe committed default. Operators bump it locally if their PostgreSQL has the capacity.)

---

## 6. What this plan does NOT do

- Does not introduce prepared-statement caching. That's a much larger refactor of `AgeQueryStore` (substituting `?` placeholders + maintaining a parallel parameter list per query) and would change every operation handler. If after Changes A+B the rate is still under target, that's the next lever — but it's a separate plan, separate review.
- Does not tune PostgreSQL config (shared_buffers, effective_cache_size, JIT). That's a host-level concern; this plan stays inside the JVM client.
- Does not touch IC13/IC14 stubs.
- Does not change query semantics. Every .sql file edit is a single-line deletion of `SET search_path = ag_catalog, public;`. The query body is byte-for-byte identical otherwise.
- Does not change the LDBC driver itself — only the AGE-specific implementation in `age/src/main/java/org/ldbcouncil/snb/impls/workloads/age/`.

---

## 7. Self-review checklist for the implementing agent

Before declaring done, confirm every line of the following is true. If any is false, the work is incomplete.

- [ ] `grep -l '^SET search_path' age/queries/*.sql` returns no matches.
- [ ] `grep -rn 'executeTwoPartSql\|findSplitPoint' age/src` returns no matches.
- [ ] `grep -rn 'synchronized.*getConnection\|synchronized\s*(\s*conn' age/src` returns no matches.
- [ ] `grep -rn 'HikariDataSource' age/src` returns at least one match.
- [ ] `mvn -q clean package -DskipTests` succeeds.
- [ ] After restore-database, 2K-subset validation at thread_count=1 reports only Q13 and Q14 in the diagnose output. No other query types with non-zero failures.
- [ ] After restore-database, 2K-subset validation at thread_count=8 also reports only Q13 and Q14. No other query types. (If new failure types appear at thread_count=8 but not at thread_count=1, you have a thread-safety bug — likely a shared mutable state somewhere, or `Class.forName` race, or `setAutoCommit` leakage between borrows.)
- [ ] thread_count=8 wall clock for 2K subset is ≤ 5 minutes.
- [ ] `driver/validate.properties` is restored to `validate_database=/tmp/ldbc_sf01/validation_params-sf0.1.csv` and `thread_count=1` after testing.
- [ ] No additions to `age_endpoint/age_user/age_password` placeholders — they remain `<HORIZON_HOST>` etc.

If all check, the change is ready for review.

---

## 8. Review handoff

When implementation is complete, the reviewer (Opus 4.7) will verify:
1. Correctness of the file edits (against this plan §3 and §4).
2. The `synchronized` blocks are gone in *every* operation handler, not just the three explicitly listed (re-grep the whole `age/src` tree).
3. `connectionInitSql` is `LOAD 'age'` only, and `search_path` is in the JDBC URL (not also in init SQL).
4. The 2K-subset diagnose output matches the pre-change baseline (only Q13 + Q14 incorrect).
5. The 2K-subset wall clock at thread_count=8 is meaningfully faster than at thread_count=1 (factor ≥ 5).
6. `driver/validate.properties` is back to committable defaults.

If review fails, the implementing agent fixes and re-tests before re-handoff.
