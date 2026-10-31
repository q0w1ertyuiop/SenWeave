///|
test "CBOR accepts nonpreferred argument widths without changing semantics" {
  let canonical = b"\x81\xa2\x00\x61x\x02\x01"
  for
    wire in [
      b"\x98\x01\xa2\x00\x61x\x02\x01", b"\x81\xb8\x02\x18\x00\x78\x01x\x18\x02\x18\x01",
      b"\x81\xa2\x00\x61x\x02\x1b\x00\x00\x00\x00\x00\x00\x00\x01",
    ] {
    let raw = @senweave.parse_cbor(wire)
    assert_eq(raw.to_cbor_bytes(), canonical)
  }
}

///|
test "CBOR record maps may be indefinite while the finite pack stays definite" {
  let raw = @senweave.parse_cbor(
    b"\x82\xbf\x21\x65base:\xff\xbf\x00\x61x\x02\x01\xff",
  )
  assert_eq(raw.len(), 2)
  let record = raw.resolve(reference_time=1793000000.0).record(0).unwrap()
  assert_eq(record.name, "base:x")
  guard record.value is Some(@senweave.Numeric(value)) else { fail("number") }
  assert_eq(value.json_literal(), "1")
}

///|
test "CBOR negative integers cover the complete major type one range exactly" {
  for
    (argument, literal) in [
      (b"\x80\x00\x00\x00\x00\x00\x00\x00", "-9223372036854775809"),
      (b"\xff\xff\xff\xff\xff\xff\xff\xfe", "-18446744073709551615"),
      (b"\xff\xff\xff\xff\xff\xff\xff\xff", "-18446744073709551616"),
    ] {
    let buffer = Buffer()
    buffer.write_bytes(b"\x81\xa2\x00\x61x\x02\x3b")
    buffer.write_bytes(argument)
    let wire = buffer.to_bytes()
    let raw = @senweave.parse_cbor(wire)
    guard raw.record(0).unwrap().value is Some(@senweave.Numeric(value)) else {
      fail("number")
    }
    assert_eq(value.json_literal(), literal)
    assert_eq(raw.to_cbor_bytes(), wire)
    let from_json = @senweave.parse_json("[{\"n\":\"x\",\"v\":\{literal}}]")
    assert_eq(from_json.to_cbor_bytes(), wire)
    let resolved = raw.resolve(reference_time=1793000000.0)
    assert_eq(resolved.to_json_string().contains(literal), true)
  }
}

///|
test "CBOR indefinite maps retain duplicate member and shape validation" {
  let _ = cbor_rejected(b"\x81\xbf\xff", @senweave.MissingValue)
  let _ = cbor_rejected(
    b"\x81\xbf\x00\x61x\x00\x61y\xff",
    @senweave.DuplicateKey,
  )
  let _ = cbor_rejected(b"\x81\xbf\x00\xff", @senweave.InvalidCbor)
  let _ = cbor_rejected(b"\x81\xbf\x00\x61x\x02\x01", @senweave.InvalidCbor)
  let _ = cbor_rejected(
    b"\x81\xbf\x00\x61x\x02\x01\xff\x00",
    @senweave.InvalidCbor,
  )
}

///|
test "CBOR indefinite maps count members and still enforce record depth" {
  let defaults = @senweave.ParseLimits::default()
  let wire = b"\x81\xbf\x00\x61x\x02\x01\x07\x01\xff"
  let _ = cbor_rejected(wire, @senweave.FieldLimit, limits={
    ..defaults,
    max_fields_per_record: 2,
  })
  let _ = cbor_rejected(wire, @senweave.NestingLimit, limits={
    ..defaults,
    max_depth: 2,
  })
  assert_eq(
    @senweave.parse_cbor(wire, limits={ ..defaults, max_fields_per_record: 3, }).len(),
    1,
  )
}

///|
test "CBOR skips wellformed indefinite extensions without materializing their trees" {
  let wire = b"\x81\xa3\x00\x61x\x02\x01\x61z\xbf\x61a\x9f\x01\x7f\x61a\x61b\xff\x5f\x41\x01\x41\x02\xff\xff\xff"
  let raw = @senweave.parse_cbor(wire)
  assert_eq(raw.measurement_count(), 1)
  assert_eq(raw.ignored_extension_count(), 1)
  let _ = cbor_rejected(wire, @senweave.NestingLimit, limits={
    ..@senweave.ParseLimits::default(),
    max_depth: 5,
  })
}

