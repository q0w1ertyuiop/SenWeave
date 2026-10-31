///|
test "raw JSON serialization preserves bases order relative time and numeric spelling" {
  let source = "[{\"bn\":\"sensor:\",\"bv\":0,\"bs\":100,\"bu\":\"Cel\",\"bver\":1e1},{\"n\":\"counter\",\"v\":9007199254740993,\"t\":-3,\"s\":0,\"ut\":30},{\"n\":\"flag\",\"vb\":false},{\"n\":\"text\",\"vs\":\"\"},{\"n\":\"data\",\"vd\":\"AP8\"}]"
  let raw = @senweave.parse_json(source)
  let json = raw.to_json_string()
  assert_eq(json.contains("9007199254740993"), true)
  assert_eq(json.contains("1e1"), true)
  let copy = @senweave.parse_json(json)
  assert_eq(copy.len(), raw.len())
  assert_eq(copy.record(0).unwrap().base_name, Some("sensor:"))
  assert_eq(copy.record(1).unwrap().time.unwrap().json_literal(), "-3")
  assert_eq(copy.to_cbor_bytes(), raw.to_cbor_bytes())
  assert_eq(
    copy.resolve(reference_time=1793000000.0).to_json_string(),
    raw.resolve(reference_time=1793000000.0).to_json_string(),
  )
}

///|
test "raw JSON encoding provides an independent CBOR conversion without a clock" {
  let raw = @senweave.parse_cbor(
    b"\x81\xbf\x00\x61x\x02\x3b\xff\xff\xff\xff\xff\xff\xff\xfe\xff",
  )
  let json = raw.to_json_string()
  assert_eq(json.contains("-18446744073709551615"), true)
  assert_eq(@senweave.parse_json(json).to_cbor_bytes(), raw.to_cbor_bytes())
  assert_eq(
    @senweave.parse_json("[{\"bn\":\"sensor:\"}]")
    .to_json_string()
    .contains("bn"),
    true,
  )
  let optional = @senweave.parse_json("[{\"n\":\"x\",\"v\":1,\"vendor\":true}]")
  assert_eq(optional.to_json_string().contains("vendor"), false)
  assert_eq(optional.ignored_extension_count(), 1)
}

///|
test "raw JSON output budgets bound escaping and do not change the original pack" {
  let empty = @senweave.parse_json("[]")
  assert_eq(empty.to_json_string(max_output_code_units=2), "[]")
  let raw = @senweave.parse_json("[{\"n\":\"x\",\"vs\":\"\\u0000\\\"\\\\\"}]")
  for
    (pack, limit, expected) in [
      (empty, 0, @senweave.InvalidLimits),
      (empty, 1, @senweave.OutputLimit),
      (raw, 5, @senweave.OutputLimit),
    ] {
    try pack.to_json_string(max_output_code_units=limit) catch {
      error => assert_eq(error.diagnostic().code, expected)
    } noraise {
      _ => fail("Expected output budget failure.")
    }
  }
  let json = raw.to_json_string(max_output_code_units=256)
  assert_eq(json.length() <= 256, true)
  assert_eq(@senweave.parse_json(json).to_cbor_bytes(), raw.to_cbor_bytes())
}
