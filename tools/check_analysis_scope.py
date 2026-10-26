#!/usr/bin/env python3
"""Validate specified analysis scope and request bounds; does not run analyses."""

import argparse
from datetime import date
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
ANALYSIS = ROOT / "inst/analysis"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_json(path):
    return json.loads(path.read_text())


def validate_profile(profile):
    require(type(profile["format_version"]) is int and profile["format_version"] == 1, "Unsupported manifest format")
    require(profile["profile_id"] == "alpha-measurement-v1", "Unsupported profile")
    metrics = profile["metrics"]
    ids = [metric["id"] for metric in metrics]
    require(len(ids) == len(set(ids)) == 15, "Expected 15 unique alpha outputs")
    require(profile["required_outputs"] == ids, "Required output list differs from metric registry")
    required = {"id", "version", "grain", "population", "window", "dimensions", "fields", "denominator",
                "aggregation", "unit_rule", "operator_rule", "zero_and_null_rule", "suppression_rule", "precision", "dependencies"}
    for metric in metrics:
        mid = metric["id"]
        require(required <= metric.keys(), f"Incomplete semantic definition: {mid}")
        require(metric["population"] in profile["populations"], f"Undefined population: {mid}")
        require(metric["version"] == "1.0.0", f"Unexpected metric revision: {mid}")
        require(set(metric["dependencies"]) <= set(ids), f"Unknown dependency: {mid}")
        for field in ("grain", "window", "aggregation", "unit_rule", "operator_rule", "zero_and_null_rule", "suppression_rule", "precision"):
            require(isinstance(metric[field], str) and metric[field].strip(), f"Missing {field}: {mid}")
        for field in ("fields", "dimensions"):
            values = metric[field]
            require(isinstance(values, list) and all(isinstance(v, str) and v for v in values) and len(values) == len(set(values)), f"Invalid {field}: {mid}")
        require(metric["fields"], f"No result fields: {mid}")
    by_id = {metric["id"]: metric for metric in metrics}

    def visit(mid, stack=()):
        require(mid not in stack, f"Cyclic metric dependency: {mid}")
        for dep in by_id[mid]["dependencies"]:
            visit(dep, stack + (mid,))
    for mid in ids:
        visit(mid)
    probes = [probe["id"] for probe in profile["prerequisite_probes"]]
    require(len(probes) == len(set(probes)), "Repeated capability probe")
    require(profile["request_contract"]["concept_max"] == 10, "Concept bound changed")
    require(profile["request_contract"]["output_scope"] == ["restricted"], "Unexpected output scope")


def validate_request(request, profile):
    require(isinstance(request, dict), "Request must be an object")
    contract = profile["request_contract"]
    require(set(request) == set(contract["required_keys"]), "Request must contain exactly the declared keys; filters/extra outputs are unsupported")
    require(request["profile_id"] == profile["profile_id"], "Unknown profile ID")
    require(isinstance(request["source_id"], str) and request["source_id"].strip(), "One explicit source ID is required")
    require(request["output_scope"] == "restricted", "Only restricted institutional output is specified")
    policy = request["disclosure_policy_id"]
    require(isinstance(policy, str) and re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}", policy), "A versioned disclosure policy ID is required")
    require(policy != "synthetic-unsuppressed-v1" or request["source_id"].startswith("fixture:"), "Synthetic policy requires a fixture source ID; executor must also verify actual source authorization")
    window = request["window"]
    require(isinstance(window, dict) and set(window) == {"start", "end"}, "Window must contain explicit start/end dates")
    for value in window.values():
        require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", value), "Use ISO date-only YYYY-MM-DD boundaries")
    start, end = date.fromisoformat(window["start"]), date.fromisoformat(window["end"])
    require(start <= end, "Window ends before it starts")
    months = (end.year - start.year) * 12 + end.month - start.month + 1
    require(months <= 120, "Window exceeds 120 touched calendar months")
    concepts = request["measurement_concept_ids"]
    require(isinstance(concepts, list) and 1 <= len(concepts) <= 10, "Select 1–10 concept IDs")
    require(all(type(cid) is int and 0 <= cid <= 2147483647 for cid in concepts), "Concept IDs must be exact nonnegative CDM integers, not floats, strings or booleans")
    require(len(concepts) == len(set(concepts)), "Repeated concept IDs are not permitted")


