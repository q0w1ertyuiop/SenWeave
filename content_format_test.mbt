///|
test "content formats retain numeric identifiers and registered or future names" {
  for
    (text, number) in [
      ("0", Some(0)),
      ("60", Some(60)),
      ("65535", Some(65535)),
      ("65000", Some(65000)),
    ] {
    let spec = @senweave.ContentFormatSpec::parse(text)
    assert_eq(spec.as_string(), text)
    assert_eq(spec.coap_number(), number)
  }
  for
    text in [
      "application/json", "application/json@deflate@aes128gcm", "text/csv;header=present@gzip",
      "text/plain; charset=utf-8@deflate", "Application/X-Future+CBOR;v=1", "text/plain;title=\"x@home;y=1\"@gzip",
      "text/plain;x=\"a\\\"b\\\\c\"", "text/plain;x=\"\"", "text/plain ; x=!#$%&'*+-.^_`|~",
    ] {
    let spec = @senweave.ContentFormatSpec::parse(text)
    assert_eq(spec.as_string(), text)
    assert_eq(spec.coap_number(), None)
  }
}

///|
fn bad_content_format(input : String) -> Unit raise {
  try @senweave.ContentFormatSpec::parse(input) catch {
    error => {
      assert_eq(error.diagnostic().code, @senweave.InvalidContentFormat)
      assert_eq(error.diagnostic().field, None)
    }
  } noraise {
    _ => fail("Expected invalid content format.")
  }
}

///|
test "content format ABNF rejects malformed numbers names parameters and codings" {
  for
    text in [
      "", "00", "060", "65536", "9999999999999999999999999", "-1", "+60", "60.0",
      "6e1", "60@gzip", "text", "/plain", "text/", "text/*", "*/plain", "text/pl%ain",
      "text/plain ", "text/plain\t;x=1", "text/plain;", "text/plain;x", "text/plain;x=",
      "text/plain;x =a", "text/plain;x= a", "text/plain;x=\"a", "text/plain;x=\"a\"z",
      "text/plain;x=\"a\\", "text/plain;x=\"a\n\"", "text/plain;x=\"a\\\t\"", "text/plain;x=\"中文\"",
      "text/plain@", "text/plain@@gzip", "text/plain@gzip ", "text/plain@gzip;x=1",
      " text/plain", "text/中文",
    ] {
    bad_content_format(text)
  }
}

///|
test "content format name bounds apply to each name separately" {
  let name = String::make(127, 'a')
  assert_eq(
    @senweave.ContentFormatSpec::parse(name + "/" + name).as_string(),
    name + "/" + name,
  )
  bad_content_format(name + "a/plain")
  bad_content_format("text/" + name + "a")
  try @senweave.ContentFormatSpec::parse("text/plain", max_code_units=4) catch {
    error => assert_eq(error.diagnostic().code, @senweave.StringLimit)
  } noraise {
    _ => fail("Expected string limit.")
  }
  try @senweave.ContentFormatSpec::parse("0", max_code_units=0) catch {
    error => assert_eq(error.diagnostic().code, @senweave.InvalidLimits)
  } noraise {
    _ => fail("Expected invalid limit.")
  }
}

///|
test "base content format applies to current and later binary records only" {
  let raw = @senweave.parse_json(
    (
      #|[{"bn":"sensor:","bct":"60","bt":1793000000},
      #| {"n":"one","vd":"AA"},{"n":"temp","v":7.1},
      #| {"n":"photo","vd":"AP8","ct":"image/png"},
      #| {"n":"two","vd":"AQ"},{"bct":"0","n":"text","vs":"ok"},
      #| {"n":"three","vd":""}]
    ),
  )
  assert_eq(raw.ignored_extension_count(), 0)
  assert_eq(
    raw.record(0).unwrap().base_content_format.unwrap().coap_number(),
    Some(60),
  )
  assert_eq(raw.record(1).unwrap().content_format is None, true)
  let records = raw.resolve()
  assert_eq(records.len(), 6)
  assert_eq(
    records.record(0).unwrap().content_format.unwrap().as_string(),
    "60",
  )
  assert_eq(records.record(1).unwrap().content_format is None, true)
  assert_eq(
    records.record(2).unwrap().content_format.unwrap().as_string(),
    "image/png",
  )
  assert_eq(
    records.record(3).unwrap().content_format.unwrap().as_string(),
    "60",
  )
  assert_eq(records.record(4).unwrap().content_format is None, true)
  assert_eq(
    records.record(5).unwrap().content_format.unwrap().coap_number(),
    Some(0),
  )
}

