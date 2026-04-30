-- IC14: Trusted connection paths
-- AGE does not support allShortestPaths(). This query is handled by AgeIC14OperationHandler
-- which always returns an empty list.
SELECT NULL AS personIdsInPath, 0.0 AS pathWeight WHERE false
