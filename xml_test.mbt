///|
test "XML shares all base fields and measurement types with JSON and CBOR" {
  let input = "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml bn='sensor:' bt='1793000000' bu='Cel' bv='20' bs='100' bver='10'/><senml n='temperature' v='2.5' t='-3' s='1' ut='30'/><senml n='door' vb='false' u='/'/><senml n='label' vs='门&#10;🚪' u=''/><senml n='blob' vd='AP8' u='/'/><senml n='counter' bv='0' v='9007199254740993'/></sensml>"
  let raw = @senweave.parse_xml(input)
  assert_eq(raw.len(), 6)
  assert_eq(raw.measurement_count(), 5)
  let resolved = raw.resolve()
  assert_eq(resolved.record(0).unwrap().name, "sensor:temperature")
  assert_eq(resolved.record(0).unwrap().time.json_literal(), "1792999997")
  let xml = raw.to_xml_string()
  assert_eq(xml.contains("9007199254740993"), true)
  assert_eq(xml.contains("&#10;"), true)
  assert_eq(@senweave.parse_xml(xml).to_cbor_bytes(), raw.to_cbor_bytes())
  assert_eq(
    @senweave.parse_xml(resolved.to_xml_string()).resolve().to_json_string(),
    resolved.to_json_string(),
  )
  assert_eq(
    @senweave.parse_xml(resolved.record(0).unwrap().to_xml_string()).len(),
    1,
  )
}

///|
test "XML namespace prefixes and XML numeric lexical forms are understood" {
  let raw = @senweave.parse_xml(
    "<?xml version='1.0' encoding='UTF-8'?><s:sensml xmlns:s='urn:ietf:params:xml:ns:senml'><!--note--><?host info?><s:senml n='one' v='+0001.' t='1793000000' bver='+010'/><s:senml n='two' v='.50E+1' t='1793000001'/><s:senml n='flag' vb='0' t='1793000002'/></s:sensml>",
  )
  assert_eq(raw.record(0).unwrap().base_version.unwrap().json_literal(), "10")
  assert_eq(raw.record(0).unwrap().value is Some(@senweave.Numeric(_)), true)
  guard raw.record(1).unwrap().value is Some(@senweave.Numeric(number)) else {
    fail("Expected number.")
  }
  assert_eq(number.as_double(), 5.0)
  assert_eq(raw.to_xml_string().contains("bver=\"10\""), true)
}

///|
test "XML explicit zero and empty bases survive raw and independent output" {
  let raw = @senweave.parse_xml(
    "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml bn='device:' bt='1792999900' bu='Cel' bv='20' bs='100' n='one' v='1' s='1'/><senml bn='' bt='0' bu='' bv='0' bs='0' n='two' v='2' s='2' vs2='optional'/></sensml>",
  )
  let text = raw.resolve(reference_time=1793000000.0).to_json_string()
  assert_eq(text.contains("\"n\":\"two\""), true)
  assert_eq(raw.ignored_extension_count(), 1)
  assert_eq(
    @senweave.parse_xml(raw.to_xml_string())
    .resolve(reference_time=1793000000.0)
    .to_json_string(),
    text,
  )
}

///|
test "XML character references preserve attribute whitespace and escaped text" {
  let raw = @senweave.parse_json(
    "[{\"n\":\"x\",\"vs\":\"\\t\\r\\n<&>\\\"'门🚪\",\"t\":1793000000}]",
  )
  assert_eq(
    @senweave.parse_xml(raw.to_xml_string()).to_json_string(),
    raw.to_json_string(),
  )
  assert_eq(
    @senweave.parse_xml(
      "\u{FEFF}<sensml xmlns='urn:ietf:params:xml:ns:senml'/>",
    ).len(),
    0,
  )
}

