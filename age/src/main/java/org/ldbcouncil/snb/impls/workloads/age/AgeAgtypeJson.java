package org.ldbcouncil.snb.impls.workloads.age;

import java.util.List;
import java.util.Map;

/**
 * Emits agtype-textual JSON for use as a parameter to AGE's 3-argument
 * cypher(graph, query, params) function. The agtype text format is a
 * superset of JSON; we use the JSON subset.
 *
 * The output is bound via JDBC as a String and cast in SQL: ?::agtype.
 */
public final class AgeAgtypeJson {
    private AgeAgtypeJson() {}

    public static String mapOf(Map<String, Object> params) {
        StringBuilder sb = new StringBuilder(64);
        sb.append('{');
        boolean first = true;
        for (Map.Entry<String, Object> e : params.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            appendString(sb, e.getKey());
            sb.append(':');
            appendValue(sb, e.getValue());
        }
        sb.append('}');
        return sb.toString();
    }

    private static void appendValue(StringBuilder sb, Object v) {
        if (v == null) sb.append("null");
        else if (v instanceof Long || v instanceof Integer) sb.append(v.toString());
        else if (v instanceof Boolean) sb.append(((Boolean) v) ? "true" : "false");
        else if (v instanceof String) appendString(sb, (String) v);
        else if (v instanceof List<?>) appendList(sb, (List<?>) v);
        else if (v instanceof Map<?, ?>) appendMap(sb, (Map<?, ?>) v);
        else throw new IllegalArgumentException("Unsupported agtype value: " + v.getClass());
    }

    private static void appendList(StringBuilder sb, List<?> items) {
        sb.append('[');
        boolean first = true;
        for (Object item : items) {
            if (!first) sb.append(',');
            first = false;
            appendValue(sb, item);
        }
        sb.append(']');
    }

    @SuppressWarnings("unchecked")
    private static void appendMap(StringBuilder sb, Map<?, ?> m) {
        sb.append('{');
        boolean first = true;
        for (Map.Entry<?, ?> e : m.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            appendString(sb, e.getKey().toString());
            sb.append(':');
            appendValue(sb, e.getValue());
        }
        sb.append('}');
    }

    private static void appendString(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        sb.append('"');
    }
}
