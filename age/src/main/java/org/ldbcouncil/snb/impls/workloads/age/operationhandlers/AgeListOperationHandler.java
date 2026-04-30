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
import java.util.Map;

/**
 * Executes a two-statement SQL file (SET search_path; SELECT ... FROM cypher(...))
 * and returns results as a list. Uses $$-aware splitting to find the statement boundary.
 */
public abstract class AgeListOperationHandler<TOperation extends Operation<List<TOperationResult>>, TOperationResult>
        implements ListOperationHandler<TOperationResult, TOperation, AgeDbConnectionState> {

    public abstract TOperationResult toResult(ResultSet rs) throws SQLException;

    public abstract Map<String, Object> getParameters(AgeDbConnectionState state, TOperation operation);

    @Override
    public void executeOperation(TOperation operation, AgeDbConnectionState state,
                                 ResultReporter resultReporter) throws DbException {
        String queryString = getQueryString(state, operation);

        // Apply parameter substitution
        Map<String, Object> params = getParameters(state, operation);
        if (params != null) {
            for (Map.Entry<String, Object> entry : params.entrySet()) {
                queryString = queryString.replace("$" + entry.getKey(), String.valueOf(entry.getValue()));
            }
        }

        Connection conn = state.getConnection();
        synchronized (conn) {
            try {
                String[] statements = splitStatements(queryString);
                List<TOperationResult> results = new ArrayList<>();

                try (Statement stmt = conn.createStatement()) {
                    // Execute SET search_path
                    if (statements.length > 1) {
                        stmt.execute(statements[0]);
                    }

                    // Execute the main query
                    String mainQuery = statements.length > 1 ? statements[1] : statements[0];
                    try (ResultSet rs = stmt.executeQuery(mainQuery)) {
                        while (rs.next()) {
                            results.add(toResult(rs));
                        }
                    }
                }

                resultReporter.report(results.size(), results, operation);
            } catch (Exception e) {
                throw new DbException(e);
            }
        }
    }

    /**
     * Split SQL into statements, respecting $$-quoted blocks.
     */
    protected static String[] splitStatements(String sql) {
        boolean inDollarQuote = false;
        int splitAt = -1;

        for (int i = 0; i < sql.length() - 1; i++) {
            if (sql.charAt(i) == '$' && sql.charAt(i + 1) == '$') {
                inDollarQuote = !inDollarQuote;
                i++; // skip second $
            } else if (sql.charAt(i) == ';' && !inDollarQuote) {
                splitAt = i;
                break;
            }
        }

        if (splitAt >= 0) {
            return new String[]{
                    sql.substring(0, splitAt + 1).trim(),
                    sql.substring(splitAt + 1).trim()
            };
        }
        return new String[]{sql.trim()};
    }
}
