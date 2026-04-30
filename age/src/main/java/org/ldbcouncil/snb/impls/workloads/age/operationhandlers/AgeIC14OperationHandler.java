package org.ldbcouncil.snb.impls.workloads.age.operationhandlers;

import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.OperationHandler;
import org.ldbcouncil.snb.driver.ResultReporter;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcQuery14;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcQuery14Result;
import org.ldbcouncil.snb.impls.workloads.age.AgeDbConnectionState;

import java.util.Collections;

/**
 * Degraded handler for IC14. AGE does not support allShortestPaths().
 * Always returns an empty list.
 */
public class AgeIC14OperationHandler implements OperationHandler<LdbcQuery14, AgeDbConnectionState> {

    @Override
    public void executeOperation(LdbcQuery14 operation, AgeDbConnectionState state,
                                 ResultReporter resultReporter) throws DbException {
        resultReporter.report(0, Collections.<LdbcQuery14Result>emptyList(), operation);
    }
}
