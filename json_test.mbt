///|
fn rejected(
  input : String,
  code : @senweave.ErrorCode,
  limits~ : @senweave.ParseLimits = @senweave.ParseLimits::default(),
) -> @senweave.Diagnostic raise {
  try @senweave.parse_json(input, limits~) catch {
    error => {
      let diagnostic = error.diagnostic()
      assert_eq(diagnostic.code, code)
      diagnostic
    }
  } noraise {
    _ => fail("Expected SenML rejection.")
  }
}

///|
test "four measurement types preserve zero false empty text and binary data" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"urn:dev:mac:001122334455:","n":"temp","u":"Cel","v":0},
      #| {"n":"label","vs":""},{"n":"open","vb":false},
      #| {"n":"blob","vd":"AQID"}]
    ),
  )
  assert_eq(pack.len(), 4)
  assert_eq(pack.measurement_count(), 4)
  let first = pack.record(0).unwrap()
  assert_eq(first.base_name, Some("urn:dev:mac:001122334455:"))
  assert_eq(first.name, Some("temp"))
  guard first.value is Some(@senweave.Numeric(number)) else { fail("numeric") }
  assert_eq(number.as_double(), 0.0)
  assert_eq(number.json_literal(), "0")
  guard pack.record(1).unwrap().value is Some(@senweave.Text(text)) else {
    fail("text")
  }
  assert_eq(text, "")
  guard pack.record(2).unwrap().value is Some(@senweave.Boolean(flag)) else {
    fail("boolean")
  }
  assert_eq(flag, false)
  guard pack.record(3).unwrap().value is Some(@senweave.Data(bytes)) else {
    fail("data")
  }
  assert_eq(bytes, b"\x01\x02\x03")
  // Parsed records intentionally retain their original, unresolved shape.
  assert_eq(pack.record(1).unwrap().base_name, None)
  assert_eq(pack.record(-1) is None, true)
  assert_eq(pack.record(4) is None, true)
}

///|
test "sum-only records and zero sum are measurements" {
  let pack = @senweave.parse_json(
    "[{\"n\":\"energy\",\"s\":0},{\"n\":\"energy\",\"s\":9,\"v\":2}]",
  )
  assert_eq(pack.measurement_count(), 2)
  let record = pack.record(0).unwrap()
  assert_eq(record.value is None, true)
  assert_eq(record.sum.unwrap().as_double(), 0.0)
}

///|
test "base-only context updates are retained without inventing measurements" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"sensor:","bver":10},{"bt":1793000000,"bu":"Cel","bv":0,"bs":0},
      #| {"n":"temp","v":20,"t":-1,"ut":30}]
    ),
  )
  assert_eq(pack.len(), 3)
  assert_eq(pack.measurement_count(), 1)
  assert_eq(pack.record(0).unwrap().is_measurement(), false)
  assert_eq(pack.record(1).unwrap().is_measurement(), false)
  let measurement = pack.record(2).unwrap()
  assert_eq(measurement.time.unwrap().json_literal(), "-1")
  assert_eq(measurement.base_time is None, true)
  assert_eq(measurement.unit, None)
  assert_eq(measurement.update_time.unwrap().as_double(), 30.0)
}

///|
test "empty packs and context-only packs can be represented" {
  let empty = @senweave.parse_json("[]")
  assert_eq(empty.len(), 0)
  assert_eq(empty.measurement_count(), 0)
  assert_eq(empty.record(0) is None, true)
  let context = @senweave.parse_json("[{\"bn\":\"sensor:\"}]")
  assert_eq(context.measurement_count(), 0)
}

