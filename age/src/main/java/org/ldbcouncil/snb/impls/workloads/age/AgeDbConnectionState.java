package org.ldbcouncil.snb.impls.workloads.age;

import org.ldbcouncil.snb.impls.workloads.BaseDbConnectionState;

import java.io.IOException;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Map;

/**
 * Holds a single JDBC Connection to a PostgreSQL instance with the AGE extension.
 * On construction, runs LOAD 'age' and SET search_path for the session.
 */
public class AgeDbConnectionState extends BaseDbConnectionState<AgeQueryStore> {

    private final Connection connection;
    private final String graphName;

    public AgeDbConnectionState(Map<String, String> properties, AgeQueryStore queryStore) {
        super(properties, queryStore);

        String endpoint = properties.get("age_endpoint");
        String user = properties.get("age_user");
        String password = properties.get("age_password");
        this.graphName = properties.get("age_graph_name");

        if (endpoint == null || endpoint.isEmpty()) {
            throw new RuntimeException("age_endpoint property is required");
        }

        String jdbcUrl = endpoint.startsWith("jdbc:") ? endpoint : "jdbc:postgresql://" + endpoint;

        try {
            Class.forName("org.postgresql.Driver");
            this.connection = DriverManager.getConnection(jdbcUrl, user, password);

            // Initialize AGE session
            try (Statement stmt = connection.createStatement()) {
                stmt.execute("LOAD 'age'");
                stmt.execute("SET search_path = ag_catalog, public");
            }
        } catch (ClassNotFoundException | SQLException e) {
            throw new RuntimeException("Failed to initialize AGE connection", e);
        }
    }

    public Connection getConnection() {
        return connection;
    }

    public String getGraphName() {
        return graphName;
    }

    @Override
    public void close() throws IOException {
        try {
            if (connection != null && !connection.isClosed()) {
                connection.close();
            }
        } catch (SQLException e) {
            throw new IOException("Failed to close AGE connection", e);
        }
    }
}
