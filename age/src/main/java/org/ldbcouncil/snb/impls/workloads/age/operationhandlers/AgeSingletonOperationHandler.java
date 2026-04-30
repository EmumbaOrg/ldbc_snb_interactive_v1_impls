package org.ldbcouncil.snb.impls.workloads.age.operationhandlers;

import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.Operation;
import org.ldbcouncil.snb.driver.ResultReporter;
import org.ldbcouncil.snb.impls.workloads.age.AgeDbConnectionState;
import org.ldbcouncil.snb.impls.workloads.operationhandlers.SingletonOperationHandler;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Map;

/**
 * Executes a query returning a single result row.
 * If no rows returned, reports (0, null).
 */
public abstract class AgeSingletonOperationHandler<TOperation extends Operation<TOperationResult>, TOperationResult>
        implements SingletonOperationHandler<TOperationResult, TOperation, AgeDbConnectionState> {

    public abstract TOperationResult toResult(ResultSet rs) throws SQLException;

    public abstract Map<String, Object> getParameters(AgeDbConnectionState state, TOperation operation);

    @Override
    public void executeOperation(TOperation operation, AgeDbConnectionState state,
                                 ResultReporter resultReporter) throws DbException {
        String queryString = getQueryString(state, operation);

        Map<String, Object> params = getParameters(state, operation);
        if (params != null) {
            for (Map.Entry<String, Object> entry : params.entrySet()) {
                queryString = queryString.replace("$" + entry.getKey(), String.valueOf(entry.getValue()));
            }
        }

        Connection conn = state.getConnection();
        synchronized (conn) {
            try {
                String[] statements = AgeListOperationHandler.splitStatements(queryString);

                try (Statement stmt = conn.createStatement()) {
                    if (statements.length > 1) {
                        stmt.execute(statements[0]);
                    }

                    String mainQuery = statements.length > 1 ? statements[1] : statements[0];
                    try (ResultSet rs = stmt.executeQuery(mainQuery)) {
                        if (rs.next()) {
                            resultReporter.report(1, toResult(rs), operation);
                        } else {
                            resultReporter.report(0, null, operation);
                        }
                    }
                }
            } catch (Exception e) {
                throw new DbException(e);
            }
        }
    }
}
