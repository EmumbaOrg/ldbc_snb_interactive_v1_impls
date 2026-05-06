#!/usr/bin/env python3

import argparse
import csv
import json
from collections import OrderedDict
from pathlib import Path


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
    """Read pipe-delimited LDBC CSV. Yields (headers_list, values_list) tuples.
    Uses positional access to handle duplicate column names."""
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


def find_social_network_dir(sf_str):
    root = Path.home() / "emumbaorg/msft-benchmarking/ldbc_snb_interactive_v1_impls/age" / "ldbc_snb_data" / f"sf{sf_str}"
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
        suffix = candidate.stem[len(base_name) + 1 :]
        parts = suffix.split("_")
        if parts and all(part.isdigit() for part in parts):
            files.append(candidate)
    if files:
        return files
    raise FileNotFoundError(f"Missing LDBC source file for {subdir}/{base_name}")


def write_csv(path, headers, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, quoting=csv.QUOTE_ALL)
        writer.writerow(headers)
        writer.writerows(rows)


def load_place_vertices(dataset_dir):
    vertices = {"City": [], "Country": [], "Continent": []}
    place_types = {}
    place_names = {}
    for file_path in find_source_files(dataset_dir, "static", "place"):
        for headers, values in read_ldbc_csv(file_path):
            record = dict(zip(headers, values))
            place_type = record["type"].strip().lower()
            if place_type == "city":
                label = "City"
            elif place_type == "country":
                label = "Country"
            elif place_type == "continent":
                label = "Continent"
            else:
                continue
            vertices[label].append([record["id"], record["name"], record["url"]])
            place_types[record["id"]] = label
            place_names[record["id"]] = record["name"]
    return vertices, place_types, place_names


def load_organisation_location_map(dataset_dir):
    org_locations = {}
    for file_path in find_source_files(dataset_dir, "static", "organisation_isLocatedIn_place"):
        for _, values in read_ldbc_csv(file_path):
            org_locations[values[0]] = values[1]
    return org_locations


def load_organisation_vertices(dataset_dir, place_names):
    company_rows = []
    university_rows = []
    organisation_types = {}
    org_locations = load_organisation_location_map(dataset_dir)
    for file_path in find_source_files(dataset_dir, "static", "organisation"):
        for headers, values in read_ldbc_csv(file_path):
            record = dict(zip(headers, values))
            org_type = record["type"].strip().lower()
            place_id = org_locations.get(record["id"], "")
            place_name = place_names.get(place_id, "")
            base_row = [record["id"], record["name"], record["url"], place_id, place_name]
            if org_type == "company":
                company_rows.append(base_row)
                organisation_types[record["id"]] = "Company"
            elif org_type == "university":
                university_rows.append(base_row)
                organisation_types[record["id"]] = "University"
    return company_rows, university_rows, organisation_types


def load_generic_vertices(dataset_dir, subdir, source_name):
    headers_out = None
    rows = []
    for file_path in find_source_files(dataset_dir, subdir, source_name):
        for headers, values in read_ldbc_csv(file_path):
            if headers_out is None:
                headers_out = headers
            rows.append(values)
    return headers_out or [], rows


def resolve_organisation_edge(source_name, start_id, end_id, organisation_types):
    end_label = organisation_types.get(end_id)
    if source_name == "person_studyAt_organisation" and end_label == "University":
        return ("Person", "University")
    if source_name == "person_workAt_organisation" and end_label == "Company":
        return ("Person", "Company")
    return None


def build_edge_rows(dataset_dir, edge_spec, place_types, organisation_types):
    rows = []
    property_names = []
    seen_properties = set()
    edge_id = 1

    for source in edge_spec["sources"]:
        for file_path in find_source_files(dataset_dir, source["subdir"], source["name"]):
            for headers, values in read_ldbc_csv(file_path):
                start_id = values[0]
                end_id = values[1]
                properties = OrderedDict()
                for index in range(2, len(headers)):
                    header = headers[index]
                    value = values[index]
                    properties[header] = value
                    if header not in seen_properties:
                        property_names.append(header)
                        seen_properties.add(header)

                if source.get("resolver") == "is_located_in":
                    start_label, end_label = IS_LOCATED_IN_ROUTING[source["name"]]
                elif source.get("resolver") == "is_part_of":
                    resolved = resolve_is_part_of(start_id, end_id, place_types)
                    if resolved is None:
                        continue
                    start_label, end_label = resolved
                elif source.get("resolver") == "organisation":
                    resolved = resolve_organisation_edge(source["name"], start_id, end_id, organisation_types)
                    if resolved is None:
                        continue
                    start_label, end_label = resolved
                else:
                    start_label = source["start"]
                    end_label = source["end"]

                row = {
                    "id": str(edge_id),
                    "start_id": start_id,
                    "end_id": end_id,
                    "start_vertex_type": start_label,
                    "end_vertex_type": end_label,
                }
                row.update(properties)
                rows.append(row)
                edge_id += 1

    ordered_headers = ["id", "start_id", "end_id", "start_vertex_type", "end_vertex_type", *property_names]
    ordered_rows = [[row.get(header, "") for header in ordered_headers] for row in rows]
    return ordered_headers, ordered_rows


