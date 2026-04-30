package org.ldbcouncil.snb.impls.workloads.age.operationhandlers;

import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.Operation;
import org.ldbcouncil.snb.driver.ResultReporter;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcNoResult;
import org.ldbcouncil.snb.impls.workloads.age.AgeDbConnectionState;
import org.ldbcouncil.snb.impls.workloads.operationhandlers.UpdateOperationHandler;

import java.sql.Connection;
import java.sql.Statement;
import java.util.Map;

/**
 * Executes an update (IU) query with transaction management.
 */
public abstract class AgeUpdateOperationHandler<TOperation extends Operation<LdbcNoResult>>
        implements UpdateOperationHandler<TOperation, AgeDbConnectionState> {

    @Override
    public String getQueryString(AgeDbConnectionState state, TOperation operation) {
        return null;
    }

    public abstract Map<String, Object> getParameters(TOperation operation);

    @Override
    public void executeOperation(TOperation operation, AgeDbConnectionState state,
                                 ResultReporter resultReporter) throws DbException {
        String queryString = getQueryString(state, operation);

        Map<String, Object> params = getParameters(operation);
        if (params != null) {
            for (Map.Entry<String, Object> entry : params.entrySet()) {
                queryString = queryString.replace("$" + entry.getKey(), String.valueOf(entry.getValue()));
            }
        }

        Connection conn = state.getConnection();
        synchronized (conn) {
            try {
                conn.setAutoCommit(false);

                String[] statements = AgeListOperationHandler.splitStatements(queryString);
                try (Statement stmt = conn.createStatement()) {
                    if (statements.length > 1) {
                        stmt.execute(statements[0]);
                    }
                    String mainQuery = statements.length > 1 ? statements[1] : statements[0];
                    stmt.execute(mainQuery);
                }

                conn.commit();
                conn.setAutoCommit(true);
            } catch (Exception e) {
                try {
                    conn.rollback();
                    conn.setAutoCommit(true);
                } catch (Exception rollbackEx) {
                    // ignore rollback failure
                }
                throw new DbException(e);
            }
        }

        resultReporter.report(0, LdbcNoResult.INSTANCE, operation);
    }
}