///|
test "combined name syntax respects inherited bases overrides and resets" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"sensor","n":"/temp","v":1},{"n":"/temp","v":2},
      #| {"bn":"","n":"standalone","v":3}]
    ),
  )
  assert_eq(pack.measurement_count(), 3)
  for
    input in [
      "[{\"v\":1}]", "[{\"n\":\"\",\"v\":1}]", "[{\"n\":\"/temp\",\"v\":1}]", "[{\"n\":\"_temp\",\"v\":1}]",
      "[{\"n\":\"sensor temp\",\"v\":1}]", "[{\"n\":\"温度\",\"v\":1}]", "[{\"bn\":\"sensor:\",\"v\":1},{\"bn\":\"\",\"v\":2}]",
    ] {
    ignore(rejected(input, @senweave.InvalidName))
  }
}

///|
test "measurement presence is distinct from base context" {
  for fields in ["", "\"n\":\"a\"", "\"vendor\":1", "\"bn\":\"a\",\"t\":0"] {
    ignore(rejected("[{" + fields + "}]", @senweave.MissingValue))
  }
  for fields in ["\"v\":0,\"vb\":false", "\"vs\":\"\",\"vd\":\"\""] {
    ignore(
      rejected("[{\"n\":\"a\"," + fields + "}]", @senweave.ConflictingValues),
    )
  }
}

///|
test "known fields do not coerce strings booleans null arrays or objects" {
  let cases = [
    ("\"bn\":1,\"n\":\"a\",\"v\":1", "bn"),
    ("\"n\":null,\"v\":1", "n"),
    ("\"n\":\"a\",\"u\":false,\"v\":1", "u"),
    ("\"n\":\"a\",\"bu\":[],\"v\":1", "bu"),
    ("\"n\":\"a\",\"bt\":\"1\",\"v\":1", "bt"),
    ("\"n\":\"a\",\"bv\":null,\"v\":1", "bv"),
    ("\"n\":\"a\",\"bs\":true,\"v\":1", "bs"),
    ("\"n\":\"a\",\"bver\":\"10\",\"v\":1", "bver"),
    ("\"n\":\"a\",\"t\":{},\"v\":1", "t"),
    ("\"n\":\"a\",\"ut\":null,\"v\":1", "ut"),
    ("\"n\":\"a\",\"s\":false", "s"),
    ("\"n\":\"a\",\"v\":\"1\"", "v"),
    ("\"n\":\"a\",\"vs\":null", "vs"),
    ("\"n\":\"a\",\"vb\":0", "vb"),
    ("\"n\":\"a\",\"vd\":[1]", "vd"),
  ]
  for (fields, field) in cases {
    let diagnostic = rejected("[{" + fields + "}]", @senweave.WrongType)
    assert_eq(diagnostic.record_index, Some(0))
    assert_eq(diagnostic.field, Some(field))
  }
}

///|
test "version ten is checked mathematically without binary64 rounding" {
  for version in ["10", "10.0", "1e1", "0.10e2", "1000e-2", "1.000e+1"] {
    let pack = @senweave.parse_json(
      "[{\"bn\":\"a\",\"bver\":" + version + ",\"v\":1}]",
    )
    assert_eq(
      pack.record(0).unwrap().base_version.unwrap().json_literal(),
      version,
    )
  }
  for
    version in [
      "0", "-10", "5", "11", "10.0000000000000001", "9.99999999999999999", "1.01e1",
    ] {
    ignore(
      rejected(
        "[{\"n\":\"a\",\"bver\":" + version + ",\"v\":1}]",
        @senweave.UnsupportedVersion,
      ),
    )
  }
}

///|
test "numeric source spelling survives values outside exact integer binary64" {
  for
    literal in [
      "9007199254740993", "-0", "1.1000", "5e-324", "1.7976931348623157e308", "0e-9999",
    ] {
    let pack = @senweave.parse_json("[{\"n\":\"a\",\"v\":" + literal + "}]")
    guard pack.record(0).unwrap().value is Some(@senweave.Numeric(number)) else {
      fail("numeric")
    }
    assert_eq(number.json_literal(), literal)
  }
}