///|
test "base-only formats survive all raw codecs and resolve after sorting" {
  let raw = @senweave.parse_json(
    "[{\"bct\":\"image/png\"},{\"n\":\"late\",\"vd\":\"AQ\",\"t\":1793000002},{\"bct\":\"60\",\"n\":\"early\",\"vd\":\"AA\",\"t\":1793000000}]",
  )
  let expected = raw.to_json_string()
  for
    copy in [
      @senweave.parse_json(expected),
      @senweave.parse_cbor(raw.to_cbor_bytes()),
      @senweave.parse_xml(raw.to_xml_string()),
    ] {
    assert_eq(copy.to_json_string(), expected)
    let resolved = copy.resolve()
    assert_eq(resolved.record(0).unwrap().name, "early")
    assert_eq(
      resolved.record(0).unwrap().content_format.unwrap().as_string(),
      "60",
    )
    assert_eq(
      resolved.record(1).unwrap().content_format.unwrap().as_string(),
      "image/png",
    )
    let independent = resolved.filter(record => record.name == "late")
    assert_eq(
      @senweave.parse_json(independent.to_json_string())
      .resolve()
      .to_json_string(),
      independent.to_json_string(),
    )
    assert_eq(
      @senweave.parse_cbor(independent.record(0).unwrap().to_cbor_bytes())
      .resolve()
      .to_json_string(),
      independent.to_json_string(),
    )
    assert_eq(
      @senweave.parse_xml(independent.record(0).unwrap().to_xml_string())
      .resolve()
      .to_json_string(),
      independent.to_json_string(),
    )
  }
}

///|
test "explicit formats are legal only on binary data values" {
  for
    input in [
      "[{\"n\":\"x\",\"v\":1,\"ct\":\"60\"}]", "[{\"n\":\"x\",\"vs\":\"AA\",\"ct\":\"60\"}]",
      "[{\"n\":\"x\",\"vb\":false,\"ct\":\"60\"}]", "[{\"n\":\"x\",\"s\":1,\"ct\":\"60\"}]",
      "[{\"bct\":\"60\",\"ct\":\"0\"}]",
    ] {
    try @senweave.parse_json(input) catch {
      error => {
        assert_eq(error.diagnostic().code, @senweave.InvalidRecord)
        assert_eq(error.diagnostic().field, Some("ct"))
      }
    } noraise {
      _ => fail("Expected data-value requirement.")
    }
  }
}

///|
test "invalid format values are rejected with safe field diagnostics" {
  for
    (input, field, code) in [
      ("[{\"bct\":\"\"}]", "bct", @senweave.InvalidContentFormat),
      (
        "[{\"n\":\"private-device\",\"vd\":\"AA\",\"ct\":\"private-format\"}]",
        "ct",
        @senweave.InvalidContentFormat,
      ),
      ("[{\"n\":\"x\",\"vd\":\"AA\",\"ct\":60}]", "ct", @senweave.WrongType),
      ("[{\"bct\":null}]", "bct", @senweave.WrongType),
    ] {
    try @senweave.parse_json(input) catch {
      error => {
        assert_eq(error.diagnostic().code, code)
        assert_eq(error.diagnostic().field, Some(field))
        assert_eq(error.diagnostic().record_index, Some(0))
        assert_eq(error.diagnostic().message.contains("private"), false)
      }
    } noraise {
      _ => fail("Expected content-format rejection.")
    }
  }
}

