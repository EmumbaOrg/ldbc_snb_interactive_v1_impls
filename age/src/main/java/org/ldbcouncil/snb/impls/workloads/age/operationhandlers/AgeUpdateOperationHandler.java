package org.ldbcouncil.snb.impls.workloads.age.operationhandlers;

import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.Operation;
import org.ldbcouncil.snb.driver.ResultReporter;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcNoResult;
import org.ldbcouncil.snb.impls.workloads.age.AgeDbConnectionState;
import org.ldbcouncil.snb.impls.workloads.operationhandlers.UpdateOperationHandler;

import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;

public abstract class AgeUpdateOperationHandler<TOperation extends Operation<LdbcNoResult>>
        implements UpdateOperationHandler<TOperation, AgeDbConnectionState> {

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
        } catch (SQLException e) {
            throw new DbException(e);
        }
        resultReporter.report(0, LdbcNoResult.INSTANCE, operation);
    }
}