def build_config(vertex_files, edge_files):
    edge_entries = []
    for edge_spec in EDGE_SPECS:
        for source in edge_spec["sources"]:
            if source.get("resolver") == "is_located_in":
                start_label, end_label = IS_LOCATED_IN_ROUTING[source["name"]]
            elif source.get("resolver") == "is_part_of":
                combos = [("City", "Country"), ("Country", "Continent")]
                for combo_start, combo_end in combos:
                    edge_entries.append(
                        {
                            "csv_path": str(edge_files[edge_spec["label"]]),
                            "type": edge_spec["label"],
                            "props": edge_spec["props"],
                            "start_vertex": vertex_files[combo_start],
                            "end_vertex": vertex_files[combo_end],
                        }
                    )
                continue
            elif source.get("resolver") == "organisation":
                if source["name"] == "person_studyAt_organisation":
                    start_label, end_label = ("Person", "University")
                else:
                    start_label, end_label = ("Person", "Company")
            else:
                start_label, end_label = source["start"], source["end"]

            edge_entries.append(
                {
                    "csv_path": str(edge_files[edge_spec["label"]]),
                    "type": edge_spec["label"],
                    "props": edge_spec["props"],
                    "start_vertex": vertex_files[start_label],
                    "end_vertex": vertex_files[end_label],
                }
            )
    return {"edge": edge_entries}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sf", default="3")
    args = parser.parse_args()

    sf_str = format_scale_factor(args.sf)
    dataset_dir = find_social_network_dir(sf_str)
    base_dir = Path(__file__).resolve().parent
    output_dir = base_dir / "converted" / f"sf{sf_str}"
    vertex_dir = output_dir / "vertices"
    edge_dir = output_dir / "edges"
    vertex_dir.mkdir(parents=True, exist_ok=True)
    edge_dir.mkdir(parents=True, exist_ok=True)

    place_vertices, place_types, place_names = load_place_vertices(dataset_dir)
    company_rows, university_rows, organisation_types = load_organisation_vertices(dataset_dir, place_names)

    vertex_files = {}

    for spec in VERTEX_SPECS:
        headers, rows = load_generic_vertices(dataset_dir, spec["subdir"], spec["source"])
        file_path = vertex_dir / f"{spec['label']}.csv"
        write_csv(file_path, headers, rows)
        vertex_files[spec["label"]] = {
            "csv_path": str(file_path),
            "id": "id",
            "label": spec["label"],
            "props": [header for header in headers if header != "id"],
        }

    for label in ["City", "Country", "Continent"]:
        headers = ["id", "name", "url"]
        file_path = vertex_dir / f"{label}.csv"
        write_csv(file_path, headers, place_vertices[label])
        vertex_files[label] = {
            "csv_path": str(file_path),
            "id": "id",
            "label": label,
            "props": ["name", "url"],
        }

    organisation_headers = ["id", "name", "url", "placeId", "placeName"]
    company_path = vertex_dir / "Company.csv"
    university_path = vertex_dir / "University.csv"
    write_csv(company_path, organisation_headers, company_rows)
    write_csv(university_path, organisation_headers, university_rows)
    vertex_files["Company"] = {
        "csv_path": str(company_path),
        "id": "id",
        "label": "Company",
        "props": ["name", "url", "placeId", "placeName"],
    }
    vertex_files["University"] = {
        "csv_path": str(university_path),
        "id": "id",
        "label": "University",
        "props": ["name", "url", "placeId", "placeName"],
    }

    edge_files = {}
    for edge_spec in EDGE_SPECS:
        headers, rows = build_edge_rows(dataset_dir, edge_spec, place_types, organisation_types)
        file_path = edge_dir / f"{edge_spec['label']}.csv"
        write_csv(file_path, headers, rows)
        edge_files[edge_spec["label"]] = file_path
        edge_spec["props"] = [
            header for header in headers if header not in {"id", "start_id", "end_id", "start_vertex_type", "end_vertex_type"}
        ]

    config = build_config(vertex_files, edge_files)
    config_path = output_dir / "agefreighter_config.json"
    with open(config_path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
    print(f"Wrote converted data to {output_dir}")
    print(f"Wrote config to {config_path}")


if __name__ == "__main__":
    main()
