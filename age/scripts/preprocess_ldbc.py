#!/usr/bin/env python3
"""
Preprocess raw LDBC SNB CSVs into a custom load-ready format.

Output format (per vertex/edge file, no header):
    Vertex:  <orig_id>|"<agtype_properties_csv_escaped>"
    Edge:    <start_orig>|<end_orig>|<start_label>|<end_label>|"<agtype_properties_csv_escaped>"

The properties field is the pre-built agtype JSON for the row, CSV-escaped
(internal `"` doubled). The load script can concatenate it directly into a
COPY line without per-row Python work — `agtype_value`/`build_agtype_props`
used to live in load-production-data.py and ran for every row at COPY time
(GIL-bound, ~15-25 min at SF10). Doing the work once here trades preprocess
CPU for load throughput.
"""

import argparse
import csv
import json
from datetime import datetime, timezone
from pathlib import Path

# Properties that MUST be stored as agtype integers, not quoted strings.
# AGE Cypher compares by type before value, so `MATCH (n {id: 933})` does not
# match a stored string "933". Mirrors the prior NUMERIC_PROPS in load script.
NUMERIC_PROPS = frozenset({
    "id", "creationDate", "joinDate", "birthMonth", "birthDay",
})


def _agtype_value(key, val):
    """Format a CSV value as the correct agtype literal.

    - Empty / None  → "null" sentinel (caller drops the field).
    - Numeric props → bare integer (e.g. 933).
    - JSON arrays   → pass through (e.g. speaks/email semicolon→JSON happened upstream).
    - Other         → double-quoted string with backslash + control-char escaping.
    """
    if val is None or val == "":
        return "null"
    if key in NUMERIC_PROPS:
        try:
            # epoch-ms values fit in int; float() first handles scientific notation
            return str(int(float(val)))
        except (ValueError, TypeError):
            pass
    stripped = val.strip()
    if stripped.startswith("["):
        # JSON arrays only — never objects (free-text fields can contain {…})
        try:
            json.loads(stripped)
            return stripped
        except (json.JSONDecodeError, ValueError):
            pass
    escaped = val.replace("\\", "\\\\").replace('"', '\\"')
    escaped = (
        escaped
        .replace("\t", "\\t")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\x08", "\\b")
        .replace("\x0c", "\\f")
    )
    return f'"{escaped}"'


def _build_agtype_props(pairs):
    """Build an agtype JSON object string from (key, value) pairs.

    Empty / NULL values are omitted (matches the original load-time behaviour
    that lets IS2/IS4/IC2/IC7/IC9 `coalesce(content, imageFile)` work).
    """
    parts = []
    for k, v in pairs:
        av = _agtype_value(k, v)
        if av == "null":
            continue
        parts.append(f'"{k}": {av}')
    return "{" + ", ".join(parts) + "}"


def _csv_escape(s):
    """Escape an agtype string for embedding in CSV double-quotes (`"` → `""`)."""
    return s.replace('"', '""')


def _derive_birthday_fields(row):
    """Compute birthMonth + birthDay (1-12, 1-31) from Person.birthday (epoch ms).

    UTC matches LDBC reference's `datetime({epochMillis: …}).month`. IC10 filters
    on these precomputed ints to avoid the date-arithmetic path at query time.
    """
    bday_str = row.get("birthday", "")
    if not bday_str:
        return
    try:
        ts = int(bday_str)
        dt = datetime.fromtimestamp(ts / 1000.0, tz=timezone.utc)
        row["birthMonth"] = str(dt.month)
        row["birthDay"] = str(dt.day)
    except (ValueError, OverflowError):
        pass


def _write_vertex_line(out, orig_id, prop_pairs):
    """Emit one vertex line: <orig_id>|"<agtype_props_csv_escaped>"\n."""
    props = _build_agtype_props(prop_pairs)
    out.write(f'{orig_id}|"{_csv_escape(props)}"\n')