def check():
    lock = load_json(ANALYSIS / "manifest-lock.json")
    for name, expected in lock["sha256"].items():
        require(hashlib.sha256((ANALYSIS / name).read_bytes()).hexdigest() == expected, f"Manifest checksum changed: {name}; review the semantic revision and refresh its pin explicitly")
    profile = load_json(ANALYSIS / "alpha-measurement-v1.json")
    validate_profile(profile)
    cases = load_json(ROOT / "tests/fixtures/analysis/alpha-oracle.json")["cases"]
    for case in cases:
        validate_request(case["request"], profile)
    baselines = load_json(ANALYSIS / "legacy-baselines.json")["baselines"]
    require({baseline["id"] for baseline in baselines} == {"published_1_7_2", "audited_development"}, "Keep legacy baselines separate")
    for baseline in baselines:
        require(re.fullmatch(r"[0-9a-f]{40}", baseline["commit"]), "Unpinned legacy commit")
        require(baseline["analysis_count"] == baseline["default_count"] + baseline["opt_in_count"] == 294, "Legacy registry counts disagree")
    return profile, cases


def check_postgresql(state, profile, cases):
    spec = importlib.util.spec_from_file_location("fixture_tool", ROOT / "tools/postgresql_fixtures.py")
    fixture_tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture_tool)
    pg = fixture_tool.Postgres(state)
    fixture_tool.guard_database(pg)
    versions = fixture_tool.check_versions(pg, allow_mismatch=False)
    reference = ROOT / "tests/fixtures/analysis"

    def query(filename, bindings):
        sql = (reference / filename).read_text()
        for key, value in bindings.items():
            sql = sql.replace("{{" + key + "}}", value)
        require("{{" not in sql, "Unresolved reference SQL token")
        return json.loads(pg.value("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n" + sql + "\nROLLBACK;", "runner"))

    checked = []
    for case in cases:
        request = case["request"]
        for version in case["schema_versions"]:
            schema = fixture_tool.schema_name(case["fixture_source"], version)
            actual = query("reference.sql", {
                "schema": fixture_tool.identifier(schema),
                "start_date": fixture_tool.literal(request["window"]["start"]),
                "end_date": fixture_tool.literal(request["window"]["end"]),
                "concept_ids": fixture_tool.literal(json.dumps(request["measurement_concept_ids"])),
            })
            require(actual == case["expected"], f"Reference differs from handwritten oracle: {case['id']} / {version}\nactual={actual}")
            checked.append({"case": case["id"], "schema": schema, "status": "matches_handwritten_reference"})
    edges = load_json(reference / "numeric-edge-oracle.json")
    actual = query("numeric-edge-reference.sql", {"rows": fixture_tool.literal(json.dumps(edges["rows"]))})
    require(actual == edges["expected"], f"Numeric edge reference differs: {actual}")
    report = {"scope": "Read-only fixture reference calculations; not production-engine or legacy-template parity",
              "profile_id": profile["profile_id"], "revision": profile["revision"], "versions": versions,
              "fixture_checks": checked, "numeric_edge_records": len(edges["rows"]),
              "input_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in [ANALYSIS / "alpha-measurement-v1.json", *sorted(reference.glob("*"))] if path.is_file()}}
    output = state / "analysis-scope-verification.json"
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(checked)} read-only fixture cases and {len(edges['rows'])} numeric edge records match independent references")
    print(f"Local scope report: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", type=Path, help="Optional semantic request JSON to validate")
    parser.add_argument("--postgresql-state", type=Path, help="Optional saved sandbox state for read-only fixture reference checks")
    args = parser.parse_args()
    try:
        profile, cases = check()
        if args.request:
            validate_request(load_json(args.request), profile)
        if args.postgresql_state:
            check_postgresql(args.postgresql_state.expanduser().resolve(), profile, cases)
        print(f"PASS: {len(profile['metrics'])} specified outputs, pinned manifests, {len(cases)} bounded fixture requests, separate legacy baselines")
        print("Scope validation only: no analysis execution or legacy parity certification.")
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
