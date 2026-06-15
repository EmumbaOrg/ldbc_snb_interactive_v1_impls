#!/usr/bin/env python3
"""
Compare validation_params-...-failed-{actual,expected}.json side by side.

Run after a validate_database run to see exactly how each query type
diverged from the reference. Groups by operation class and prints the
first divergence per class.
"""
import json
import sys
from collections import defaultdict, OrderedDict
from pathlib import Path


def load(path):
    text = Path(path).read_text()
    # File contains pretty-printed JSON arrays of {operation, result} objects,
    # but the driver writes them as concatenated arrays separated by newlines
    # rather than a single array. Try strict load first, then fall back.
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Wrap in []
        return json.loads("[" + text.strip().rstrip(",") + "]")


import re


_QID_RE = re.compile(r"(SQ|Q)(\d+)")


def op_class(entry):
    op = entry.get("operation", {})
    if not isinstance(op, dict):
        return "Unknown"
    found = set()
    for k in op:
        m = _QID_RE.search(k)
        if m:
            kind = "SQ" if m.group(1) == "SQ" else "Q"
            found.add(f"{kind}{m.group(2)}")
    if found:
        return ",".join(sorted(found))
    keys = sorted(op.keys())
    return "Update[" + ",".join(keys) + "]"


def short(val, n=180):
    s = json.dumps(val, default=str)
    if len(s) > n:
        s = s[: n - 3] + "..."
    return s


def diff_lists(expected, actual):
    """Return (status, detail) describing how two list results differ."""
    if expected == actual:
        return "MATCH", ""
    if not isinstance(expected, list) or not isinstance(actual, list):
        return "TYPE", f"expected={type(expected).__name__} actual={type(actual).__name__}"
    if len(expected) != len(actual):
        return "LEN", f"expected={len(expected)} actual={len(actual)}"
    for i, (e, a) in enumerate(zip(expected, actual)):
        if e != a:
            extra_keys = set(a) - set(e) if isinstance(e, dict) and isinstance(a, dict) else set()
            missing_keys = set(e) - set(a) if isinstance(e, dict) and isinstance(a, dict) else set()
            diff_keys = []
            if isinstance(e, dict) and isinstance(a, dict):
                for k in e:
                    if k in a and e[k] != a[k]:
                        diff_keys.append((k, e[k], a[k]))
            detail = f"row {i}: keys_diff={diff_keys[:3]} extra={extra_keys} missing={missing_keys}"
            return "ROW", detail
    return "UNKNOWN", ""


def main():
    if len(sys.argv) >= 3:
        actual_path, expected_path = sys.argv[1], sys.argv[2]
    else:
        base = "/tmp/ldbc_sf01/validation_params-sf0.1-subset"
        actual_path = base + "-failed-actual.json"
        expected_path = base + "-failed-expected.json"

    actual_entries = load(actual_path)
    expected_entries = load(expected_path)

    if len(actual_entries) != len(expected_entries):
        print(f"WARN: actual={len(actual_entries)} entries vs expected={len(expected_entries)} entries")

    by_class = defaultdict(list)
    for a, e in zip(actual_entries, expected_entries):
        cls = op_class(a)
        status, detail = diff_lists(e.get("result"), a.get("result"))
        by_class[cls].append((status, detail, a.get("operation"), e.get("result"), a.get("result")))

    print("\n" + "=" * 80)
    print("PER-QUERY DIAGNOSIS (first failure per query type)")
    print("=" * 80 + "\n")

    for cls in sorted(by_class):
        rows = by_class[cls]
        first = rows[0]
        status, detail, op, exp, act = first
        print(f"=== {cls}  [{len(rows)} failures]  status={status} ===")
        print(f"  detail: {detail}")
        print(f"  operation: {short(op, 200)}")
        print(f"  expected[0]: {short(exp[0] if isinstance(exp, list) and exp else exp, 220)}")
        print(f"  actual[0]:   {short(act[0] if isinstance(act, list) and act else act, 220)}")
        if isinstance(exp, list) and isinstance(act, list):
            print(f"  expected_count={len(exp)}  actual_count={len(act)}")
        print()


if __name__ == "__main__":
    main()
