# Proposal: Native Integer Support in AGEFreighter
---

## 1. Executive Summary

**The Problem:** 
Currently, the `agefreighter` loader serializes all property values in the agtype payload as strings. If we load a graph node with a numeric ID of `933`, `agefreighter` stores that property in the database as the text string `"933"`. 

**Why It Blocks Us:**
In Apache AGE (the graph engine running on PostgreSQL), finding a node is perfectly strict. If the application asks the database for "User number `933`", the database looks at its records, sees the text string `"933"`, decides they are not the same type, and returns 0 results. 

**Why We Can't Use a Workaround:**
We could, in principle, rewrite some queries so certain parameters are emitted as quoted strings to match AGEFreighter's current string storage. That may preserve index use for some exact-match lookups such as `id`.

However, this is not a general fix for the LDBC workload. The workload also includes date range filters, arithmetic, and other numeric comparisons. 

Handling those cases through query-side casting or selective parameter rewriting would complicate queries, potentially impact performance and it will become harder to compare numbers with other ldbc results as well. For that reason, fixing the loader to preserve numeric types at ingest time is the lower-risk and more scalable solution.

**The Ask:**
We need `agefreighter` to support loading numbers natively as numbers, so that we can adhere to LDBC standards. 

---

## 2. Technical Details

### 2.1 Root Cause in `agefreighter`
When `agefreighter` generates the intermediate CSV for the `COPY` pipeline, all properties are routed through the `format_kv` closure inside `AgeFreighter.write_csv()`.

```python
def format_kv(key: str, value: Any) -> str:
    safe_value = str(value).replace(...)...
    return f'""{key}"": ""{safe_value}""'  # <-- Hardcodes quotes around every value
```

Because of this rigid formatting, every single property (numeric, boolean, etc.) is emitted as an `agtype` string literal.

### 2.2 Impact on AGE / PostgreSQL Execution
Apache AGE's `@>` containment operator (which powers Cypher property lookups like `MATCH (p:Person {id: $personId})`) is type-strict.
* Stored as string: `{"id": "933"}`
* Query parameter: `{"id": 933}`
* **Result:** No match.

**Limits of Query-Side Workarounds:**
If we attempt to bypass this in Cypher by explicitly casting the stored property (for example, `MATCH (p:Person) WHERE toInteger(p.id) = $personId`), we leave the current containment-based lookup path and the existing index strategy used by this workload. In practice, that means the query planner would need different functional indexes to stay efficient.
Some exact-match lookups could instead be rewritten to compare against quoted string parameters, but that approach does not generalize cleanly to date range predicates, arithmetic, or mixed query patterns across the LDBC workload. That is why we treat query-side workarounds as fragile and prefer fixing the data typing at load time.

---

## 3. Proposed Solutions

To maintain high performance and correctness, `agefreighter` requires a mechanism to specify which columns should be emitted as unquoted integers. Below are two implementation approaches for the maintainer to consider.

These interface options are proposed for the config-driven import paths used by this workload. If the maintainer later wants a universal typed-value fix across all AGEFreighter source adapters, the same typing rules can also be applied at the shared property-serialization layer inside `write_csv()`.

### Solution 1: Neo4j-Style Type Suffixes (Longer-Term Interface)
In this approach, the user specifies the type directly in the configuration `"props"` list by appending a colon and the type (e.g., `:int`), similar to Neo4j's bulk import syntax. If no suffix is provided, it defaults to a string.

**How the config looks:**
```json
{
  "start_vertex": {
    "csv_path": "person.csv",
    "label": "Person",
    "props": ["id:int", "firstName", "lastName", "creationDate:int"]
  }
}
```

**Implementation Impact (Medium Effort):**
* Requires string parsing (`prop.split(":")`) during configuration load.
* Requires the loader to maintain a small mapping dictionary of `column_name -> type_constraint`.
* Requires normalization of `props` before downstream field selection, because some import paths currently consume `props` directly as raw property names.
* Inside `format_kv`, the loader checks the mapping dictionary. If the constraint is mapped to `int`, it skips the quotes around the `safe_value`.
* **Pro:** Extremely clean user experience. Very familiar to graph industry standards. Highly extensible for future types (`float`, `boolean`).

### Solution 2: Explicit `numeric_props` Scoped Array
In this approach, we add a secondary array exclusively for designating which keys represent numbers. To prevent global naming collisions across different labels, this array is scoped *inside* the specific vertex or edge configuration.

**How the config looks:**
```json
{
  "start_vertex": {
    "csv_path": "person.csv",
    "label": "Person",
    "props": ["id", "firstName", "lastName", "creationDate"],
    "numeric_props": ["id", "creationDate"]
  }
}
```

**Implementation Impact (Low Effort):**
* Very minimal parser changes. The JSON schema simply accepts a new optional list called `numeric_props`.
* This list is passed down to `write_csv` as a `set()` for `O(1)` validation.
* Inside `format_kv`, the logic is simply `if key in numeric_keys: <emit bare integer>`. 
* **Pro:** Extremely simple backward-compatible fix. Lowest risk of introducing parsing bugs. 
* **Con:** A bit more verbose for the user. Does not gracefully extend to other data types without adding more lists (e.g., `boolean_props: []`).

---

## 4. Conclusion
For our high-performance benchmarking needs on Apache AGE, we require native numeric containment matching. We strongly recommend adding interface support for numeric loading to `agefreighter`. **Solution 2** is the shortest low-risk path to land a safe fix for the current workload, while **Solution 1** is the stronger longer-term interface if the maintainer wants a more expressive schema for typed properties.