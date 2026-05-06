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

    public AgeDbConnectionState(Map<String, String> properties, AgeQueryStore queryStore)
            throws DbException {
        super(properties, queryStore);

        String endpoint = properties.getOrDefault("age_endpoint", "localhost:5432/ldbc");
        String user = properties.getOrDefault("age_user", "postgres");
        String password = properties.getOrDefault("age_password", "");

        printQueryNames = Boolean.parseBoolean(properties.getOrDefault("printQueryNames", "false"));
        printQueryStrings = Boolean.parseBoolean(properties.getOrDefault("printQueryStrings", "false"));
        printQueryResults = Boolean.parseBoolean(properties.getOrDefault("printQueryResults", "false"));

        // Pool size matches thread_count so each worker gets its own connection.
        int threadCount = Integer.parseInt(properties.getOrDefault("thread_count", "1"));

        // Set search_path via JDBC options so it applies at connection startup,
        // not as a per-checkout round trip. %20 encodes the space; %3D encodes =.
        // jit=off: JIT compilation costs 50-500ms per query for our OLTP workload
        // (each unique SQL string triggers a cold JIT compile; savings never recoup cost).
        String jdbcUrl = "jdbc:postgresql://" + endpoint
                + "?options=-c%20search_path%3Dag_catalog%2Cpublic%20-c%20jit%3Doff";

        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        config.setUsername(user);
        config.setPassword(password);
        config.setMaximumPoolSize(threadCount);
        config.setMinimumIdle(threadCount);
        config.setAutoCommit(true);
        // LOAD 'age' is per-session and must run before any cypher() call.
        // connectionInitSql runs once per new physical connection.
        config.setConnectionInitSql("LOAD 'age'");
        config.setPoolName("age-ldbc");
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

    @Override
    public void close() throws IOException {
        dataSource.close();
    }
}
