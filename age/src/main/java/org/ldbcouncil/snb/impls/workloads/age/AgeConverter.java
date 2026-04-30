package org.ldbcouncil.snb.impls.workloads.age;

import org.ldbcouncil.snb.driver.workloads.interactive.LdbcQuery1Result;
import org.ldbcouncil.snb.driver.workloads.interactive.LdbcUpdate1AddPerson;
import org.ldbcouncil.snb.impls.workloads.converter.Converter;

import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;

/**
 * Handles both read (agtype → Java) and write (Java → agtype JSON) conversions.
 *
 * PostgreSQL JDBC returns AGE columns as PGobject whose getValue() is a
 * JSON-quoted string. Raw JDBC getLong/getString calls will fail on agtype.
 */
public class AgeConverter extends Converter {

    // ── Read direction: agtype → Java ──

    /**
     * Convert an agtype value to long. AGE returns numeric values as
     * JSON strings like "42" or as agtype wrapper "42::numeric".
     */
    public static long toLong(Object agtypeObj) {
        if (agtypeObj == null) {
            return 0L;
        }
        String s = stripAgtype(agtypeObj.toString());
        if (s.isEmpty()) {
            return 0L;
        }
        // Handle agtype numeric suffix like "42::numeric"
        int idx = s.indexOf("::");
        if (idx >= 0) {
            s = s.substring(0, idx);
        }
        return Long.parseLong(s);
    }

    /**
     * Convert an agtype value to int.
     */
    public static int toInt(Object agtypeObj) {
        return (int) toLong(agtypeObj);
    }

    /**
     * Convert an agtype value to String. Strips JSON string quotes.
     */
    public static String toStr(Object agtypeObj) {
        if (agtypeObj == null) {
            return "";
        }
        return stripAgtype(agtypeObj.toString());
    }

    /**
     * Convert an agtype value to boolean.
     */
    public static boolean toBool(Object agtypeObj) {
        if (agtypeObj == null) {
            return false;
        }
        String s = stripAgtype(agtypeObj.toString());
        return "true".equalsIgnoreCase(s);
    }

    /**
     * Convert an agtype value to double.
     */
    public static double toDouble(Object agtypeObj) {
        if (agtypeObj == null) {
            return 0.0;
        }
        String s = stripAgtype(agtypeObj.toString());
        if (s.isEmpty()) {
            return 0.0;
        }
        int idx = s.indexOf("::");
        if (idx >= 0) {
            s = s.substring(0, idx);
        }
        return Double.parseDouble(s);
    }

    /**
     * Convert an agtype value representing epoch millis to long.
     */
    public static long toDate(Object agtypeObj) {
        return toLong(agtypeObj);
    }

    /**
     * Convert an agtype array to a list of strings.
     * Expected format: ["val1", "val2", ...]
     */
    public static List<String> toStringList(Object agtypeObj) {
        if (agtypeObj == null) {
            return new ArrayList<>();
        }
        String s = agtypeObj.toString().trim();
        if (s.isEmpty() || "[]".equals(s) || "null".equals(s)) {
            return new ArrayList<>();
        }
        // Remove outer brackets
        if (s.startsWith("[")) {
            s = s.substring(1);
        }
        if (s.endsWith("]")) {
            s = s.substring(0, s.length() - 1);
        }
        List<String> result = new ArrayList<>();
        for (String item : s.split(",")) {
            String trimmed = item.trim();
            // Strip quotes
            if (trimmed.startsWith("\"") && trimmed.endsWith("\"")) {
                trimmed = trimmed.substring(1, trimmed.length() - 1);
            }
            if (!trimmed.isEmpty()) {
                result.add(trimmed);
            }
        }
        return result;
    }

    /**
     * Convert an agtype array of organization arrays to Organization list.
     * Expected format: [["orgName", classYear, "cityName"], ...]
     */
    public static List<LdbcQuery1Result.Organization> asOrganization(Object agtypeObj) {
        List<LdbcQuery1Result.Organization> orgs = new ArrayList<>();
        if (agtypeObj == null) {
            return orgs;
        }
        String s = agtypeObj.toString().trim();
        if (s.isEmpty() || "[]".equals(s) || "null".equals(s)) {
            return orgs;
        }
        // Parse nested arrays: [["name", year, "city"], ...]
        // Simple state-machine parser for nested brackets
        int depth = 0;
        int start = -1;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '[') {
                depth++;
                if (depth == 2) {
                    start = i + 1;
                }
            } else if (c == ']') {
                if (depth == 2 && start >= 0) {
                    String inner = s.substring(start, i);
                    orgs.add(parseOrganization(inner));
                    start = -1;
                }
                depth--;
            }
        }
        return orgs;
    }

    private static LdbcQuery1Result.Organization parseOrganization(String inner) {
        // inner: "orgName", 2010, "cityName"
        String[] parts = inner.split(",", 3);
        String name = stripQuotes(parts[0].trim());
        int year = Integer.parseInt(parts[1].trim());
        String city = stripQuotes(parts[2].trim());
        return new LdbcQuery1Result.Organization(name, year, city);
    }

    // ── Write direction: Java → agtype/Cypher literals ──

    /**
     * Convert a list of tag IDs to a Cypher array literal: [1, 2, 3]
     */
    public static String convertTagIds(List<Long> tagIds) {
        if (tagIds == null || tagIds.isEmpty()) {
            return "[]";
        }
        return "[" + tagIds.stream()
                .map(String::valueOf)
                .collect(Collectors.joining(", ")) + "]";
    }

    /**
     * Convert Organization list to Cypher array of objects for IU1 UNWIND.
     * Format: [{organizationId: 1, year: 2010}, ...]
     */
    public static String convertOrganizations(List<LdbcUpdate1AddPerson.Organization> orgs) {
        if (orgs == null || orgs.isEmpty()) {
            return "[]";
        }
        return "[" + orgs.stream()
                .map(o -> "{organizationId: " + o.getOrganizationId() + ", year: " + o.getYear() + "}")
                .collect(Collectors.joining(", ")) + "]";
    }

    /**
     * Escape a string for safe embedding in Cypher single-quoted strings.
     */
    public static String escapeCypherString(String s) {
        if (s == null) {
            return "";
        }
        return s.replace("\\", "\\\\").replace("'", "\\'");
    }

    // ── Helpers ──

    /**
     * Strip JSON-style quoting and agtype suffixes from a value string.
     */
    private static String stripAgtype(String s) {
        if (s == null) {
            return "";
        }
        s = s.trim();
        // Strip JSON string quotes
        if (s.startsWith("\"") && s.endsWith("\"")) {
            s = s.substring(1, s.length() - 1);
        }
        return s;
    }

    private static String stripQuotes(String s) {
        if (s == null) {
            return "";
        }
        s = s.trim();
        if (s.startsWith("\"") && s.endsWith("\"")) {
            s = s.substring(1, s.length() - 1);
        }
        return s;
    }

    // Override Converter methods for string substitution in queries.
    // NOTE: Do NOT add surrounding quotes here because the .sql query files
    // already contain the quotes around $param placeholders (e.g. '$firstName').
    @Override
    public String convertString(String value) {
        return escapeCypherString(value);
    }
}
