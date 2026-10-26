"""Exercise KPN SenML 1.0.1's numeric/boolean subset without patching it."""

import importlib.metadata
import json
from pathlib import Path
import subprocess

from kpn_senml import SenmlPack, SenmlRecord


ROOT = Path(__file__).resolve().parent.parent


def cli(payload, source="json", destination="json", success=True):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    result = subprocess.run(
        ["node", "bin/senweave.mjs", "resolve", "--from", source, "--to", destination],
        cwd=ROOT, input=payload, capture_output=True, timeout=30,
    )
    if success and result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8"))
    return result


def receiver(records):
    pack = SenmlPack("")
    targets = []
    for record in records:
        target = SenmlRecord(record["n"])
        pack.add(target)
        targets.append(target)
    return pack, targets


def main():
    assert importlib.metadata.version("kpn-senml") == "1.0.1"
    device = SenmlPack("device:")
    device.base_time = 1793000000
    device.base_value = 20
    device.base_unit = "Cel"
    source_records = [
        SenmlRecord("temperature", value=22.5, time=1792999970),
        SenmlRecord("zero", value=0, time=1792999980),
        SenmlRecord("door", value=False, time=1793000000, unit="/"),
    ]
    for record in source_records:
        device.add(record)
    expected = [
        {"n": "device:temperature", "v": 22.5, "t": 1792999970, "u": "Cel"},
        {"n": "device:zero", "v": 0, "t": 1792999980, "u": "Cel"},
        {"n": "device:door", "vb": False, "t": 1793000000, "u": "/"},
    ]
    # KPN writes relative offsets from its configured absolute base time/value.
    for source, payload in [("json", device.to_json()), ("cbor", device.to_cbor())]:
        result = cli(payload, source)
        assert json.loads(result.stdout) == expected
        assert type(json.loads(result.stdout)[2]["vb"]) is bool

    # KPN's input API updates existing record values. Check that contract in
    # both formats; it does not populate time/unit metadata in this release.
    resolved = json.dumps(expected)
    incoming_json = cli(resolved).stdout.decode("utf-8")
    json_pack, targets = receiver(expected)
    json_pack.from_json(incoming_json)
    assert [record.value for record in targets] == [22.5, 0, False]
    assert type(targets[2].value) is bool
    assert all(record.time is None for record in targets)
    incoming_cbor = cli(resolved, destination="cbor").stdout
    cbor_pack, targets = receiver(expected)
    cbor_pack.from_cbor(incoming_cbor)
    assert [record.value for record in targets] == [22.5, 0, False]
    assert type(targets[2].value) is bool

    energy = SenmlPack("energy:")
    energy.base_time = 1793000000
    energy.base_sum = 100
    energy.base_unit = "W"
    energy.add(SenmlRecord("integral", sum=105, time=1792999970))
    assert json.loads(cli(energy.to_json()).stdout) == [
        {"n": "energy:integral", "s": 105, "t": 1792999970, "u": "W"},
    ]
    # The published KPN release uses -16 for bs. RFC 8428 assigns -6, so keep
    # SenWeave's rejection and record the interoperability difference explicitly.
    incompatible = cli(energy.to_cbor(), "cbor", success=False)
    assert incompatible.returncode == 1
    assert json.loads(incompatible.stderr)["code"] == "InvalidCborLabel"
    try:
        SenmlRecord("label", value="sensor")
    except NameError as error:
        assert "basestring" in str(error)
    else:
        raise AssertionError("Recheck the documented KPN Python 3 text limitation")
    print(json.dumps({
        "library": "kpn-senml==1.0.1",
        "passing_flows": 5,
        "known_differences": ["base-sum-cbor-key", "python3-text-construction", "input-time-metadata"],
        "status": "passed-with-documented-differences",
    }))


if __name__ == "__main__":
    main()
