///|
fn cbor_rejected(
  input : Bytes,
  code : @senweave.ErrorCode,
  limits~ : @senweave.ParseLimits = @senweave.ParseLimits::default(),
  max_input_bytes~ : Int32 = 1_048_576,
) -> @senweave.Diagnostic raise {
  try @senweave.parse_cbor(input, limits~, max_input_bytes~) catch {
    error => {
      let diagnostic = error.diagnostic()
      assert_eq(diagnostic.code, code)
      diagnostic
    }
  } noraise {
    _ => fail("Expected CBOR rejection.")
  }
}

///|
test "independent integer-key wire fixture and byte-exact JSON to CBOR output" {
  let fixture = b"\x81\xa2\x00\x61x\x02\x01"
  let raw = @senweave.parse_cbor(fixture)
  assert_eq(raw.len(), 1)
  assert_eq(raw.record(0).unwrap().name, Some("x"))
  guard raw.record(0).unwrap().value is Some(@senweave.Numeric(n)) else {
    fail("number")
  }
  assert_eq(n.json_literal(), "1")
  assert_eq(
    @senweave.parse_json("[{\"n\":\"x\",\"v\":1}]").to_cbor_bytes(),
    fixture,
  )
  assert_eq(raw.to_cbor_bytes(), fixture)
}

///|
test "four CBOR value types retain false zero empty strings and byte strings" {
  let raw = @senweave.parse_cbor(
    b"\x84\xa2\x00\x61a\x02\x00\xa2\x00\x61b\x04\xf4\xa2\x00\x61c\x03\x60\xa2\x00\x61d\x08\x40",
  )
  assert_eq(raw.measurement_count(), 4)
  guard raw.record(0).unwrap().value is Some(@senweave.Numeric(number)) else {
    fail("number")
  }
  assert_eq(number.as_double(), 0.0)
  guard raw.record(1).unwrap().value is Some(@senweave.Boolean(flag)) else {
    fail("bool")
  }
  assert_eq(flag, false)
  guard raw.record(2).unwrap().value is Some(@senweave.Text(text)) else {
    fail("text")
  }
  assert_eq(text, "")
  guard raw.record(3).unwrap().value is Some(@senweave.Data(bytes)) else {
    fail("bytes")
  }
  assert_eq(bytes, b"")
}

///|
test "raw JSON CBOR and resolved JSON agree on every base field" {
  let json =
    #|[{"bn":"device:","bt":1793000000,"bu":"Cel","bv":20,"bs":100,"bver":1e1},
    #| {"n":"temp","v":2.5,"s":3,"t":-30,"ut":15},
    #| {"n":"blob","vd":"----____","u":"/"},
    #| {"bn":"other:","bu":"","bv":0,"bs":0,"n":"flag","vb":false,"t":1}]
  let raw = @senweave.parse_json(json)
  let cbor = @senweave.parse_cbor(raw.to_cbor_bytes())
  assert_eq(cbor.len(), raw.len())
  assert_eq(cbor.measurement_count(), 3)
  assert_eq(cbor.record(0).unwrap().base_version.unwrap().json_literal(), "10")
  assert_eq(cbor.resolve().to_json_string(), raw.resolve().to_json_string())
  guard cbor.record(2).unwrap().value is Some(@senweave.Data(bytes)) else {
    fail("bytes")
  }
  assert_eq(bytes, b"\xfb\xef\xbe\xff\xff\xff")
}

///|
test "resolved CBOR records can be forwarded independently after filtering" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"a:","bv":20},{"n":"temp","v":2.5,"t":-2},{"n":"door","vb":false}]
    ),
  ).resolve(reference_time=1793000000.0)
  let filtered = pack.filter(record => record.name == "a:temp")
  assert_eq(
    @senweave.parse_cbor(filtered.to_cbor_bytes()).resolve().to_json_string(),
    filtered.to_json_string(),
  )
  for i in 0..<pack.len() {
    let record = pack.record(i).unwrap()
    let again = @senweave.parse_cbor(record.to_cbor_bytes())
    assert_eq(again.record(0).unwrap().base_name, None)
    assert_eq(again.record(0).unwrap().base_time is None, true)
    assert_eq(again.resolve().to_json_string(), record.to_json_string())
  }
}

