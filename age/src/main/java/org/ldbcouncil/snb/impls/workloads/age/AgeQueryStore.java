package org.ldbcouncil.snb.impls.workloads.age;

import com.google.common.collect.ImmutableMap;
import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcQuery3;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcQuery4;
import org.ldbcouncil.snb.impls.workloads.QueryStore;
import org.ldbcouncil.snb.impls.workloads.converter.Converter;

import java.util.Calendar;
import java.util.Date;
import java.util.Map;
import java.util.TimeZone;

/**
 * Loads .sql query files for the AGE implementation.
 * Replaces $graphName placeholder at load time.
 */
public class AgeQueryStore extends QueryStore {

    public AgeQueryStore(String path, String graphName) throws DbException {
        super(path, ".sql");
        // Replace $graphName in all loaded queries
        for (var entry : queries.entrySet()) {
            if (entry.getValue() != null) {
                queries.put(entry.getKey(), entry.getValue().replace("$graphName", graphName));
            }
        }
    }

    @Override
    protected Converter getConverter() {
        return new AgeConverter();
    }

    private static Date addDays(Date startDate, int days) {
        final Calendar cal = Calendar.getInstance(TimeZone.getTimeZone("GMT"));
        cal.setTime(startDate);
        cal.add(Calendar.DATE, days);
        return cal.getTime();
    }

    @Override
    public Map<String, Object> getQuery3Map(LdbcQuery3 operation) {
        final Date endDate = addDays(operation.getStartDate(), operation.getDurationDays());
        return new ImmutableMap.Builder<String, Object>()
            .put(LdbcQuery3.PERSON_ID, getConverter().convertId(operation.getPersonIdQ3()))
            .put(LdbcQuery3.COUNTRY_X_NAME, getConverter().convertString(operation.getCountryXName()))
            .put(LdbcQuery3.COUNTRY_Y_NAME, getConverter().convertString(operation.getCountryYName()))
            .put(LdbcQuery3.START_DATE, getConverter().convertDate(operation.getStartDate()))
            .put("endDate", getConverter().convertDate(endDate))
            .put(LdbcQuery3.DURATION_DAYS, getConverter().convertInteger(operation.getDurationDays()))
            .build();
    }

    @Override
    public Map<String, Object> getQuery4Map(LdbcQuery4 operation) {
        final Date endDate = addDays(operation.getStartDate(), operation.getDurationDays());
        return new ImmutableMap.Builder<String, Object>()
            .put(LdbcQuery4.PERSON_ID, getConverter().convertId(operation.getPersonIdQ4()))
            .put(LdbcQuery4.START_DATE, getConverter().convertDate(operation.getStartDate()))
            .put("endDate", getConverter().convertDate(endDate))
            .put(LdbcQuery4.DURATION_DAYS, getConverter().convertInteger(operation.getDurationDays()))
            .build();
    }
}