def _write_edge_line(out, start_id, end_id, start_label, end_label, prop_pairs):
    """Emit one edge line with start/end labels for downstream id_map resolution."""
    props = _build_agtype_props(prop_pairs)
    out.write(f'{start_id}|{end_id}|{start_label}|{end_label}|"{_csv_escape(props)}"\n')


def _semicolon_to_json_array(v):
    """Convert 'a;b;c' to JSON array string '["a","b","c"]' for AGE array storage."""
    parts = [p for p in v.split(";") if p]
    return json.dumps(parts, separators=(",", ":"))


# Person CSV has "language" (semicolon-separated) but queries/spec use "speaks" as an array.
# Email is also semicolon-separated and stored as a JSON array.
PERSON_COLUMN_TRANSFORMS = {
    "language": ("speaks", _semicolon_to_json_array),
    "email": ("email", _semicolon_to_json_array),
}

IS_LOCATED_IN_ROUTING = {
    "comment_isLocatedIn_place": ("Comment", "Country"),
    "post_isLocatedIn_place": ("Post", "Country"),
    "person_isLocatedIn_place": ("Person", "City"),
}


VERTEX_SPECS = [
    {"label": "Person", "subdir": "dynamic", "source": "person"},
    {"label": "Comment", "subdir": "dynamic", "source": "comment"},
    {"label": "Post", "subdir": "dynamic", "source": "post"},
    {"label": "Forum", "subdir": "dynamic", "source": "forum"},
    {"label": "Tag", "subdir": "static", "source": "tag"},
    {"label": "TagClass", "subdir": "static", "source": "tagclass"},
]


EDGE_SPECS = [
    {
        "label": "KNOWS",
        "bidirectional": True,   # LDBC CSV has one row per friendship; both directions required
        "sources": [{"subdir": "dynamic", "name": "person_knows_person", "start": "Person", "end": "Person"}],
    },
    {
        "label": "HAS_CREATOR",
        "sources": [
            {"subdir": "dynamic", "name": "comment_hasCreator_person", "start": "Comment", "end": "Person"},
            {"subdir": "dynamic", "name": "post_hasCreator_person", "start": "Post", "end": "Person"},
        ],
    },
    {
        "label": "REPLY_OF",
        "sources": [
            {"subdir": "dynamic", "name": "comment_replyOf_comment", "start": "Comment", "end": "Comment"},
            {"subdir": "dynamic", "name": "comment_replyOf_post", "start": "Comment", "end": "Post"},
        ],
    },
    {
        "label": "CONTAINER_OF",
        "sources": [{"subdir": "dynamic", "name": "forum_containerOf_post", "start": "Forum", "end": "Post"}],
    },
    {
        "label": "HAS_MEMBER",
        "sources": [{"subdir": "dynamic", "name": "forum_hasMember_person", "start": "Forum", "end": "Person"}],
    },
    {
        "label": "HAS_MODERATOR",
        "sources": [{"subdir": "dynamic", "name": "forum_hasModerator_person", "start": "Forum", "end": "Person"}],
    },
    {
        "label": "LIKES",
        "sources": [
            {"subdir": "dynamic", "name": "person_likes_comment", "start": "Person", "end": "Comment"},
            {"subdir": "dynamic", "name": "person_likes_post", "start": "Person", "end": "Post"},
        ],
    },
    {
        "label": "HAS_INTEREST",
        "sources": [{"subdir": "dynamic", "name": "person_hasInterest_tag", "start": "Person", "end": "Tag"}],
    },
    {
        "label": "STUDY_AT",
        "sources": [{"subdir": "dynamic", "name": "person_studyAt_organisation", "resolver": "organisation"}],
    },
    {
        "label": "WORK_AT",
        "sources": [{"subdir": "dynamic", "name": "person_workAt_organisation", "resolver": "organisation"}],
    },
    {
        "label": "IS_LOCATED_IN",
        "sources": [
            {"subdir": "dynamic", "name": "comment_isLocatedIn_place", "resolver": "is_located_in"},
            {"subdir": "dynamic", "name": "post_isLocatedIn_place", "resolver": "is_located_in"},
            {"subdir": "dynamic", "name": "person_isLocatedIn_place", "resolver": "is_located_in"},
            {"subdir": "static", "name": "organisation_isLocatedIn_place", "resolver": "org_is_located_in"},
        ],
    },
    {
        "label": "IS_PART_OF",
        "sources": [{"subdir": "static", "name": "place_isPartOf_place", "resolver": "is_part_of"}],
    },
    {
        "label": "HAS_TYPE",
        "sources": [{"subdir": "static", "name": "tag_hasType_tagclass", "start": "Tag", "end": "TagClass"}],
    },
    {
        "label": "IS_SUBCLASS_OF",
        "sources": [{"subdir": "static", "name": "tagclass_isSubclassOf_tagclass", "start": "TagClass", "end": "TagClass"}],
    },
    {
        "label": "HAS_TAG",
        "sources": [
            {"subdir": "dynamic", "name": "comment_hasTag_tag", "start": "Comment", "end": "Tag"},
            {"subdir": "dynamic", "name": "post_hasTag_tag", "start": "Post", "end": "Tag"},
            {"subdir": "dynamic", "name": "forum_hasTag_tag", "start": "Forum", "end": "Tag"},
        ],
    },
]