///|
test "64-bit integers retain exact source text and wire values" {
  for
    (literal, wire) in [
      (
        "9007199254740993", b"\x81\xa2\x00\x61x\x02\x1b\x00\x20\x00\x00\x00\x00\x00\x01",
      ),
      (
        "18446744073709551615", b"\x81\xa2\x00\x61x\x02\x1b\xff\xff\xff\xff\xff\xff\xff\xff",
      ),
      (
        "-9223372036854775808", b"\x81\xa2\x00\x61x\x02\x3b\x7f\xff\xff\xff\xff\xff\xff\xff",
      ),
    ] {
    let json = "[{\"n\":\"x\",\"v\":\{literal}}]"
    assert_eq(@senweave.parse_json(json).to_cbor_bytes(), wire)
    let raw = @senweave.parse_cbor(wire)
    guard raw.record(0).unwrap().value is Some(@senweave.Numeric(n)) else {
      fail("number")
    }
    assert_eq(n.json_literal(), literal)
    assert_eq(raw.to_cbor_bytes(), wire)
  }
}

///|
test "half single and double precision wire values decode identically" {
  for
    wire in [
      b"\x81\xa2\x00\x61x\x02\xf9\x3e\x00", b"\x81\xa2\x00\x61x\x02\xfa\x3f\xc0\x00\x00",
      b"\x81\xa2\x00\x61x\x02\xfb\x3f\xf8\x00\x00\x00\x00\x00\x00",
    ] {
    let raw = @senweave.parse_cbor(wire)
    guard raw.record(0).unwrap().value is Some(@senweave.Numeric(n)) else {
      fail("number")
    }
    assert_eq(n.as_double(), 1.5)
  }
}

///|
test "decimal tag 4 uses the shared finite number and version policies" {
  let raw = @senweave.parse_cbor(b"\x81\xa2\x00\x61x\x02\xc4\x82\x21\x18\x7b")
  guard raw.record(0).unwrap().value is Some(@senweave.Numeric(n)) else {
    fail("number")
  }
  assert_eq(n.json_literal(), "123e-2")
  assert_eq(n.as_double(), 1.23)
  let _ = cbor_rejected(
    b"\x81\xa2\x00\x61x\x02\xc4\x82\x61x\x01",
    @senweave.WrongType,
  )
  let _ = cbor_rejected(
    b"\x81\xa3\x00\x61x\x02\x01\x20\xc4\x82\x00\x0a",
    @senweave.WrongType,
  )
  let _ = cbor_rejected(
    b"\x81\xa2\x00\x61x\x02\xc4\x82\x19\x03\xe8\x01",
    @senweave.InvalidNumber,
  )
}

///|
test "non-integer decimal spellings project to binary64 and negative zero survives" {
  let raw = @senweave.parse_json("[{\"n\":\"x\",\"v\":9007199254740993.0}]")
  let decoded = @senweave.parse_cbor(raw.to_cbor_bytes())
  guard raw.record(0).unwrap().value is Some(@senweave.Numeric(before)) else {
    fail("number")
  }
  guard decoded.record(0).unwrap().value is Some(@senweave.Numeric(after)) else {
    fail("number")
  }
  assert_eq(after.as_double(), before.as_double())
  assert_eq(after.json_literal() != before.json_literal(), true)
  let zero = @senweave.parse_cbor(
    @senweave.parse_json("[{\"n\":\"x\",\"v\":-0}]").to_cbor_bytes(),
  )
  guard zero.record(0).unwrap().value is Some(@senweave.Numeric(n)) else {
    fail("number")
  }
  assert_eq(n.as_double().reinterpret_as_uint64(), 0x8000000000000000UL)
}

