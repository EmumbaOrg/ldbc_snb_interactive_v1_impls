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
