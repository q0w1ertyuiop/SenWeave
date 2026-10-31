///|
// The comparison host passes payloads as strings so exact JSON numbers never
// pass through a JavaScript Number. This executable is a verification adapter.
pub fn compare_payload(input : String, format : String, now : Double) -> String {
  let report : Map[String, Json] = Map([])
  let bytes = if format == "cbor" {
    @hex.decode(input) catch {
      _ => return "{\"stage\":\"decode_validate\",\"error\":\"InvalidHex\"}"
    }
  } else {
    b""
  }
  let raw = try {
    if format == "xml" {
      @senweave.parse_xml(input)
    } else if format == "json" {
      @senweave.parse_json(input)
    } else {
      @senweave.parse_cbor(bytes)
    }
  } catch {
    error => {
      report["stage"] = Json::string("decode_validate")
      report["error"] = Json::string("\{Repr(error.diagnostic().code)}")
      return Json::object(report).stringify()
    }
  }
  try {
    report["raw_json"] = Json::string(raw.to_json_string())
    report["raw_cbor"] = Json::string(@hex.encode(raw.to_cbor_bytes()))
  } catch {
    error => {
      report["stage"] = Json::string("encode_raw")
      report["error"] = Json::string("\{Repr(error.diagnostic().code)}")
      return Json::object(report).stringify()
    }
  }
  try {
    report["raw_xml"] = Json::string(raw.to_xml_string())
  } catch {
    error =>
      report["raw_xml_error"] = Json::string("\{Repr(error.diagnostic().code)}")
  }
  try {
    let resolved = raw.resolve(reference_time=now)
    report["resolved_json"] = Json::string(resolved.to_json_string())
    try {
      report["resolved_xml"] = Json::string(resolved.to_xml_string())
    } catch {
      error =>
        report["resolved_xml_error"] = Json::string(
          "\{Repr(error.diagnostic().code)}",
        )
    }
    report["resolved_cbor"] = Json::string(
      @hex.encode(resolved.to_cbor_bytes()),
    )
    report["stage"] = Json::string("resolved")
  } catch {
    error => {
      report["stage"] = Json::string("resolve")
      report["error"] = Json::string("\{Repr(error.diagnostic().code)}")
    }
  }
  Json::object(report).stringify()
}

///|
fn main {
  ()
}