///|
fn xml_rejected(
  input : String,
  code : @senweave.ErrorCode,
  limits~ : @senweave.ParseLimits = @senweave.ParseLimits::default(),
) -> @senweave.Diagnostic raise {
  try @senweave.parse_xml(input, limits~) catch {
    error => {
      assert_eq(error.diagnostic().code, code)
      error.diagnostic()
    }
  } noraise {
    _ => fail("Expected XML rejection.")
  }
}

///|
test "XML malformed structures namespace errors and duplicate attributes fail" {
  for
    input in [
      "", "<sensml/>", "<sensml xmlns='urn:other'/>", "<senml xmlns='urn:ietf:params:xml:ns:senml'/>",
      "<s:sensml/>", "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='1' v='2'/></sensml>",
      "<sensml xmlns='urn:ietf:params:xml:ns:senml' xmlns:a='urn:ext' xmlns:b='urn:ext'><senml n='x' v='1' a:key='a' b:key='b'/></sensml>",
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml xmlns='' n='x' v='1'/></sensml>",
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='1'><nested/></senml></sensml>",
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'>unexpected text</sensml>", "<sensml xmlns='urn:ietf:params:xml:ns:senml'/><sensml xmlns='urn:ietf:params:xml:ns:senml'/>",
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' vs='&unknown;'/></sensml>",
    ] {
    ignore(xml_rejected(input, @senweave.InvalidXml))
  }
}

///|
test "XML truncation never exposes a partially parsed pack" {
  let input = "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='1'/></sensml>"
  for length in 0..<input.length() {
    try @senweave.parse_xml(input[:length].to_owned()) catch {
      _ => ()
    } noraise {
      _ => fail("Incomplete document accepted.")
    }
  }
}

///|
test "XML DTD declarations are refused and comment lookalikes remain valid" {
  for
    prefix in [
      "<!DOCTYPE sensml SYSTEM 'urn:external:blocked'>", "<!DOCTYPE sensml [<!ENTITY item 'value'>]>",
      "<!DOCTYPE sensml [<!ENTITY a 'x'><!ENTITY b '&a;&a;&a;'>]>",
    ] {
    ignore(
      xml_rejected(
        prefix + "<sensml xmlns='urn:ietf:params:xml:ns:senml'/>",
        @senweave.UnsupportedXmlFeature,
      ),
    )
  }
  assert_eq(
    @senweave.parse_xml(
      "<!-- <!DOCTYPE sensml> --><sensml xmlns='urn:ietf:params:xml:ns:senml'/>",
    ).len(),
    0,
  )
  ignore(
    xml_rejected(
      "<?xml version='1.0' encoding='ISO-8859-1'?><sensml xmlns='urn:ietf:params:xml:ns:senml'/>",
      @senweave.UnsupportedXmlFeature,
    ),
  )
}

///|
test "XML optional and mandatory extensions follow shared ingress policy" {
  let input = "<sensml xmlns='urn:ietf:params:xml:ns:senml' xmlns:e='urn:ext'><senml n='x' v='1' e:v='ignored' vendor='revision'/></sensml>"
  let raw = @senweave.parse_xml(input)
  assert_eq(raw.ignored_extension_count(), 2)
  assert_eq(raw.to_xml_string().contains("vendor"), false)
  let diagnostic = xml_rejected(
    "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='private-device' v='1' private_='secret'/></sensml>",
    @senweave.UnsupportedExtension,
  )
  assert_eq(diagnostic.field, None)
  assert_eq(diagnostic.message.contains("secret"), false)
  assert_eq(diagnostic.message.contains("private"), false)
}

///|
test "XML invalid lexical numbers retain standard field diagnostics" {
  for
    value in [
      "", "+", ".", "1e", "1e+", "1_000", "1 2", "0x10", "INF", "NaN", "1e309", "1e-999",
    ] {
    let diagnostic = xml_rejected(
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='" +
      value +
      "'/></sensml>",
      @senweave.InvalidNumber,
    )
    assert_eq(diagnostic.field, Some("v"))
    assert_eq(diagnostic.record_index, Some(0))
  }
  ignore(
    xml_rejected(
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='1' bver='10.0'/></sensml>",
      @senweave.InvalidNumber,
    ),
  )
  ignore(
    xml_rejected(
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' vb='yes'/></sensml>",
      @senweave.WrongType,
    ),
  )
}