def read_ldbc_csv(filepath):
    """Read pipe-delimited LDBC CSV. Yields (headers_list, values_list) tuples."""
    with open(filepath, "r", encoding="utf-8") as f:
        headers = f.readline().strip().split("|")
        for line in f:
            line = line.strip()
            if line:
                yield headers, line.split("|")


def resolve_is_part_of(start_id, end_id, place_types):
    s_type = place_types.get(start_id, "")
    e_type = place_types.get(end_id, "")
    if s_type == "City" and e_type == "Country":
        return ("City", "Country")
    elif s_type == "Country" and e_type == "Continent":
        return ("Country", "Continent")
    return None


def format_scale_factor(sf_value):
    return str(sf_value)


def find_social_network_dir(sf_str, data_dir=None):
    if data_dir is not None:
        root = Path(data_dir)
    else:
        root = Path.home() / "repositories" / "ldbc_snb_data" / f"sf{sf_str}"
    if not root.exists():
        raise FileNotFoundError(f"Missing scale factor directory: {root}")
    matches = sorted(root.glob(f"social_network-sf{sf_str}*-CsvComposite-LongDateFormatter"))
    if not matches:
        matches = sorted(root.glob("social_network-*-CsvComposite-LongDateFormatter"))
    if not matches:
        raise FileNotFoundError(f"Could not find extracted social network dataset under {root}")
    return matches[0]


def find_source_files(dataset_dir, subdir, base_name):
    source_dir = dataset_dir / subdir
    exact = source_dir / f"{base_name}.csv"
    if exact.exists():
        return [exact]

    files = []
    for candidate in sorted(source_dir.glob(f"{base_name}_*.csv")):
        suffix = candidate.stem[len(base_name) + 1:]
        parts = suffix.split("_")
        if parts and all(part.isdigit() for part in parts):
            files.append(candidate)
    if files:
        return files
    raise FileNotFoundError(f"Missing LDBC source file for {subdir}/{base_name}")


# ---------------------------------------------------------------------------
# Streaming writers — never accumulate full datasets in memory
# ---------------------------------------------------------------------------

