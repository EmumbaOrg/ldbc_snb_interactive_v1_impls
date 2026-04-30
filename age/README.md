# LDBC SNB Interactive v1 — Apache AGE Implementation

## Overview

This module implements the LDBC SNB Interactive v1 benchmark for [Apache AGE](https://age.apache.org/),
a graph extension for PostgreSQL. It provides all 29 operation handlers required by the LDBC driver,
with IC13 and IC14 operating in degraded mode due to AGE's lack of `shortestPath()` / `allShortestPaths()`.

## Build

Prerequisites:
- JDK 11+ (compiles to Java 11 bytecode)
- Maven 3.6+

```bash
cd ldbc_snb_interactive_v1_impls
mvn install -pl common -am -DskipTests
cd age
mvn clean package -DskipTests
```

This produces `age/target/age-1.2.0-SNAPSHOT.jar`.

## Data Loading

Data loading uses agefreighter (outside LDBC standard):

```bash
bash scripts/load-data.sh --sf 0.1
```

See `scripts/load-data.sh` for details. After loading, indexes are created and VACUUM ANALYZE is run.

## Validation

```bash
java -cp target/age-1.2.0-SNAPSHOT.jar org.ldbcouncil.snb.driver.Client \
  -db org.ldbcouncil.snb.impls.workloads.age.interactive.AgeInteractiveDb \
  -w  org.ldbcouncil.snb.impls.workloads.interactive.LdbcSnbInteractiveWorkload \
  -vdb test-data/validation_params.csv \
  -P  driver/validate.properties
```

**Note**: IC13 and IC14 are disabled in `validate.properties` because AGE cannot compute shortest paths.

## Benchmark

```bash
java -cp target/age-1.2.0-SNAPSHOT.jar org.ldbcouncil.snb.driver.Client \
  -db org.ldbcouncil.snb.impls.workloads.age.interactive.AgeInteractiveDb \
  -w  org.ldbcouncil.snb.impls.workloads.interactive.LdbcSnbInteractiveWorkload \
  -P  driver/benchmark.properties
```

## Configuration

Edit `driver/benchmark.properties` or `driver/validate.properties`:

| Property | Description |
|---|---|
| `age_endpoint` | JDBC connection string (e.g., `localhost:5432/ldbcsnb`) |
| `age_user` | PostgreSQL user |
| `age_password` | PostgreSQL password |
| `age_graph_name` | AGE graph name (default: `ldbc_snb`) |
| `queryDir` | Path to query SQL files |
| `thread_count` | Number of worker threads |

## Known Limitations

### IC13 — Single Shortest Path
AGE does not support `shortestPath()`. The handler returns `-1` (LDBC sentinel for "no path exists").

### IC14 — Trusted Connection Paths
AGE does not support `allShortestPaths()`. The handler returns an empty list.

Both are registered as proper operation handlers (not `NotImplementedOperationHandler`) and are
spec-compliant in degraded mode. Disable in validation via `LdbcQuery13.enable=false` and
`LdbcQuery14.enable=false`.

### Organisation Locations
Company and University vertices carry a `placeName` property (denormalized from
`organisation_isLocatedIn_place`). IC11 filters via `company.placeName` instead of traversing
`IS_LOCATED_IN` edges.

### Thread Safety
The single JDBC connection is synchronized. For production benchmarks with `thread_count > 1`,
consider adding HikariCP connection pooling.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/load-data.sh` | Preprocess + agefreighter load + indexes + VACUUM |
| `scripts/create-indexes.sql` | B-tree indexes on vertex id + edge start_id/end_id |
| `scripts/vacuum-analyze.sh` | VACUUM ANALYZE after load or restore |
| `scripts/snapshot-database.sh` | pg_dump before IU benchmark runs |
| `scripts/restore-database.sh` | pg_restore + VACUUM ANALYZE to reset state |

## Project Structure

```
age/
├── pom.xml
├── README.md
├── driver/
│   ├── benchmark.properties
│   └── validate.properties
├── queries/
│   ├── interactive-complex-1.sql … interactive-complex-14.sql
│   ├── interactive-short-1.sql … interactive-short-7.sql
│   └── interactive-update-1.sql … interactive-update-8.sql
├── scripts/
│   ├── load-data.sh
│   ├── create-indexes.sql
│   ├── vacuum-analyze.sh
│   ├── snapshot-database.sh
│   └── restore-database.sh
├── src/main/java/org/ldbcouncil/snb/impls/workloads/age/
│   ├── AgeDb.java
│   ├── AgeDbConnectionState.java
│   ├── AgeQueryStore.java
│   ├── AgeConverter.java
│   ├── interactive/
│   │   └── AgeInteractiveDb.java
│   └── operationhandlers/
│       ├── AgeListOperationHandler.java
│       ├── AgeSingletonOperationHandler.java
│       ├── AgeUpdateOperationHandler.java
│       ├── AgeIC13OperationHandler.java
│       └── AgeIC14OperationHandler.java
└── test-data/
    └── validation_params.csv (obtain from LDBC)
```
