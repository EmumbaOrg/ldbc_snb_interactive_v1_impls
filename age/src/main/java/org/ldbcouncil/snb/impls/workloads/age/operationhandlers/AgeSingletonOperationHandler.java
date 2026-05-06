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

public abstract class AgeSingletonOperationHandler<TOperation extends Operation<TOperationResult>, TOperationResult>
        implements SingletonOperationHandler<TOperationResult, TOperation, AgeDbConnectionState> {

    protected abstract TOperationResult toResult(ResultSet row) throws SQLException;

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
}
