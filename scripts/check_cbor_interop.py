"""Check both wire directions against cbor2 5.7.1 (Python >= 3.9)."""

import argparse
import importlib.metadata
import json
from decimal import Decimal
from pathlib import Path
import subprocess

import cbor2


def run_example(target, payload=None):
    command = ["moon", "run", "examples/cbor", "--target", target]
    if payload is not None:
        command += ["--", "--hex", payload.hex()]
    completed = subprocess.run(
        command,
        cwd=Path(__file__).resolve().parent.parent,
        capture_output=True,
        encoding="utf-8",
        timeout=120,
    )
    if completed.returncode:
        raise RuntimeError(f"MoonBit consumer failed ({target}):\n{completed.stderr}")
    return json.loads(completed.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=["js", "native", "wasm-gc"], default="js")
    args = parser.parse_args()
    assert importlib.metadata.version("cbor2") == "5.7.1", "Install cbor2==5.7.1"

    outbound = run_example(args.target)
    raw = cbor2.loads(bytes.fromhex(outbound["raw_cbor_hex"]))
    assert raw == [
        {-2: "sensor:", -3: 1793000000, -4: "Cel", -5: 20, -6: 100, -1: 10},
        {0: "temperature", 2: 2.5, 5: 3, 6: -30, 7: 15},
        {0: "flag", 4: False, 1: "/"},
        {0: "blob", 8: b"\x00\xff", 1: "/", 6: -10},
        {0: "label", 3: "门\n🚪", 1: "", 6: -20},
        {0: "counter", -5: 0, 2: 9007199254740993},
    ]
    expected = [
        {0: "sensor:temperature", 1: "Cel", 2: 22.5, 5: 103, 6: 1792999970, 7: 15},
        {0: "sensor:label", 1: "", 3: "门\n🚪", 5: 100, 6: 1792999980},
        {0: "sensor:blob", 1: "/", 8: b"\x00\xff", 5: 100, 6: 1792999990},
        {0: "sensor:flag", 1: "/", 4: False, 5: 100, 6: 1793000000},
        {0: "sensor:counter", 1: "Cel", 2: 9007199254740993, 5: 100, 6: 1793000000},
    ]
    assert cbor2.loads(bytes.fromhex(outbound["resolved_cbor_hex"])) == expected
    assert type(raw[2][4]) is bool and type(raw[3][8]) is bytes
    assert type(raw[5][2]) is int

    incoming = [
        {-2: "external:", -3: 1793000000, -4: "V", -5: 1.0, -6: 10, -1: 10},
        {0: "decimal", 2: Decimal("1.25"), 6: -2, 7: 30},
        {0: "switch", 4: False, 1: "/", 6: -1},
        {0: "data", 8: b"\xfb\xef\xbe\xff\xff\xff", 1: "/"},
        {0: "counter", -5: 0, 2: 18446744073709551615, 6: 1},
        {0: "sum", 5: Decimal("2.5"), 6: 2},
    ]
    inbound = run_example(args.target, cbor2.dumps(incoming, canonical=True))
    assert cbor2.loads(bytes.fromhex(inbound["raw_cbor_hex"])) == incoming
    assert inbound["resolved"] == [
        {"n": "external:decimal", "u": "V", "v": 2.25, "s": 10, "t": 1792999998, "ut": 30},
        {"n": "external:switch", "u": "/", "vb": False, "s": 10, "t": 1792999999},
        {"n": "external:data", "u": "/", "vd": "----____", "s": 10, "t": 1793000000},
        {"n": "external:counter", "u": "V", "v": 18446744073709551615, "s": 10, "t": 1793000001},
        {"n": "external:sum", "u": "V", "v": 0, "s": 12.5, "t": 1793000002},
    ]
    wire_records = cbor2.loads(bytes.fromhex(inbound["resolved_cbor_hex"]))
    assert wire_records[2][8] == incoming[3][8]
    assert wire_records[3][2] == 18446744073709551615
    assert type(wire_records[1][4]) is bool
    assert all(all(type(key) is int and key >= 0 for key in row) for row in wire_records)
    print(json.dumps({
        "target": args.target,
        "codec": "cbor2==5.7.1",
        "outbound_records": len(raw),
        "inbound_records": len(incoming),
        "status": "passed",
    }))


if __name__ == "__main__":
    main()