///|
test "CBOR skipped extension chunks remain structurally and UTF8 checked" {
  for
    wire in [
      b"\x81\xa3\x00\x61x\x02\x01\x61z\x7f\x41\x01\xff", b"\x81\xa3\x00\x61x\x02\x01\x61z\x7f\x7f\xff\xff",
      b"\x81\xa3\x00\x61x\x02\x01\x61z\x7f\x61\xff\xff", b"\x81\xa3\x00\x61x\x02\x01\x61z\xbf\x00\xff",
    ] {
    let _ = cbor_rejected(wire, @senweave.InvalidCbor)
  }
}

///|
test "CBOR text chunks in names and extension labels preserve their decoded meaning" {
  let raw = @senweave.parse_cbor(b"\x81\xa2\x00\x7f\x61x\x61y\xff\x02\x01")
  assert_eq(raw.record(0).unwrap().name, Some("xy"))
  let wire = b"\x81\xa3\x00\x61x\x02\x01\x7f\x61q\x61_\xff\xf5"
  let diagnostic = cbor_rejected(wire, @senweave.UnsupportedExtension)
  assert_eq(diagnostic.field, None)
  let _ = cbor_rejected(
    b"\x81\xa2\x7f\x61n\xff\x61x\x02\x01",
    @senweave.InvalidCborLabel,
  )
}

///|
test "CBOR text chunk limits apply to the accumulated UTF16 length" {
  let wire = b"\x81\xa2\x00\x7f\x61x\x61y\xff\x02\x01"
  let defaults = @senweave.ParseLimits::default()
  let _ = cbor_rejected(wire, @senweave.StringLimit, limits={
    ..defaults,
    max_string_code_units: 1,
  })
  assert_eq(
    @senweave.parse_cbor(wire, limits={ ..defaults, max_string_code_units: 2, }).len(),
    1,
  )
}

///|
test "CBOR early text limits retain known record and field diagnostics" {
  let diagnostic = cbor_rejected(
    b"\x81\xa2\x00\x61x\x03\x64long",
    @senweave.StringLimit,
    limits={ ..@senweave.ParseLimits::default(), max_string_code_units: 1, },
  )
  assert_eq(diagnostic.record_index, Some(0))
  assert_eq(diagnostic.field, Some("vs"))
}

///|
test "CBOR decimal fractions accept variant container widths and wide negative mantissas" {
  for
    (wire, literal) in [
      (b"\x81\xa2\x00\x61x\x02\xd9\x00\x04\x98\x02\x18\x00\x18\x01", "1e0"),
      (b"\x81\xa2\x00\x61x\x02\xc4\x9f\x00\x01\xff", "1e0"),
      (
        b"\x81\xa2\x00\x61x\x02\xc4\x82\x00\x3b\x80\x00\x00\x00\x00\x00\x00\x00",
        "-9223372036854775809e0",
      ),
    ] {
    let raw = @senweave.parse_cbor(wire)
    guard raw.record(0).unwrap().value is Some(@senweave.Numeric(value)) else {
      fail("number")
    }
    assert_eq(value.json_literal(), literal)
  }
}

///|
test "CBOR decimal fractions reject missing extra and noninteger parts" {
  let _ = cbor_rejected(
    b"\x81\xa2\x00\x61x\x02\xc4\x82\x00",
    @senweave.InvalidCbor,
  )
  for
    wire in [
      b"\x81\xa2\x00\x61x\x02\xc4\x9f\x00\x01\x02\xff", b"\x81\xa2\x00\x61x\x02\xc4\x82\x00\x61x",
    ] {
    let _ = cbor_rejected(wire, @senweave.WrongType)
  }
}

///|
test "CBOR scalar reserved encodings do not gain acceptance with argument variants" {
  let _ = cbor_rejected(b"\x81\xa2\x00\x61x\x04\xf8\x14", @senweave.InvalidCbor)
  let _ = cbor_rejected(
    b"\x81\xa2\x00\x61x\x02\x1c",
    @senweave.UnsupportedCborType,
  )
}

///|
test "every truncated prefix of accepted CBOR variants fails without a partial pack" {
  for
    wire in [
      b"\x81\xbf\x00\x61x\x02\x01\xff", b"\x81\xa2\x00\x7f\x61x\x61y\xff\x02\x01",
      b"\x81\xa2\x00\x61x\x02\xc4\x9f\x00\x01\xff", b"\x81\xa2\x00\x61x\x02\x3b\xff\xff\xff\xff\xff\xff\xff\xff",
    ] {
    for end in 0..<wire.length() {
      try @senweave.parse_cbor(wire.exact_view(end~).to_owned()) catch {
        _ => ()
      } noraise {
        _ => fail("A truncated prefix must not produce a pack.")
      }
    }
  }
}
