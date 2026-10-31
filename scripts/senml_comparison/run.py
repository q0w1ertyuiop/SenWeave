"""Compare pinned SenML implementations using the same payloads and clock."""

import argparse
import base64
from collections import Counter
import importlib.metadata
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

import cbor2
from kpn_senml import SenmlPack, SenmlRecord


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GO_MODULE = "github.com/absmach/senml"
GO_VERSION = "v1.0.9-0.20261001142627-40cd806e5f63"
LABELS = {"bn": -2, "bt": -3, "bu": -4, "bv": -5, "bs": -6,
          "bver": -1, "n": 0, "u": 1, "v": 2, "vs": 3,
          "vb": 4, "s": 5, "t": 6, "ut": 7, "vd": 8}
UNDERSTOOD = set(LABELS) | {"ct", "bct"}


def run(args, data=None, cwd=ROOT):
    result = subprocess.run(args, cwd=cwd, input=data, text=True,
                            encoding="utf-8", capture_output=True, timeout=240)
    if result.returncode:
        # Build diagnostics stay on stderr; result artifacts never store paths.
        sys.stderr.write(result.stderr)
        raise RuntimeError("Comparison command failed: " + Path(args[0]).name)
    return result.stdout


def payload(case, fmt):
    if fmt == "xml":
        if "xml_input" in case:
            return case["xml_input"]
        root = ET.Element("sensml", {"xmlns": "urn:ietf:params:xml:ns:senml"})
        for record in json.loads(case["input"]):
            attributes = {key: ("true" if value else "false") if isinstance(value, bool)
                          else str(value) for key, value in record.items()}
            ET.SubElement(root, "senml", attributes)
        return ET.tostring(root, encoding="unicode")
    if fmt == "json":
        return case["input"]
    if "cbor_hex" in case:
        return case["cbor_hex"]
    records = json.loads(case["input"])
    mapped = []
    for record in records:
        fields = {}
        for label, value in record.items():
            if label == "vd" and isinstance(value, str):
                value = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
            fields[LABELS.get(label, label)] = value
        mapped.append(fields)
    return cbor2.dumps(mapped).hex()


def records_from_cbor(hex_text):
    names = {value: key for key, value in LABELS.items()}
    records = cbor2.loads(bytes.fromhex(hex_text))
    result = []
    for record in records:
        fields = {}
        for label, value in record.items():
            label = names.get(label, label)
            if label == "vd" and isinstance(value, bytes):
                value = base64.urlsafe_b64encode(value).decode().rstrip("=")
            fields[label] = value
        result.append(fields)
    return result


def records_from_xml(text):
    root = ET.fromstring(text)
    ns = "{urn:ietf:params:xml:ns:senml}"
    assert root.tag == ns + "sensml"
    result = []
    for child in root:
        assert child.tag == ns + "senml"
        record = {}
        for label, value in child.attrib.items():
            if label in {"bt", "bv", "bs", "bver", "v", "s", "t", "ut"}:
                value = json.loads(value)
            elif label == "vb":
                assert value in {"true", "false", "1", "0"}
                value = value in {"true", "1"}
            record[label] = value
        result.append(record)
    return result


def cbor_data_types_valid(hex_text):
    return all((8 not in record or isinstance(record[8], bytes)) and
               all(key not in record or isinstance(record[key], str) for key in ["ct", "bct"])
               for record in cbor2.loads(bytes.fromhex(hex_text)))


def project(records, now, complete_time=False):
    """Ignore member order and empty standalone units, never bool/number types.

    Go Normalize retains relative time. The host's explicit clock completion is
    recorded separately from the untouched upstream normalized payload.
    """
    result = []
    for record in records:
        record = dict(record)
        if record.get("u") == "":
            record.pop("u")
        if complete_time:
            time = record.get("t", 0)
            record["t"] = now + time if time < 2 ** 28 else time
        result.append(record)
    if complete_time:
        result.sort(key=lambda record: record["t"])
    return result


def equal(left, right, binary64=False):
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(equal(left[k], right[k], binary64) for k in left)
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(equal(a, b, binary64) for a, b in zip(left, right))
    if binary64 and isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return float(left) == float(right)
    return left == right


def moon_batch(requests):
    return json.loads(run(["node", str(HERE / "moon_host.mjs")], json.dumps(requests)))


def python_update(case, request):
    # This release updates existing actuator values. It exposes neither a
    # general Validate API nor a Pack-preserving Normalize API.
    records = json.loads(case["input"])
    pack = SenmlPack(records[0].get("bn", ""))
    targets = []
    for record in records:
        target = SenmlRecord(record["n"])
        pack.add(target)
        targets.append(target)
    try:
        if request["format"] == "json":
            pack.from_json(request["payload"])
        else:
            pack.from_cbor(bytes.fromhex(request["payload"]))
        return {"values": [target.value for target in targets],
                "metadata": [{"time": t.time, "unit": t.unit, "sum": t.sum,
                              "update_time": t.update_time} for t in targets]}
    except Exception as error:
        return {"error": type(error).__name__}


