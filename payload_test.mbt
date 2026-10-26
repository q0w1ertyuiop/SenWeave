///|
test "content types and CoAP format IDs recognize only finite SenML packs" {
  for format in [@senweave.SenmlJson, @senweave.SenmlCbor] {
    assert_eq(
      @senweave.Format::from_content_type(format.content_type()),
      Some(format),
    )
    assert_eq(
      @senweave.Format::from_coap_content_format(format.coap_content_format()),
      Some(format),
    )
  }
  for
    input in [
      " APPLICATION/SENML+JSON \t", "application/senml+json; charset=utf-8", "application/senml+json; Charset = \"UTF-8\"",
    ] {
    assert_eq(
      @senweave.Format::from_content_type(input),
      Some(@senweave.SenmlJson),
    )
  }
  for
    input in [
      "application/json", "application/cbor", "application/sensml+json", "application/senml+cbor; charset=utf-8",
      "application/senml+json; charset=ascii", "application/senml+json; charset=utf-8; charset=utf-8",
      "application/senml+json\r\n", "",
    ] {
    assert_eq(@senweave.Format::from_content_type(input), None)
  }
  for id in [-1, 50, 60, 111, 113, 65535] {
    assert_eq(@senweave.Format::from_coap_content_format(id), None)
  }
}

///|
fn payload_rejected(
  input : Bytes,
  code : @senweave.ErrorCode,
  max_input_bytes~ : Int32 = 1_048_576,
) -> Unit raise {
  try
    @senweave.parse_payload(input, @senweave.SenmlJson, max_input_bytes~)
  catch {
    error => assert_eq(error.diagnostic().code, code)
  } noraise {
    _ => fail("Expected payload rejection.")
  }
}

///|
test "byte ingress checks UTF-8 and byte limits before creating JSON text" {
  payload_rejected(b"\xff", @senweave.InvalidUtf8)
  payload_rejected(b"\xed\xa0\x80", @senweave.InvalidUtf8)
  payload_rejected(b"\xef\xbb\xbf[]", @senweave.InvalidJson)
  payload_rejected(b"\xff\xff", @senweave.InputLimit, max_input_bytes=1)
  payload_rejected(b"[]", @senweave.InvalidLimits, max_input_bytes=0)
}

///|
test "payload formats share resolution and exact integer preservation" {
  let json = b"[{\"bn\":\"sensor:\",\"bt\":1793000000},{\"n\":\"counter\",\"v\":9007199254740993}]"
  let raw = @senweave.parse_payload(json, @senweave.SenmlJson)
  let via_cbor = @senweave.parse_payload(
    raw.to_cbor_bytes(),
    @senweave.SenmlCbor,
  )
  assert_eq(raw.resolve().to_json_string(), via_cbor.resolve().to_json_string())
  assert_eq(raw.resolve().to_json_string().contains("9007199254740993"), true)
}

///|
test "ingress extension policy counts context fields and can reject data loss" {
  let bytes = b"[{\"bn\":\"x:\",\"vendor\":1},{\"n\":\"t\",\"v\":1,\"other\":false}]"
  let raw = @senweave.parse_payload(bytes, @senweave.SenmlJson)
  assert_eq(raw.ignored_extension_count(), 2)
  try
    @senweave.parse_payload(bytes, @senweave.SenmlJson, reject_extensions=true)
  catch {
    error => assert_eq(error.diagnostic().code, @senweave.IgnoredExtensions)
  } noraise {
    _ => fail("Strict ingress must reject extension loss.")
  }
  try
    @senweave.parse_payload(
      raw.to_cbor_bytes(),
      @senweave.SenmlCbor,
      max_input_bytes=1,
    )
  catch {
    error => assert_eq(error.diagnostic().code, @senweave.InputLimit)
  } noraise {
    _ => fail("CBOR ingress must check byte limit.")
  }
}
