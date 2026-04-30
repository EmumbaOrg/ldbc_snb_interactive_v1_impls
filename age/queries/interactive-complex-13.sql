-- IC13: Single shortest path length between two persons
-- Uses PL/pgSQL BFS function (create-sp-functions.sql must be installed)
SELECT ldbc_snb_shortest_path('$graphName', $person1Id, $person2Id) AS shortestPathLength
