"""Validate the actual MoonBit archive in a separate consumer workspace."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import zipfile


def run(arguments, cwd):
    result = subprocess.run(arguments, cwd=cwd, text=True, capture_output=True, encoding="utf-8", errors="replace")
    if result.returncode:
        raise RuntimeError(f"Command failed: {arguments[0]}\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


def main(targets):
    root = Path(__file__).resolve().parent.parent
    manifest = (root / "moon.mod").read_text(encoding="utf-8")
    name = re.search(r'^name = "([^"]+)"', manifest, re.M)[1]
    version = re.search(r'^version = "([^"]+)"', manifest, re.M)[1]
    run(["moon", "package"], root)
    archive = root / "_build" / "publish" / f"{name.replace('/', '-')}-{version}.zip"
    path_pattern = re.compile(r'(?<![A-Za-z])[A-Za-z]:[\\/]+[^\\/"\s]|' + 'file:' + r'//|/(?:Users|home)/|AppData[\\/]')
    allowed_roots = {"bin", "cmd", "docs", "examples", "integrations", "internal", "js", "scripts", "tests"}
    with tempfile.TemporaryDirectory(prefix="senweave-moon-consumer-") as temporary:
        workspace = Path(temporary)
        library = workspace / "library"
        library.mkdir()
        with zipfile.ZipFile(archive) as package:
            names = package.namelist()
            for entry in package.infolist():
                path = PurePosixPath(entry.filename)
                metadata = entry.filename in {".gitignore", ".moonignore"}
                assert not path.is_absolute() and not any(part == ".." or (part.startswith(".") and not metadata) for part in path.parts), entry.filename
                assert path.parts[0] in allowed_roots or (len(path.parts) == 1 and
                    (path.suffix in {".mbt", ".mbti"} or path.name in {".gitignore", ".moonignore", "moon.mod", "moon.pkg", "package.json", "package-lock.json", "README.md", "LICENSE"})), entry.filename
                assert not entry.is_dir(), entry.filename
                data = package.read(entry)
                text = data.decode("utf-8")
                clean = re.sub(r'https?://[^\s<>"\x27]+', '', text)
                assert not path_pattern.search(clean), f"Local path in archive: {entry.filename}"
                destination = library.joinpath(*path.parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
        for required in [".gitignore", ".moonignore", "moon.mod", "moon.pkg", "LICENSE", "package-lock.json", "pkg.generated.mbti", "integrations/coap/moon.pkg"]:
            assert required in names, required
        (workspace / "moon.work").write_text('members = ["library", "consumer"]\n', encoding="utf-8")
        consumer = workspace / "consumer"
        consumer.mkdir()
        (consumer / "moon.mod").write_text(f'name = "validation/consumer"\nversion = "0.1.0"\npreferred_target = "wasm-gc"\nimport {{ "{name}@{version}" }}\n', encoding="utf-8")
        (consumer / "moon.pkg").write_text(f'import {{ "{name}", "{name}/integrations/coap" @coap }}\n', encoding="utf-8")
        (consumer / "consumer.mbt").write_text('''///|
pub fn normalize(input : Bytes) -> String raise @senweave.SenmlError {
  @senweave.parse_payload(input, @senweave.SenmlJson).resolve().to_json_string()
}

///|
pub fn new_collector() -> @coap.Collector {
  @coap.Collector::new(deferred=true, idempotency=true)
}
''', encoding="utf-8")
        (consumer / "consumer_test.mbt").write_text('''///|
test "archive consumer preserves integer text and crosses public CBOR APIs" {
  let input = b"[{\\"n\\":\\"counter\\",\\"v\\":18446744073709551615,\\"t\\":1793000000}]"
  let text = @consumer.normalize(input)
  assert_eq(text.contains("18446744073709551615"), true)
  let wire = @senweave.parse_json(text).to_cbor_bytes()
  assert_eq(@senweave.parse_cbor(wire).resolve().to_json_string(), text)
  let raw = @senweave.parse_cbor(b"\\x81\\xbf\\x00\\x61x\\x02\\x3b\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff")
  let raw_json = raw.to_json_string()
  assert_eq(raw_json.contains("-18446744073709551615"), true)
  assert_eq(@senweave.parse_json(raw_json).to_cbor_bytes(), raw.to_cbor_bytes())
}

///|
test "archive consumer completes a public deferred CoAP delivery" {
  let collector = @consumer.new_collector()
  let key = @coap.BusinessKey::from_queries(["source=external", "key=one"]).unwrap().unwrap()
  assert_eq(key.source, "external")
  let events = collector.receive("peer", b"\\x41\\x02\\x00\\x0a\\x01\\xb6ingest\\x11\\x6e\\xff[]", 0L, 1793000000.0)
  let mut completed = false
  for event in events {
    if event is @coap.Pending(delivery, _, _) {
      for finished in delivery.complete(@coap.Stored, 1L) {
        if finished is @coap.Completed(_, _) { completed = true }
      }
    }
  }
  assert_eq(completed, true)
  assert_eq(collector.pending_count(), 0)
}

///|
test "archive consumer exchanges XML using only the public library" {
  let raw = @senweave.parse_xml("<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml bn='sensor:' bt='1793000000' n='counter' v='9007199254740993'/></sensml>")
  let xml = raw.to_xml_string()
  assert_eq(xml.contains("9007199254740993"), true)
  let copy = @senweave.parse_xml(xml)
  assert_eq(copy.resolve().to_json_string(), raw.resolve().to_json_string())
  assert_eq(@senweave.parse_xml(copy.resolve().to_xml_string()).resolve().to_json_string(), raw.resolve().to_json_string())
  assert_eq(@senweave.SenmlXml.coap_content_format(), 310)
}

///|
test "archive consumer uses typed binary content formats across codecs" {
  let spec = @senweave.ContentFormatSpec::parse("60")
  assert_eq(spec.coap_number(), Some(60))
  let raw = @senweave.parse_json("[{\\\"bct\\\":\\\"60\\\"},{\\\"n\\\":\\\"blob\\\",\\\"vd\\\":\\\"AA\\\",\\\"t\\\":1793000000}]")
  assert_eq(raw.record(0).unwrap().base_content_format.unwrap().as_string(), "60")
  let copy = @senweave.parse_xml(@senweave.parse_cbor(raw.to_cbor_bytes()).to_xml_string())
  assert_eq(copy.resolve().record(0).unwrap().content_format.unwrap().coap_number(), Some(60))
  assert_eq(copy.ignored_extension_count(), 0)
}

///|
test "archive consumer diagnostics retain standard labels but omit extension names" {
  for (input, expected) in [
    ("[{\\"n\\":\\"x\\",\\"v\\":\\"secret-value\\"}]", Some("v")),
    ("[{\\"n\\":\\"x\\",\\"v\\":1,\\"private-key_\\":true}]", None),
  ] {
    try @senweave.parse_json(input) catch {
      error => assert_eq(error.diagnostic().field, expected)
    } noraise {
      _ => fail("Expected a diagnostic.")
    }
  }
}
///|
test "archive consumer uses a public SenML sender without socket dependencies" {
  let sender = @coap.Sender::new("gateway", 123L).unwrap()
  let key = @coap.BusinessKey::from_queries(["source=room-a", "key=batch-1"]).unwrap().unwrap()
  let events = sender.send(b"[{\\"n\\":\\"temperature\\",\\"v\\":22.5,\\"t\\":-3}]", @senweave.SenmlJson, 0L, 0, business_key=key)
  let retry = sender.poll(2000L)
  guard events[0] is @coap.Transmit(first) else { fail("first request") }
  guard retry[0] is @coap.Transmit(second) else { fail("request retry") }
  assert_eq(first, second)
  assert_eq(sender.is_pending(), true)
  let cancelled = sender.cancel(6000L)
  assert_eq(cancelled.length(), 1)
  assert_eq(cancelled[0] is @coap.Cancelled(_), true)
}
''', encoding="utf-8")
        run(["moon", "check", "--target", "all", "--deny-warn"], consumer)
        consumer_cases = len(re.findall(r'^test "', (consumer / "consumer_test.mbt").read_text(encoding="utf-8"), re.M))
        for target in targets:
            output = run(["moon", "test", "--package", "validation/consumer", "--target", target], consumer)
            assert f"Total tests: {consumer_cases}, passed: {consumer_cases}, failed: 0." in output, output
        print(json.dumps({"module": name, "version": version, "archive_files": len(names),
            "targets": targets, "consumer_cases": consumer_cases, "status": "passed", "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=["all", "native", "js", "wasm-gc"], default="all")
    args = parser.parse_args()
    main(["native", "js", "wasm-gc"] if args.target == "all" else [args.target])