///|
test "XML semantic constraints reuse existing validation" {
  for
    (attributes, code) in [
      ("n='x' v='1' vb='false'", @senweave.ConflictingValues),
      ("n='x'", @senweave.MissingValue),
      ("n='bad name' v='1'", @senweave.InvalidName),
      ("n='x' vd='AP8='", @senweave.InvalidData),
      ("n='x' vd='A'", @senweave.InvalidData),
      ("n='x' v='1' bver='99'", @senweave.UnsupportedVersion),
    ] {
    ignore(
      xml_rejected(
        "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml " +
        attributes +
        "/></sensml>",
        code,
      ),
    )
  }
}

///|
test "XML input record depth attribute string and number quotas apply" {
  let defaults = @senweave.ParseLimits::default()
  let input = "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='123'/><senml n='y' v='2'/></sensml>"
  for
    (limits, code) in [
      ({ ..defaults, max_input_code_units: 5, }, @senweave.InputLimit),
      ({ ..defaults, max_records: 1, }, @senweave.RecordLimit),
      ({ ..defaults, max_depth: 1, }, @senweave.NestingLimit),
      ({ ..defaults, max_fields_per_record: 1, }, @senweave.FieldLimit),
      ({ ..defaults, max_number_code_units: 2, }, @senweave.NumberLimit),
      ({ ..defaults, max_depth: 0, }, @senweave.InvalidLimits),
    ] {
    ignore(xml_rejected(input, code, limits~))
  }
  ignore(
    xml_rejected(
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='long-name' v='1'/></sensml>",
      @senweave.StringLimit,
      limits={ ..defaults, max_string_code_units: 3, },
    ),
  )
  ignore(
    xml_rejected(
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='1' vendor='long-value'/></sensml>",
      @senweave.StringLimit,
      limits={ ..defaults, max_string_code_units: 6, },
    ),
  )
}

///|
test "XML encoder rejects unrepresentable JSON characters and output overruns" {
  let raw = @senweave.parse_json("[{\"n\":\"x\",\"vs\":\"\\u0000\"}]")
  try raw.to_xml_string() catch {
    error => assert_eq(error.diagnostic().code, @senweave.InvalidXml)
  } noraise {
    _ => fail("XML cannot represent NUL.")
  }
  let empty = @senweave.parse_json("[]")
  for
    (limit, code) in [(0, @senweave.InvalidLimits), (1, @senweave.OutputLimit)] {
    try empty.to_xml_string(max_output_code_units=limit) catch {
      error => assert_eq(error.diagnostic().code, code)
    } noraise {
      _ => fail("Expected output budget rejection.")
    }
  }
}

///|
test "XML byte ingress and extension admission share transport quotas" {
  let input = b"<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='1' vendor='extra'/></sensml>"
  assert_eq(@senweave.parse_payload(input, @senweave.SenmlXml).len(), 1)
  for
    (bytes, strict, limit, code) in [
      (input, true, 1024, @senweave.IgnoredExtensions),
      (input, false, 1, @senweave.InputLimit),
      (b"\xff", false, 1024, @senweave.InvalidUtf8),
    ] {
    try
      @senweave.parse_payload(
        bytes,
        @senweave.SenmlXml,
        reject_extensions=strict,
        max_input_bytes=limit,
      )
    catch {
      error => assert_eq(error.diagnostic().code, code)
    } noraise {
      _ => fail("Expected ingress rejection.")
    }
  }
  assert_eq(
    @senweave.Format::from_content_type(
      "application/senml+xml; charset=\"UTF-8\"",
    ),
    Some(@senweave.SenmlXml),
  )
  assert_eq(@senweave.Format::from_content_type("application/sensml+xml"), None)
}