///|
test "CBOR labels reject numeric extensions text aliases and invalid key types" {
  for
    wire in [
      b"\x81\xa3\x00\x61x\x02\x01\x18\x63\xf6", b"\x81\xa2\x61n\x61x\x02\x01", b"\x81\xa3\x00\x61x\x02\x01\xf4\xf6",
      b"\x81\xa3\x00\x61x\x02\x01\x26\xf6",
    ] {
    let _ = cbor_rejected(wire, @senweave.InvalidCborLabel)
  }
}

///|
test "repeated known and unknown labels fail instead of silently overwriting" {
  let error = cbor_rejected(
    b"\x81\xa3\x00\x61x\x02\x01\x02\x02",
    @senweave.DuplicateKey,
  )
  assert_eq(error.record_index, Some(0))
  assert_eq(error.field, Some("v"))
  let _ = cbor_rejected(
    b"\x81\xa4\x00\x61x\x02\x01\x61z\xf6\x61z\xf4",
    @senweave.DuplicateKey,
  )
}

///|
test "extension policy ignores optional nested values and rejects mandatory labels" {
  let raw = @senweave.parse_cbor(
    b"\x81\xa3\x00\x61x\x02\x01\x61z\xa1\x62a_\xf6",
  )
  assert_eq(raw.record(0).unwrap().ignored_extension_count, 1)
  let again = @senweave.parse_cbor(raw.to_cbor_bytes())
  assert_eq(again.record(0).unwrap().ignored_extension_count, 0)
  let error = cbor_rejected(
    b"\x81\xa3\x00\x61x\x02\x01\x67vendor_\xf6",
    @senweave.UnsupportedExtension,
  )
  assert_eq(error.field, None)
  let duplicate = cbor_rejected(
    b"\x81\xa4\x00\x61x\x02\x01\x61z\xf6\x61z\xf4",
    @senweave.DuplicateKey,
  )
  assert_eq(duplicate.field, None)
}

///|
test "wrong wire types conflicting values and missing measurements are rejected" {
  for
    wire in [
      b"\x81\xa2\x00\x61x\x08\x60", b"\x81\xa2\x00\x61x\x04\x01", b"\x81\xa2\x00\x61x\x03\x40",
      b"\x81\xa2\x00\x61x\x02\xf6",
    ] {
    let _ = cbor_rejected(wire, @senweave.WrongType)
  }
  let _ = cbor_rejected(
    b"\x81\xa3\x00\x61x\x02\x01\x04\xf4",
    @senweave.ConflictingValues,
  )
  let _ = cbor_rejected(b"\x81\xa1\x00\x61x", @senweave.MissingValue)
  let _ = cbor_rejected(b"\x81\xa2\x00\x61-\x02\x01", @senweave.InvalidName)
}

///|
test "CBOR version is unsigned and exactly ten" {
  assert_eq(@senweave.parse_cbor(b"\x81\xa1\x20\x0a").len(), 1)
  let _ = cbor_rejected(b"\x81\xa1\x20\x0b", @senweave.UnsupportedVersion)
  let _ = cbor_rejected(b"\x81\xa1\x20\x29", @senweave.WrongType)
  let _ = cbor_rejected(b"\x81\xa1\x20\xf9\x49\x00", @senweave.WrongType)
}

///|
test "nonfinite float values malformed UTF-8 and trailing bytes fail closed" {
  for
    wire in [
      b"\x81\xa2\x00\x61x\x02\xf9\x7e\x00", b"\x81\xa2\x00\x61x\x02\xf9\x7c\x00",
      b"\x81\xa2\x00\x61x\x02\xf9\xfc\x00",
    ] {
    let _ = cbor_rejected(wire, @senweave.InvalidNumber)
  }
  let _ = cbor_rejected(
    b"\x81\xa2\x00\x61x\x03\x63\xed\xa0\x80",
    @senweave.InvalidCbor,
  )
  let _ = cbor_rejected(b"\x80\x00", @senweave.InvalidCbor)
}