///|
test "known numbers reject uppercase exponents overflow and nonzero underflow" {
  for literal in ["1E0", "1e309", "-1e400", "1e-9999"] {
    ignore(
      rejected("[{\"n\":\"a\",\"v\":" + literal + "}]", @senweave.InvalidNumber),
    )
  }
}

///|
test "base64url data rejects padding standard alphabet and nonzero unused bits" {
  for encoded in ["", "AQID", "-_8", "----____"] {
    let pack = @senweave.parse_json(
      "[{\"n\":\"a\",\"vd\":\"" + encoded + "\"}]",
    )
    guard pack.record(0).unwrap().value is Some(@senweave.Data(_)) else {
      fail("data")
    }
  }
  let pack = @senweave.parse_json("[{\"n\":\"a\",\"vd\":\"----____\"}]")
  guard pack.record(0).unwrap().value is Some(@senweave.Data(bytes)) else {
    fail("data")
  }
  assert_eq(bytes, b"\xfb\xef\xbe\xff\xff\xff")
  for encoded in ["A", "AB", "AAB", "AQ==", "AQ+_", "AQ/_", "A Q", "AAAA===="] {
    ignore(
      rejected(
        "[{\"n\":\"a\",\"vd\":\"" + encoded + "\"}]",
        @senweave.InvalidData,
      ),
    )
  }
  let long_bad_tail = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"
  ignore(
    rejected(
      "[{\"n\":\"a\",\"vd\":\"" + long_bad_tail + "\"}]",
      @senweave.InvalidData,
    ),
  )
}

///|
test "duplicate keys are compared after escape decoding even inside extensions" {
  let diagnostic = rejected(
    (
      #|[{"n":"a","v":1,"\u0076":2}]
    ),
    @senweave.DuplicateKey,
  )
  assert_eq(diagnostic.field, Some("v"))
  assert_eq(diagnostic.line is Some(_), true)
  assert_eq(diagnostic.column is Some(_), true)
  ignore(
    rejected(
      "[{\"n\":\"a\",\"v\":1,\"vendor\":{\"x\":1,\"x\":2}}]",
      @senweave.DuplicateKey,
    ),
  )
}

///|
test "optional extensions are ignored while mandatory extensions reject" {
  let pack = @senweave.parse_json(
    "[{\"n\":\"a\",\"v\":1,\"vendor\":{\"private_\":true},\"V\":false}]",
  )
  assert_eq(pack.record(0).unwrap().ignored_extension_count, 2)
  let diagnostic = rejected(
    "[{\"n\":\"a\",\"v\":1,\"vendor_\":true}]",
    @senweave.UnsupportedExtension,
  )
  assert_eq(diagnostic.field, None)
  ignore(rejected("[{\"n\":\"a\",\"V\":1}]", @senweave.MissingValue))
}

///|
test "JSON shape errors and syntax errors produce explicit categories" {
  for input in ["{}", "null", "1", "\"a\""] {
    ignore(rejected(input, @senweave.InvalidRoot))
  }
  for input in ["[null]", "[1]", "[[]]"] {
    ignore(rejected(input, @senweave.InvalidRecord))
  }
  for
    input in [
      "", "[", "[{\"n\":\"a\",\"v\":NaN}]", "[] []", "[{\"n\":\"a\",\"vs\":\"\\ud800\"}]",
    ] {
    ignore(rejected(input, @senweave.InvalidJson))
  }
}

