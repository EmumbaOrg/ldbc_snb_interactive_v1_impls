-- PL/pgSQL BFS function for IC-13 (shortest path) and supporting functions
-- Run this after data loading: psql "$CONNECTION_STRING" -f create-sp-functions.sql

-- IC-13: Unweighted BFS shortest path between two persons via KNOWS
CREATE OR REPLACE FUNCTION ldbc_snb_shortest_path(
  graph_name text,
  person1_id bigint,
  person2_id bigint
)
RETURNS integer
LANGUAGE plpgsql
AS $func$
DECLARE
  depth integer := 0;
  frontier bigint[];
  next_frontier bigint[];
  visited bigint[];
  sql text;
  rec record;
  neighbor_id bigint;
BEGIN
  -- Same person => distance 0
  IF person1_id = person2_id THEN
    RETURN 0;
  END IF;

  LOAD 'age';
  SET search_path TO ag_catalog, public;

  frontier := ARRAY[person1_id];
  visited := ARRAY[person1_id];

  WHILE array_length(frontier, 1) > 0 AND depth < 30 LOOP
    depth := depth + 1;
    next_frontier := ARRAY[]::bigint[];

    -- For each person in the frontier, find all KNOWS neighbors
    -- We use dynamic SQL because cypher() needs a literal graph name
    sql := format(
      'SELECT (bid::text)::bigint AS neighbor_id
       FROM cypher(%L, $$
         MATCH (a:Person)-[:KNOWS]-(b:Person)
         WHERE a.id IN [%s]
         RETURN DISTINCT b.id AS bid
       $$) AS (bid agtype)',
      graph_name,
      array_to_string(frontier, ', ')
    );

    FOR rec IN EXECUTE sql LOOP
      neighbor_id := rec.neighbor_id;

      -- Found target
      IF neighbor_id = person2_id THEN
        RETURN depth;
      END IF;

      -- Add to next frontier if not visited
      IF NOT (neighbor_id = ANY(visited)) THEN
        next_frontier := array_append(next_frontier, neighbor_id);
        visited := array_append(visited, neighbor_id);
      END IF;
    END LOOP;

    frontier := next_frontier;
  END LOOP;

  -- No path found
  RETURN -1;
END
$func$;