///|
test "CBOR rejects truncation huge declarations and restricted indefinite values" {
  for
    wire in [
      b"", b"\x81", b"\x81\xa1\x00", b"\x81\xa2\x00\x61x\x02\xfb\x00", b"\x81\xa2\x00\x61x\x08\x5b\x7f\xff\xff\xff\xff\xff\xff\xff",
      b"\x81\xa2\x00\x61x\x08\x5b\x00\x00\x00\x01\x00\x00\x00\x00", b"\x81\xa3\x00\x61x\x02\x01\x61z\x9b\xff\xff\xff\xff\xff\xff\xff\xff",
    ] {
    let _ = cbor_rejected(wire, @senweave.InvalidCbor)
  }
  for
    wire in [
      b"\x9f\xff", b"\x81\xa2\x00\x61x\x08\x5f\xff", b"\x81\xa2\x00\x61x\x03\x7f\x60\xff",
    ] {
    let _ = cbor_rejected(wire, @senweave.UnsupportedCborType)
  }
}

///|
test "bounded ingress checks input records fields depth strings binary and numbers" {
  let wire = b"\x81\xa2\x00\x61x\x02\x01"
  let defaults = @senweave.ParseLimits::default()
  let _ = cbor_rejected(wire, @senweave.InputLimit, max_input_bytes=1)
  let _ = cbor_rejected(wire, @senweave.InvalidLimits, max_input_bytes=0)
  let _ = cbor_rejected(
    b"\x82\xa1\x21\x61a\xa1\x21\x61b",
    @senweave.RecordLimit,
    limits={ ..defaults, max_records: 1, },
  )
  let _ = cbor_rejected(wire, @senweave.FieldLimit, limits={
    ..defaults,
    max_fields_per_record: 1,
  })
  let _ = cbor_rejected(wire, @senweave.NestingLimit, limits={
    ..defaults,
    max_depth: 2,
  })
  let _ = cbor_rejected(
    b"\x81\xa2\x00\x61x\x03\x64\xf0\x9f\x98\x80",
    @senweave.StringLimit,
    limits={ ..defaults, max_string_code_units: 1, },
  )
  let _ = cbor_rejected(
    b"\x81\xa2\x00\x61x\x08\x42\x00\x01",
    @senweave.StringLimit,
    limits={ ..defaults, max_string_code_units: 1, },
  )
  let _ = cbor_rejected(
    b"\x81\xa2\x00\x61x\x02\x18\x64",
    @senweave.NumberLimit,
    limits={ ..defaults, max_number_code_units: 1, },
  )
}

///|
test "unknown extension nesting is bounded while skipping its wire items" {
  let buffer = Buffer()
  buffer.write_bytes(b"\x81\xa3\x00\x61x\x02\x01\x61z")
  for _ in 0..<40 {
    buffer.write_byte(0x81)
  }
  buffer.write_byte(0)
  let _ = cbor_rejected(buffer.to_bytes(), @senweave.NestingLimit)
}

///|
test "empty packs context records and conservative output budgets" {
  let raw = @senweave.parse_cbor(b"\x80")
  assert_eq(raw.to_cbor_bytes(max_output_bytes=1), b"\x80")
  assert_eq(raw.resolve().to_cbor_bytes(max_output_bytes=1), b"\x80")
  let context = @senweave.parse_cbor(b"\x81\xa1\x21\x62a:")
  assert_eq(context.measurement_count(), 0)
  assert_eq(context.resolve().to_cbor_bytes(), b"\x80")
  let pack = @senweave.parse_json("[{\"n\":\"x\",\"v\":1,\"t\":1793000000}]")
  try pack.to_cbor_bytes(max_output_bytes=1) catch {
    error => assert_eq(error.diagnostic().code, @senweave.OutputLimit)
  } noraise {
    _ => fail("Output budget must reject this pack.")
  }
  try pack.to_cbor_bytes(max_output_bytes=0) catch {
    error => assert_eq(error.diagnostic().code, @senweave.InvalidLimits)
  } noraise {
    _ => fail("Output budget must be positive.")
  }
  assert_eq(pack.to_cbor_bytes(max_output_bytes=1024).length() <= 1024, true)
}

///|
test "CBOR root and record shape are checked before their fields" {
  let _ = cbor_rejected(b"\xa0", @senweave.InvalidRoot)
  let _ = cbor_rejected(b"\x81\x01", @senweave.InvalidRecord)
}