///|
test "resource limits reject before admitting oversized packs or fields" {
  let defaults = @senweave.ParseLimits::default()
  ignore(
    rejected("[] ", @senweave.InputLimit, limits={
      ..defaults,
      max_input_code_units: 2,
    }),
  )
  ignore(
    rejected(
      "[{\"n\":\"a\",\"v\":1},{\"n\":\"a\",\"v\":2}]",
      @senweave.RecordLimit,
      limits={ ..defaults, max_records: 1, },
    ),
  )
  ignore(
    rejected("[{\"n\":\"a\",\"v\":1}]", @senweave.FieldLimit, limits={
      ..defaults,
      max_fields_per_record: 1,
    }),
  )
  ignore(
    rejected("[{\"n\":\"a\",\"v\":123}]", @senweave.NumberLimit, limits={
      ..defaults,
      max_number_code_units: 2,
    }),
  )
  let diagnostic = rejected(
    "[{\"n\":\"a\",\"vs\":\"😀😀😀\"}]",
    @senweave.StringLimit,
    limits={ ..defaults, max_string_code_units: 4, },
  )
  assert_eq(diagnostic.field, Some("vs"))
  let boundary = @senweave.parse_json("[{\"n\":\"a\",\"vs\":\"😀😀\"}]", limits={
    ..defaults,
    max_string_code_units: 4,
  })
  assert_eq(boundary.len(), 1)
  ignore(
    rejected(
      "[{\"n\":\"a\",\"v\":1,\"vendor\":[[[]]]}]",
      @senweave.NestingLimit,
      limits={ ..defaults, max_depth: 3, },
    ),
  )
}

///|
test "invalid limits are rejected even for an empty input pack" {
  let defaults = @senweave.ParseLimits::default()
  for
    limits in [
      { ..defaults, max_input_code_units: 0, },
      { ..defaults, max_records: 0, },
      { ..defaults, max_depth: 0, },
      { ..defaults, max_depth: 129, },
      { ..defaults, max_fields_per_record: -1, },
      { ..defaults, max_string_code_units: 0, },
      { ..defaults, max_number_code_units: 1025, },
    ] {
    ignore(rejected("[]", @senweave.InvalidLimits, limits~))
  }
}

///|
test "diagnostics do not include rejected measurement values" {
  let diagnostic = rejected(
    "[{\"n\":\"a\",\"vs\":{\"token\":\"private-sensor-secret\"}}]",
    @senweave.WrongType,
  )
  assert_eq(diagnostic.message, "Expected a JSON string.")
  assert_eq(diagnostic.field, Some("vs"))
  assert_eq(diagnostic.record_index, Some(0))
}

///|
test "escaped mandatory labels and unknown diagnostic field names are omitted" {
  let escaped = rejected(
    (
      #|[{"n":"a","v":1,"vendor\u005f":true}]
    ),
    @senweave.UnsupportedExtension,
  )
  assert_eq(escaped.field, None)
  let mut key = ""
  for _ in 0..<129 {
    key += "x"
  }
  key += "_"
  let diagnostic = rejected(
    "[{\"n\":\"a\",\"v\":1,\"" + key + "\":true}]",
    @senweave.UnsupportedExtension,
  )
  assert_eq(diagnostic.field, None)
  assert_eq(diagnostic.record_index, Some(0))
}

///|
test "duplicate extension keys and nested application keys do not enter diagnostics" {
  for
    input in [
      "[{\"n\":\"a\",\"v\":1,\"private-key\":1,\"private-key\":2}]", "[{\"n\":\"a\",\"v\":1,\"vendor\":{\"private-key\":1,\"private-key\":2}}]",
    ] {
    let diagnostic = rejected(input, @senweave.DuplicateKey)
    assert_eq(diagnostic.field, None)
    assert_eq(diagnostic.line is Some(_), true)
    assert_eq(diagnostic.column is Some(_), true)
  }
}

///|
test "failed calls do not leak base name state into a later call" {
  let bad = rejected(
    "[{\"bn\":\"sensor:\",\"v\":1},{\"n\":\"bad name\",\"v\":2}]",
    @senweave.InvalidName,
  )
  assert_eq(bad.record_index, Some(1))
  ignore(rejected("[{\"v\":1}]", @senweave.InvalidName))
  let good = @senweave.parse_json("[{\"bn\":\"new:\"},{\"n\":\"a\",\"v\":1}]")
  assert_eq(good.measurement_count(), 1)
}
