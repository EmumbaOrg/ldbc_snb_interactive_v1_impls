package org.ldbcouncil.snb.impls.workloads.age.operationhandlers;

import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.Operation;
import org.ldbcouncil.snb.driver.ResultReporter;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcNoResult;
import org.ldbcouncil.snb.impls.workloads.age.AgeAgtypeJson;
import org.ldbcouncil.snb.impls.workloads.age.AgeDbConnectionState;
import org.ldbcouncil.snb.impls.workloads.operationhandlers.UpdateOperationHandler;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Map;

public abstract class AgeUpdateOperationHandler<TOperation extends Operation<LdbcNoResult>>
        implements UpdateOperationHandler<TOperation, AgeDbConnectionState> {

    protected String getQueryTemplate(AgeDbConnectionState state, TOperation operation) {
        throw new UnsupportedOperationException("getQueryTemplate not implemented for " + getClass().getSimpleName());
    }

    protected Map<String, Object> getQueryParameterMap(AgeDbConnectionState state, TOperation operation) {
        throw new UnsupportedOperationException("getQueryParameterMap not implemented for " + getClass().getSimpleName());
    }

    @Override
    public void executeOperation(TOperation operation, AgeDbConnectionState state,
                                 ResultReporter resultReporter) throws DbException {
        String opName = operation.getClass().getSimpleName();
        boolean parameterized = state.isParameterized(opName);

        try (Connection conn = state.getConnection()) {
            conn.setAutoCommit(false);
            try {
                if (parameterized) {
                    String sqlTemplate = getQueryTemplate(state, operation);
                    Map<String, Object> bindMap = getQueryParameterMap(state, operation);
                    String agtypeJson = AgeAgtypeJson.mapOf(bindMap);
                    state.logQuery(opName, sqlTemplate);
                    try (PreparedStatement ps = conn.prepareStatement(sqlTemplate)) {
                        int placeholderCount = countCypherCalls(sqlTemplate);
                        for (int i = 1; i <= placeholderCount; i++) {
                            ps.setObject(i, agtypeJson, java.sql.Types.OTHER);
                        }
                        ps.execute();
                    }
                } else {
                    String sql = getQueryString(state, operation);
                    state.logQuery(opName, sql);
                    try (Statement stmt = conn.createStatement()) {
                        stmt.execute(sql);
                    }
                }
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

    private static int countCypherCalls(String sql) {
        int n = 0;
        int idx = 0;
        while ((idx = sql.indexOf("cypher(", idx)) != -1) { n++; idx += 7; }
        return n;
    }
}
