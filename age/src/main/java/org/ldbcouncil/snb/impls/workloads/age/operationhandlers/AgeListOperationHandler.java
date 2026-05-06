package org.ldbcouncil.snb.impls.workloads.age.operationhandlers;

import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.Operation;
import org.ldbcouncil.snb.driver.ResultReporter;
import org.ldbcouncil.snb.impls.workloads.age.AgeAgtypeJson;
import org.ldbcouncil.snb.impls.workloads.age.AgeDbConnectionState;
import org.ldbcouncil.snb.impls.workloads.operationhandlers.ListOperationHandler;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public abstract class AgeListOperationHandler<TOperation extends Operation<List<TOperationResult>>, TOperationResult>
        implements ListOperationHandler<TOperationResult, TOperation, AgeDbConnectionState> {

    protected abstract TOperationResult toResult(ResultSet row) throws SQLException;

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
            List<TOperationResult> results = new ArrayList<>();
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
                    if (ps.execute()) {
                        try (ResultSet rs = ps.getResultSet()) {
                            while (rs.next()) results.add(toResult(rs));
                        }
                    }
                }
            } else {
                String sql = getQueryString(state, operation);
                state.logQuery(opName, sql);
                try (Statement stmt = conn.createStatement()) {
                    if (stmt.execute(sql)) {
                        try (ResultSet rs = stmt.getResultSet()) {
                            while (rs.next()) results.add(toResult(rs));
                        }
                    }
                }
            }
            resultReporter.report(results.size(), results, operation);
        } catch (SQLException e) {
            throw new DbException(e);
        }
    }

    private static int countCypherCalls(String sql) {
        int n = 0;
        int idx = 0;
        while ((idx = sql.indexOf("cypher(", idx)) != -1) { n++; idx += 7; }
        return n;
    }
}