def stream_vertex_csv(path, dataset_dir, subdir, source_name, column_transforms=None, is_person=False):
    """Stream vertex rows to the load-ready format.

    column_transforms: {raw_col: (output_col, transform_fn)} — rename and/or
    transform columns before agtype property construction.
    is_person: if True, derives birthMonth/birthDay from birthday and includes them.
    Returns the list of property column names (headers minus 'id')."""
    path.parent.mkdir(parents=True, exist_ok=True)
    headers_out = None
    with open(path, "w", encoding="utf-8") as f:
        for file_path in find_source_files(dataset_dir, subdir, source_name):
            for headers, values in read_ldbc_csv(file_path):
                if headers_out is None:
                    if column_transforms:
                        headers_out = [
                            column_transforms[h][0] if h in column_transforms else h
                            for h in headers
                        ]
                    else:
                        headers_out = list(headers)
                    if is_person:
                        headers_out.extend(["birthMonth", "birthDay"])
                if column_transforms:
                    transformed_values = [
                        column_transforms[h][1](v) if h in column_transforms else v
                        for h, v in zip(headers, values)
                    ]
                else:
                    transformed_values = list(values)
                row = dict(zip(headers_out, transformed_values))
                if is_person:
                    _derive_birthday_fields(row)
                orig_id = row.get("id", "")
                # Include `id` in the agtype properties so AGE's
                # MATCH (n:Label {id: X}) compiles to a `properties @> {"id": X}`
                # containment that actually hits a row. orig_id is also written
                # as the line prefix so the loader can populate id_map without
                # re-parsing the agtype payload.
                prop_pairs = [(k, row.get(k, "")) for k in headers_out]
                _write_vertex_line(f, orig_id, prop_pairs)
    return [h for h in (headers_out or []) if h != "id"]


def stream_place_vertex_csvs(vertex_dir, dataset_dir):
    """Stream City/Country/Continent vertex files in load-ready format.
    Returns (vertex_files_dict, place_types, place_names).
    place_types and place_names are small (<2K entries at any SF) — kept in memory."""
    place_types = {}
    place_names = {}
    handles = {}
    for label in ("City", "Country", "Continent"):
        path = vertex_dir / f"{label}.csv"
        path.parent.mkdir(parents=True, exist_ok=True)
        handles[label] = open(path, "w", encoding="utf-8")

    for file_path in find_source_files(dataset_dir, "static", "place"):
        for headers, values in read_ldbc_csv(file_path):
            record = dict(zip(headers, values))
            ptype = record["type"].strip().lower()
            label_map = {"city": "City", "country": "Country", "continent": "Continent"}
            label = label_map.get(ptype)
            if label is None:
                continue
            place_types[record["id"]] = label
            place_names[record["id"]] = record["name"]
            _write_vertex_line(
                handles[label],
                record["id"],
                [("id", record["id"]), ("name", record["name"]), ("url", record["url"])],
            )

    for h in handles.values():
        h.close()

    vertex_files = {}
    for label in ("City", "Country", "Continent"):
        vertex_files[label] = {
            "csv_path": str(vertex_dir / f"{label}.csv"),
            "id": "id",
            "label": label,
            "props": ["name", "url"],
        }
    return vertex_files, place_types, place_names


def stream_organisation_vertex_csvs(vertex_dir, dataset_dir, place_names):
    """Stream Company/University vertex files in load-ready format.
    Returns (vertex_files_dict, organisation_types).
    organisation_types is small (<10K entries) — kept in memory."""
    org_locations = {}
    for file_path in find_source_files(dataset_dir, "static", "organisation_isLocatedIn_place"):
        for _, values in read_ldbc_csv(file_path):
            org_locations[values[0]] = values[1]

    organisation_types = {}
    company_path = vertex_dir / "Company.csv"
    university_path = vertex_dir / "University.csv"

    with open(company_path, "w", encoding="utf-8") as cf, \
         open(university_path, "w", encoding="utf-8") as uf:
        for file_path in find_source_files(dataset_dir, "static", "organisation"):
            for headers, values in read_ldbc_csv(file_path):
                record = dict(zip(headers, values))
                otype = record["type"].strip().lower()
                place_id = org_locations.get(record["id"], "")
                place_name = place_names.get(place_id, "")
                prop_pairs = [
                    ("id", record["id"]),
                    ("name", record["name"]),
                    ("url", record["url"]),
                    ("placeId", place_id),
                    ("placeName", place_name),
                ]
                if otype == "company":
                    _write_vertex_line(cf, record["id"], prop_pairs)
                    organisation_types[record["id"]] = "Company"
                elif otype == "university":
                    _write_vertex_line(uf, record["id"], prop_pairs)
                    organisation_types[record["id"]] = "University"

    org_props = ["name", "url", "placeId", "placeName"]
    vertex_files = {
        "Company": {"csv_path": str(company_path), "id": "id", "label": "Company", "props": org_props},
        "University": {"csv_path": str(university_path), "id": "id", "label": "University", "props": org_props},
    }
    return vertex_files, organisation_types