///|
test "CBOR uses text extension keys with byte-string data values" {
  let wire = b"\x81\xa4\x00\x61x\x08\x41\x00\x62ct\x6260\x63bct\x610"
  let raw = @senweave.parse_cbor(wire)
  assert_eq(raw.to_cbor_bytes(), wire)
  for end in 0..<wire.length() {
    try @senweave.parse_cbor(wire[:end].to_owned()) catch {
      _ => ()
    } noraise {
      _ => fail("A truncated content-format record must not be returned.")
    }
  }
  assert_eq(
    raw.record(0).unwrap().content_format.unwrap().coap_number(),
    Some(60),
  )
  assert_eq(
    raw.record(0).unwrap().base_content_format.unwrap().coap_number(),
    Some(0),
  )
  let chunked = @senweave.parse_cbor(
    b"\x81\xa3\x00\x61x\x08\x41\x00\x7f\x61c\x61t\xff\x7f\x616\x610\xff",
  )
  assert_eq(
    chunked.record(0).unwrap().content_format.unwrap().as_string(),
    "60",
  )
  ignore(
    cbor_rejected(
      b"\x81\xa3\x00\x61x\x08\x41\x00\x62ct\x18\x3c",
      @senweave.WrongType,
    ),
  )
  ignore(
    cbor_rejected(
      b"\x81\xa4\x00\x61x\x08\x41\x00\x62ct\x6260\x62ct\x610",
      @senweave.DuplicateKey,
    ),
  )
}

///|
test "XML attributes retain quoted parameters and do not promote qualified ct" {
  let raw = @senweave.parse_xml(
    "<sensml xmlns='urn:ietf:params:xml:ns:senml' xmlns:e='urn:ext'><senml bct='text/plain;title=&quot;a@b;c&quot;@gzip'/><senml n='x' vd='AA' e:ct='future'/></sensml>",
  )
  assert_eq(raw.ignored_extension_count(), 1)
  assert_eq(
    raw.resolve(reference_time=1793000000.0).record(0).unwrap().content_format
    .unwrap()
    .as_string(),
    "text/plain;title=\"a@b;c\"@gzip",
  )
  assert_eq(
    @senweave.parse_xml(raw.to_xml_string()).record(0).unwrap().base_content_format
    .unwrap()
    .as_string(),
    "text/plain;title=\"a@b;c\"@gzip",
  )
  ignore(
    xml_rejected(
      "<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' vd='AA' ct='060'/></sensml>",
      @senweave.InvalidContentFormat,
    ),
  )
}

///|
test "strict payload admission understands both format fields across codecs" {
  let raw = @senweave.parse_json(
    "[{\"bct\":\"60\"},{\"n\":\"x\",\"vd\":\"AA\",\"ct\":\"0\"}]",
  )
  for
    (bytes, format) in [
      (@utf8.encode(raw.to_json_string()), @senweave.SenmlJson),
      (raw.to_cbor_bytes(), @senweave.SenmlCbor),
      (@utf8.encode(raw.to_xml_string()), @senweave.SenmlXml),
    ] {
    let copy = @senweave.parse_payload(bytes, format, reject_extensions=true)
    assert_eq(copy.ignored_extension_count(), 0)
    assert_eq(
      copy.resolve(reference_time=1793000000.0).record(0).unwrap().content_format
      .unwrap()
      .as_string(),
      "0",
    )
  }
}

///|
test "inherited format strings count toward expansion and output budgets" {
  let text = "application/" + String::make(100, 'a')
  let raw = @senweave.parse_json(
    "[{\"bct\":\"" + text + "\"},{\"n\":\"x\",\"vd\":\"AA\",\"t\":1793000000}]",
  )
  try raw.resolve(max_expanded_code_units=300) catch {
    error => assert_eq(error.diagnostic().code, @senweave.ExpansionLimit)
  } noraise {
    _ => fail("Expected inherited format expansion limit.")
  }
  try raw.to_cbor_bytes(max_output_bytes=100) catch {
    error => assert_eq(error.diagnostic().code, @senweave.OutputLimit)
  } noraise {
    _ => fail("Expected CBOR output limit.")
  }
  let limits = { ..@senweave.ParseLimits::default(), max_string_code_units: 4, }
  ignore(cbor_rejected(raw.to_cbor_bytes(), @senweave.StringLimit, limits~))
  ignore(xml_rejected(raw.to_xml_string(), @senweave.StringLimit, limits~))
  for
    input in [
      "[{\"bct\":\"image/png\"}]", "[{\"n\":\"x\",\"vd\":\"AA\",\"ct\":\"image/png\"}]",
    ] {
    try @senweave.parse_json(input, limits~) catch {
      error => assert_eq(error.diagnostic().code, @senweave.StringLimit)
    } noraise {
      _ => fail("Expected string limit.")
    }
  }
}
