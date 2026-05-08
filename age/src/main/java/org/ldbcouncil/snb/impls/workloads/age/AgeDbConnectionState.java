package org.ldbcouncil.snb.impls.workloads.age;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.impls.workloads.BaseDbConnectionState;

import java.io.IOException;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * Holds a HikariCP pool of JDBC connections to Apache AGE (PostgreSQL with the
 * AGE extension). Pool size matches the driver's thread_count so each worker
 * can run independently without lock contention.
 *
 * Each pooled connection is initialized once with LOAD 'age'. The search_path
 * is set via the JDBC URL's options parameter so it applies for the connection's
 * lifetime without a per-checkout round trip.
 */
public class AgeDbConnectionState extends BaseDbConnectionState<AgeQueryStore> {

    private final HikariDataSource dataSource;
    private final boolean printQueryNames;
    private final boolean printQueryStrings;
    private final boolean printQueryResults;
    private final Set<String> parameterizedQueryTypes;

    public AgeDbConnectionState(Map<String, String> properties, AgeQueryStore queryStore)
            throws DbException {
        super(properties, queryStore);

        String endpoint = properties.getOrDefault("age_endpoint", "localhost:5432/ldbc");
        String user = properties.getOrDefault("age_user", "postgres");
        String password = properties.getOrDefault("age_password", "");

        printQueryNames = Boolean.parseBoolean(properties.getOrDefault("printQueryNames", "false"));
        printQueryStrings = Boolean.parseBoolean(properties.getOrDefault("printQueryStrings", "false"));
        printQueryResults = Boolean.parseBoolean(properties.getOrDefault("printQueryResults", "false"));

        String csv = properties.getOrDefault("age_parameterized_queries", "");
        this.parameterizedQueryTypes = csv.isEmpty()
            ? Collections.emptySet()
            : new HashSet<>(Arrays.asList(csv.split("\\s*,\\s*")));

        // Pool size: prefer the explicit user-defined `age_connection_pool_size`,
        // then fall back to `thread_count` if propagated by the LDBC framework,
        // else 16. The LDBC SNB driver consumes `thread_count` as a framework-level
        // parameter and does NOT include it in the user-defined params map passed
        // to BaseDbConnectionState — defaulting to "1" silently here crippled prior
        // runs (Hikari pool of 1 with 4 worker threads → starvation).
        String declaredThreadCount = properties.get("thread_count");
        int poolSize = Integer.parseInt(
            properties.getOrDefault("age_connection_pool_size",
                declaredThreadCount != null ? declaredThreadCount : "16"));

        // Sanity check: the pool should equal thread_count. A pool smaller than
        // thread_count starves workers; a pool larger than thread_count wastes
        // server-side memory. We can only verify this when thread_count is
        // visible in the user-params map (rare; see comment above).
        if (declaredThreadCount != null) {
            try {
                int tc = Integer.parseInt(declaredThreadCount);
                if (tc != poolSize) {
                    System.err.println("[AGE] WARNING: age_connection_pool_size=" + poolSize
                            + " differs from thread_count=" + tc
                            + ". For best throughput these should be equal: pool < threads"
                            + " causes connection starvation, pool > threads wastes memory.");
                }
            } catch (NumberFormatException ignored) { /* malformed — skip check */ }
        } else {
            System.out.println("[AGE] NOTE: thread_count not propagated to user-params"
                    + " (LDBC framework strips it). Cannot auto-verify alignment with"
                    + " age_connection_pool_size=" + poolSize
                    + ". Ensure benchmark.properties has thread_count="
                    + poolSize + " for matched concurrency.");
        }

        long connectionTimeoutMs = Long.parseLong(
            properties.getOrDefault("age_connection_timeout_ms", "30000"));
        long keepaliveMs = Long.parseLong(
            properties.getOrDefault("age_keepalive_ms", "30000"));
        long maxLifetimeMs = Long.parseLong(
            properties.getOrDefault("age_max_lifetime_ms", "1800000"));

        // Set search_path via JDBC options so it applies at connection startup,
        // not as a per-checkout round trip. %20 encodes the space; %3D encodes =.
        // jit=off: JIT compilation costs 50-500ms per query for our OLTP workload
        // (each unique SQL string triggers a cold JIT compile; savings never recoup cost).
        // tcpKeepAlive=true asks the OS to probe idle connections so cloud
        // firewalls (Azure, AWS) don't silently drop them mid-benchmark.
        String jdbcUrl = "jdbc:postgresql://" + endpoint
                + "?options=-c%20search_path%3Dag_catalog%2Cpublic%20-c%20jit%3Doff"
                + "&prepareThreshold=1"
                + "&preparedStatementCacheQueries=64"
                + "&preparedStatementCacheSizeMiB=10"
                + "&tcpKeepAlive=true";

        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        config.setUsername(user);
        config.setPassword(password);
        config.setMaximumPoolSize(poolSize);
        config.setMinimumIdle(poolSize);
        config.setAutoCommit(true);
        // LOAD 'age' is per-session and must run before any cypher() call.
        // connectionInitSql runs once per new physical connection.
        // config.setConnectionInitSql("LOAD 'age'");
        config.setPoolName("age-ldbc");
        config.setConnectionTimeout(connectionTimeoutMs);
        config.setValidationTimeout(5_000);
        // keepaliveTime: HikariCP probes idle connections. Catches cloud-firewall
        // idle drops (typical 4–30 min) before the benchmark blocks on a dead one.
        config.setKeepaliveTime(keepaliveMs);
        // maxLifetime: recycle connections every 30 min to stay under Azure /
        // managed-Postgres idle-disconnect thresholds. Must be < server timeout.
        config.setMaxLifetime(maxLifetimeMs);

        try {
            Class.forName("org.postgresql.Driver");
            this.dataSource = new HikariDataSource(config);
            System.out.println("[AGE] Hikari pool: poolSize=" + poolSize
                    + ", connectionTimeoutMs=" + connectionTimeoutMs
                    + ", keepaliveMs=" + keepaliveMs
                    + ", maxLifetimeMs=" + maxLifetimeMs);
        } catch (ClassNotFoundException e) {
            throw new DbException(e);
        }
    }

    /**
     * Borrow a connection from the pool. Caller must close it (try-with-resources)
     * to return it to the pool.
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

    public boolean isParameterized(String operationSimpleName) {
        // operationSimpleName is e.g. "LdbcQuery1"; the property uses "Query1".
        String stripped = operationSimpleName.startsWith("Ldbc")
            ? operationSimpleName.substring(4)
            : operationSimpleName;
        return parameterizedQueryTypes.contains(stripped);
    }

    @Override
    public void close() throws IOException {
        dataSource.close();
    }
}