def resolve_organisation_edge(source_name, end_id, organisation_types):
    end_label = organisation_types.get(end_id)
    if source_name == "person_studyAt_organisation" and end_label == "University":
        return ("Person", "University")
    if source_name == "person_workAt_organisation" and end_label == "Company":
        return ("Person", "Company")
    return None


def stream_edge_csv(path, edge_spec, dataset_dir, place_types, organisation_types):
    """Stream edge rows in load-ready format. For bidirectional edges (KNOWS),
    emits both A→B and B→A from each source row. Returns list of property
    column names (informational for the agefreighter_config.json)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    bidirectional = edge_spec.get("bidirectional", False)

    # Determine property headers from the first row of the first source file.
    prop_headers = []
    seen = set()
    for source in edge_spec["sources"]:
        for file_path in find_source_files(dataset_dir, source["subdir"], source["name"]):
            for headers, _ in read_ldbc_csv(file_path):
                for h in headers[2:]:
                    if h not in seen:
                        prop_headers.append(h)
                        seen.add(h)
            break  # only need headers from first file of each source
        break  # only need one source to determine prop_headers

    with open(path, "w", encoding="utf-8") as f:
        for source in edge_spec["sources"]:
            for file_path in find_source_files(dataset_dir, source["subdir"], source["name"]):
                for headers, values in read_ldbc_csv(file_path):
                    start_id = values[0]
                    end_id = values[1]
                    prop_pairs = list(zip(headers[2:], values[2:]))

                    if source.get("resolver") == "is_located_in":
                        start_label, end_label = IS_LOCATED_IN_ROUTING[source["name"]]
                    elif source.get("resolver") == "org_is_located_in":
                        start_label = organisation_types.get(start_id)
                        end_label = place_types.get(end_id)
                        if start_label is None or end_label is None:
                            continue
                    elif source.get("resolver") == "is_part_of":
                        resolved = resolve_is_part_of(start_id, end_id, place_types)
                        if resolved is None:
                            continue
                        start_label, end_label = resolved
                    elif source.get("resolver") == "organisation":
                        resolved = resolve_organisation_edge(source["name"], end_id, organisation_types)
                        if resolved is None:
                            continue
                        start_label, end_label = resolved
                    else:
                        start_label = source["start"]
                        end_label = source["end"]

                    _write_edge_line(f, start_id, end_id, start_label, end_label, prop_pairs)
                    if bidirectional:
                        _write_edge_line(f, end_id, start_id, end_label, start_label, prop_pairs)

    return prop_headers


def build_config(vertex_files, edge_files, edge_prop_map):
    edge_entries = []
    for edge_spec in EDGE_SPECS:
        props = edge_prop_map.get(edge_spec["label"], [])
        for source in edge_spec["sources"]:
            if source.get("resolver") == "is_located_in":
                start_label, end_label = IS_LOCATED_IN_ROUTING[source["name"]]
            elif source.get("resolver") == "org_is_located_in":
                # University→City and Company→Country; emit representative entries for config docs
                for combo_start, combo_end in [("University", "City"), ("Company", "Country")]:
                    edge_entries.append({
                        "csv_path": str(edge_files[edge_spec["label"]]),
                        "type": edge_spec["label"],
                        "props": props,
                        "start_vertex": vertex_files[combo_start],
                        "end_vertex": vertex_files[combo_end],
                    })
                continue
            elif source.get("resolver") == "is_part_of":
                for combo_start, combo_end in [("City", "Country"), ("Country", "Continent")]:
                    edge_entries.append({
                        "csv_path": str(edge_files[edge_spec["label"]]),
                        "type": edge_spec["label"],
                        "props": props,
                        "start_vertex": vertex_files[combo_start],
                        "end_vertex": vertex_files[combo_end],
                    })
                continue
            elif source.get("resolver") == "organisation":
                start_label, end_label = (
                    ("Person", "University") if source["name"] == "person_studyAt_organisation"
                    else ("Person", "Company")
                )
            else:
                start_label, end_label = source["start"], source["end"]

            edge_entries.append({
                "csv_path": str(edge_files[edge_spec["label"]]),
                "type": edge_spec["label"],
                "props": props,
                "start_vertex": vertex_files[start_label],
                "end_vertex": vertex_files[end_label],
            })
    return {"edge": edge_entries}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sf", default="3")
    parser.add_argument(
        "--data-dir",
        default=None,
        help=(
            "Directory containing the social_network-sf<N>-CsvComposite-LongDateFormatter folder. "
            "Defaults to ~/repositories/ldbc_snb_data/sf<N>."
        ),
    )
    args = parser.parse_args()

    sf_str = format_scale_factor(args.sf)
    dataset_dir = find_social_network_dir(sf_str, data_dir=args.data_dir)
    base_dir = Path(__file__).resolve().parent
    output_dir = base_dir / "converted" / f"sf{sf_str}"
    vertex_dir = output_dir / "vertices"
    edge_dir = output_dir / "edges"
    vertex_dir.mkdir(parents=True, exist_ok=True)
    edge_dir.mkdir(parents=True, exist_ok=True)

    # --- Vertices ---
    # Place and org lookups (small, kept in memory for edge resolution)
    place_vertex_files, place_types, place_names = stream_place_vertex_csvs(vertex_dir, dataset_dir)
    org_vertex_files, organisation_types = stream_organisation_vertex_csvs(vertex_dir, dataset_dir, place_names)

    vertex_files = {**place_vertex_files, **org_vertex_files}

    for spec in VERTEX_SPECS:
        file_path = vertex_dir / f"{spec['label']}.csv"
        transforms = PERSON_COLUMN_TRANSFORMS if spec["label"] == "Person" else None
        is_person = spec["label"] == "Person"
        props = stream_vertex_csv(file_path, dataset_dir, spec["subdir"], spec["source"], transforms, is_person=is_person)
        vertex_files[spec["label"]] = {
            "csv_path": str(file_path),
            "id": "id",
            "label": spec["label"],
            "props": props,
        }
        print(f"  {spec['label']}: streamed")

    # --- Edges ---
    edge_files = {}
    edge_prop_map = {}
    for edge_spec in EDGE_SPECS:
        file_path = edge_dir / f"{edge_spec['label']}.csv"
        props = stream_edge_csv(file_path, edge_spec, dataset_dir, place_types, organisation_types)
        edge_files[edge_spec["label"]] = file_path
        edge_prop_map[edge_spec["label"]] = props
        suffix = " (bidirectional)" if edge_spec.get("bidirectional") else ""
        print(f"  {edge_spec['label']}{suffix}: streamed")

    # Side tables (CommentRootPost, MessageByCreator) retired Milestone A 2026-05-30.

    # --- Config ---
    config = build_config(vertex_files, edge_files, edge_prop_map)
    config_path = output_dir / "agefreighter_config.json"
    with open(config_path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
    print(f"Wrote converted data to {output_dir}")
    print(f"Wrote config to {config_path}")


if __name__ == "__main__":
    main()