def compare(output, include_xml):
    assert importlib.metadata.version("cbor2") == "5.7.1"
    assert importlib.metadata.version("kpn-senml") == "1.0.1"
    suite = json.loads((HERE / "cases.json").read_text(encoding="utf-8"))
    assert suite["schema"] == 1
    cases = suite["cases"]
    if include_xml:
        cases += json.loads((HERE / "xml_cases.json").read_text(encoding="utf-8"))
    assert len({case["id"] for case in cases}) == len(cases)
    now = suite["reference_time"]
    expanded = [(case, fmt) for case in cases for fmt in case.get("formats", ["json", "cbor"])]
    if include_xml:
        # XML has no JSON null value; invalid numeric lexical forms are covered
        # by XML-specific tests rather than pretending that "None" is null.
        expanded += [(case, "xml") for case in cases if "formats" not in case and case["id"] != "null-value"]
    requests = [{"payload": payload(case, fmt), "format": fmt, "now": now}
                for case, fmt in expanded]
    run(["moon", "build", "examples/comparison", "--target", "js", "--release", "--deny-warn"])
    module = json.loads(run(["go", "list", "-m", "-json", GO_MODULE], cwd=HERE))
    assert module["Version"] == GO_VERSION
    assert "Replace" not in module, "Run the unmodified pinned reference module"
    binary = ROOT / "_build" / "interop" / ("senml-go-reference.exe" if sys.platform == "win32" else "senml-go-reference")
    binary.parent.mkdir(parents=True, exist_ok=True)
    run(["go", "build", "-trimpath", "-o", str(binary), "."], cwd=HERE)
    go_results = json.loads(run([str(binary)], json.dumps(requests)))
    moon_results = moon_batch(requests)
    assert len(go_results) == len(moon_results) == len(requests)
    # Read the reference encodings back through SenWeave; raw re-encoding must
    # preserve meaning across bases, explicit resets and format conversion.
    roundtrip_requests, roundtrip_keys = [], []
    for i, (actual, reference) in enumerate(zip(moon_results, go_results)):
        if "expected" not in expanded[i][0]:
            continue
        for library, result in [("senweave", actual), ("go", reference)]:
            for field, fmt in [("raw_json", "json"), ("raw_cbor", "cbor")] + ([("raw_xml", "xml")] if expanded[i][1] == "xml" else []):
                if field in result:
                    roundtrip_keys.append((i, library, field))
                    roundtrip_requests.append({"payload": result[field], "format": fmt, "now": now})
    roundtrips = dict(zip(roundtrip_keys, moon_batch(roundtrip_requests)))
    expectations = json.loads((HERE / "go_expectations.json").read_text(encoding="utf-8"))
    if include_xml:
        expectations.update(json.loads((HERE / "xml_expectations.json").read_text(encoding="utf-8")))
    reports, unexpected, differences = [], [], Counter()
    python_count = 0
    for i, ((case, fmt), request, actual, go) in enumerate(zip(expanded, requests, moon_results, go_results)):
        key = case["id"] + "/" + fmt
        observed = []
        binary64_equivalent = []
        if "error" in case:
            assert actual.get("error") == case["error"], (key, actual)
            assert actual["stage"] == case.get("error_stage", "decode_validate"), (key, actual)
            if go["stage"] != "decode_validate" and case.get("error_stage") != "resolve":
                observed.append("validation")
            if case.get("error_stage") == "resolve":
                assert go["stage"] == "encode_normalized", (key, go)
                observed.append("failure_stage")
        else:
            expected = project(case["expected"], now)
            assert actual["stage"] == "resolved", (key, actual)
            for field, decoded in [("resolved_json", json.loads(actual["resolved_json"])),
                                   ("resolved_cbor", records_from_cbor(actual["resolved_cbor"]))]:
                assert equal(project(decoded, now), expected), (key, field, decoded, expected)
            assert cbor_data_types_valid(actual["resolved_cbor"]), key
            if "resolved_xml" in actual:
                assert equal(project(records_from_xml(actual["resolved_xml"]), now), expected), (key, "resolved_xml")
            else:
                assert fmt != "xml" and actual.get("resolved_xml_error") == "InvalidXml", key
            if "xml_input" not in case:
                original = [{k: v for k, v in r.items() if k in UNDERSTOOD} for r in json.loads(case["input"])]
                assert equal(json.loads(actual["raw_json"]), original), (key, "raw_json")
                assert equal(records_from_cbor(actual["raw_cbor"]), original), (key, "raw_cbor")
                if "raw_xml" in actual:
                    assert equal(records_from_xml(actual["raw_xml"]), original), (key, "raw_xml")
            raw_fields = ["raw_json", "raw_cbor"] + (["raw_xml"] if fmt == "xml" else [])
            for field in raw_fields:
                copy = roundtrips[(i, "senweave", field)]
                assert copy["stage"] == "resolved" and equal(project(json.loads(copy["resolved_json"]), now), expected), (key, field, copy)
            if go["stage"] == "decode_validate":
                observed.append("validation")
            else:
                assert go["stage"] == "normalized", (key, go)
                for field in raw_fields:
                    copy = roundtrips[(i, "go", field)]
                    if copy["stage"] != "resolved" or not equal(project(json.loads(copy["resolved_json"]), now), expected):
                        observed.append(field)
                        if copy["stage"] == "resolved" and equal(project(json.loads(copy["resolved_json"]), now), expected, binary64=True):
                            binary64_equivalent.append(field)
                normalized = [("normalized_json", json.loads(go["normalized_json"])),
                              ("normalized_cbor", records_from_cbor(go["normalized_cbor"]))]
                if fmt == "xml":
                    normalized.append(("normalized_xml", records_from_xml(go["normalized_xml"])))
                for field, decoded in normalized:
                    if (not equal(project(decoded, now, complete_time=True), expected)
                            or (field == "normalized_cbor" and not cbor_data_types_valid(go[field]))):
                        observed.append(field)
                        if (field != "normalized_cbor" or cbor_data_types_valid(go[field])) and equal(project(decoded, now, complete_time=True), expected, binary64=True):
                            binary64_equivalent.append(field)
        known = expectations.get(key, {})
        if sorted(observed) != sorted(known.get("stages", [])):
            unexpected.append({"case": key, "observed": observed, "expected": known.get("stages", [])})
        differences.update(observed)
        record = {"case": key, "spec": case["spec"], "request": request,
                  "expected": case.get("expected", {"error": case.get("error"),
                      "stage": case.get("error_stage", "decode_validate")}),
                  "senweave": actual, "go": go, "go_difference_stages": observed,
                  "go_binary64_equivalent_difference_stages": binary64_equivalent,
                  "go_classification": known.get("classification", "same"),
                  "go_interpretation": known.get("reason", "Same result in the exercised stages.")}
        record["roundtrips"] = {library: {field: roundtrips[(i, library, field)]
            for field in ["raw_json", "raw_cbor", "raw_xml"] if (i, library, field) in roundtrips}
            for library in ["senweave", "go"]}
        if "normalized_json" in go:
            record["go_normalized_with_reference"] = project(json.loads(go["normalized_json"]), now, complete_time=True)
        if "python" in case and fmt != "xml":
            python_count += 1
            python = python_update(case, request)
            if "error" in case["python"]:
                assert python == case["python"], (key, python)
            else:
                assert equal(python.get("values"), case["python"]["values"]), (key, python)
                assert all(all(v is None for v in m.values()) for m in python["metadata"]), (key, python)
            record["python_input_update"] = python
        else:
            record["python_input_update"] = {"status": "not-covered-by-this-adapter"}
        reports.append(record)
    used = {case["id"] + "/" + fmt for case, fmt in expanded}
    assert not (expectations.keys() - used), "Remove stale difference expectations"
    summary = {"fixtures": len(cases), "format_cases": len(requests),
               "formats": dict(sorted(Counter(fmt for _, fmt in expanded).items())),
               "senweave_passed": len(requests),
               "go_same": sum(r["go_classification"] == "same" for r in reports),
               "go_unrelated_rejections": sum(r["go_classification"] == "unrelated-rejection" for r in reports),
               "go_documented_differences": sum(bool(r["go_difference_stages"]) for r in reports),
               "go_classifications": dict(sorted(Counter(r["go_classification"] for r in reports).items())),
               "go_difference_stages": dict(sorted(differences.items())),
               "python_input_update_cases": python_count,
               "python_successful_updates": sum("values" in r["python_input_update"] for r in reports),
               "python_recorded_exceptions": sum("error" in r["python_input_update"] for r in reports),
               "unexpected_differences": unexpected}
    report = {"schema": 1, "versions": {"senweave": json.loads((ROOT / "package.json").read_text())["version"],
              "go_toolchain": run(["go", "version"]).strip(), "go_module": GO_MODULE,
              "go_reference": GO_VERSION, "kpn_senml": "1.0.1", "cbor2": "5.7.1"},
              "reference_time": now, "command": "python scripts/senml_comparison/run.py" + (" --xml" if include_xml else ""),
              "summary": summary, "cases": reports}
    report["versions"].update({"python": platform.python_version(),
        "node": run(["node", "--version"]).strip(), "moon": run(["moon", "version"]).strip()})
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    assert not unexpected, "Reference behavior changed; inspect the saved case outputs"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "_build/interop/senml-comparison.json")
    parser.add_argument("--xml", action="store_true", help="Include shared XML cases and XML-specific fixtures")
    args = parser.parse_args()
    if not shutil.which("go"):
        parser.error("Go 1.24.5 or newer is required for the pinned reference")
    compare(args.output, args.xml)
