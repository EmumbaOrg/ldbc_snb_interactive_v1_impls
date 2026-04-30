package org.ldbcouncil.snb.impls.workloads.age.operationhandlers;

import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.OperationHandler;
import org.ldbcouncil.snb.driver.ResultReporter;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcQuery13;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcQuery13Result;
import org.ldbcouncil.snb.impls.workloads.age.AgeDbConnectionState;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;

/**
 * Handler for IC13 using PL/pgSQL BFS function ldbc_snb_shortest_path().
 * The function must be installed via scripts/create-sp-functions.sql.
 */
public class AgeIC13OperationHandler implements OperationHandler<LdbcQuery13, AgeDbConnectionState> {

    @Override
    public void executeOperation(LdbcQuery13 operation, AgeDbConnectionState state,
                                 ResultReporter resultReporter) throws DbException {
        try {
            Connection conn = state.getConnection();
            String graphName = state.getGraphName();
            long person1Id = operation.getPerson1IdQ13StartNode();
            long person2Id = operation.getPerson2IdQ13EndNode();

            String query = String.format(
                "SELECT ldbc_snb_shortest_path('%s', %d, %d) AS shortestPathLength",
                graphName, person1Id, person2Id
            );

            synchronized (conn) {
                try (Statement stmt = conn.createStatement()) {
                    stmt.execute("SET search_path = ag_catalog, public");
                    ResultSet rs = stmt.executeQuery(query);
                    if (rs.next()) {
                        int pathLength = rs.getInt("shortestPathLength");
                        resultReporter.report(1, new LdbcQuery13Result(pathLength), operation);
                    } else {
                        resultReporter.report(1, new LdbcQuery13Result(-1), operation);
                    }
                }
            }
        } catch (Exception e) {
            throw new DbException(e);
        }
    }
}
