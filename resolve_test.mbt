///|
fn resolution_rejected(
  input : String,
  code : @senweave.ErrorCode,
  reference_time? : Double,
  max_expanded_code_units~ : Int32 = 4_194_304,
) -> @senweave.Diagnostic raise {
  let pack = @senweave.parse_json(input)
  try pack.resolve(reference_time?, max_expanded_code_units~) catch {
    error => {
      let diagnostic = error.diagnostic()
      assert_eq(diagnostic.code, code)
      diagnostic
    }
  } noraise {
    _ => fail("Expected resolution rejection.")
  }
}

///|
fn numeric(record : @senweave.ResolvedRecord) -> Double raise {
  guard record.value is Some(@senweave.Numeric(number)) else { fail("numeric") }
  number.as_double()
}

///|
test "gateway bases apply on the current record and inherit independently" {
  let raw = @senweave.parse_json(
    (
      #|[{"bn":"a:","bt":1793000000,"bu":"Cel","bv":20,"bs":100,"n":"t","v":1,"s":2,"t":3},
      #| {"bn":"b:","n":"t","v":2,"u":"K","t":4},
      #| {"n":"t","v":3,"t":5},
      #| {"bn":"","bu":"","bv":0,"bs":0,"bt":0,"n":"reset","v":0,"t":1793000006}]
    ),
  )
  let resolved = raw.resolve()
  assert_eq(resolved.len(), 4)
  let first = resolved.record(0).unwrap()
  assert_eq(first.name, "a:t")
  assert_eq(first.unit, Some("Cel"))
  assert_eq(first.time.as_double(), 1793000003.0)
  assert_eq(numeric(first), 21.0)
  assert_eq(first.sum.unwrap().as_double(), 102.0)
  let second = resolved.record(1).unwrap()
  assert_eq(second.name, "b:t")
  assert_eq(second.unit, Some("K"))
  assert_eq(numeric(second), 22.0)
  assert_eq(second.sum.unwrap().as_double(), 100.0)
  assert_eq(resolved.record(2).unwrap().unit, Some("Cel"))
  let reset = resolved.record(3).unwrap()
  assert_eq(reset.name, "reset")
  assert_eq(reset.unit, Some(""))
  assert_eq(numeric(reset), 0.0)
  assert_eq(reset.sum.unwrap().as_double(), 0.0)
  // Resolution must not overwrite reusable raw input.
  assert_eq(raw.record(1).unwrap().base_time is None, true)
  assert_eq(raw.record(1).unwrap().name, Some("t"))
}

///|
test "time classification happens after adding base and regular time" {
  let absolute = @senweave.parse_json(
    "[{\"n\":\"x\",\"v\":1,\"bt\":268435450,\"t\":6}]",
  ).resolve()
  assert_eq(absolute.record(0).unwrap().time.as_double(), 268435456.0)
  let relative = @senweave.parse_json(
    "[{\"n\":\"x\",\"v\":1,\"bt\":268435456,\"t\":-1}]",
  ).resolve(reference_time=1793000000.0)
  assert_eq(relative.record(0).unwrap().time.as_double(), 2061435455.0)
}

///|
test "relative past now future and fractional times share one explicit reference" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"x:","n":"future","v":1,"t":3.5},
      #| {"n":"now","v":1},{"n":"past","v":1,"t":-1.25}]
    ),
  ).resolve(reference_time=1793000000.25)
  assert_eq(pack.record(0).unwrap().time.as_double(), 1792999999.0)
  assert_eq(pack.record(1).unwrap().time.as_double(), 1793000000.25)
  assert_eq(pack.record(2).unwrap().time.as_double(), 1793000003.75)
  assert_eq(pack.record(0).unwrap().source_index, 2)
}

///|
test "absolute packs need no clock and missing relative context reports source record" {
  let pack = @senweave.parse_json("[{\"n\":\"x\",\"v\":1,\"t\":268435456}]")
  assert_eq(pack.resolve().len(), 1)
  let error = resolution_rejected(
    "[{\"bn\":\"x:\"},{\"n\":\"t\",\"v\":1}]",
    @senweave.MissingReferenceTime,
  )
  assert_eq(error.record_index, Some(1))
  assert_eq(error.field, Some("t"))
}

///|
test "invalid reference clocks and unrepresentable absolute results fail closed" {
  for
    now in [
      0.0,
      -1.0,
      268435455.0,
      0x7FF0000000000000L.reinterpret_as_double(),
      0xFFF0000000000000UL.reinterpret_as_double(),
      0x7FF8000000000001L.reinterpret_as_double(),
    ] {
    let _ = resolution_rejected(
      "[]",
      @senweave.InvalidReferenceTime,
      reference_time=now,
    )
  }
  let _ = resolution_rejected(
    "[{\"n\":\"x\",\"v\":1,\"t\":-1}]",
    @senweave.UnrepresentableTime,
    reference_time=268435456.0,
  )
}

///|
test "overflow in time value or sum rejects the complete result with diagnostics" {
  for
    (input, field) in [
      ("[{\"n\":\"x\",\"bt\":1e308,\"t\":1e308,\"v\":1}]", "t"),
      ("[{\"n\":\"x\",\"bv\":1e308,\"v\":1e308,\"t\":1793000000}]", "v"),
      ("[{\"n\":\"x\",\"bs\":1e308,\"s\":1e308,\"t\":1793000000}]", "s"),
    ] {
    let error = resolution_rejected(input, @senweave.ArithmeticOverflow)
    assert_eq(error.record_index, Some(0))
    assert_eq(error.field, Some(field))
    assert_eq(error.message.contains("1e308"), false)
  }
}

///|
test "sum-only measurements and inherited sums retain absence versus zero" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"x:","bt":1793000000,"n":"a","s":0},
      #| {"bs":10,"n":"b","v":2},
      #| {"bv":30,"n":"c","s":5},
      #| {"n":"d","vb":false}]
    ),
  ).resolve()
  assert_eq(pack.record(0).unwrap().value is None, true)
  assert_eq(pack.record(0).unwrap().sum.unwrap().as_double(), 0.0)
  assert_eq(pack.record(1).unwrap().sum.unwrap().as_double(), 10.0)
  assert_eq(numeric(pack.record(2).unwrap()), 30.0)
  assert_eq(pack.record(2).unwrap().sum.unwrap().as_double(), 15.0)
  guard pack.record(3).unwrap().value is Some(@senweave.Boolean(flag)) else {
    fail("Base value must not replace a boolean value.")
  }
  assert_eq(flag, false)
}

///|
test "numeric identity preserves source literals while actual addition uses binary64" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"x:","bt":1793000000,"bv":0,"n":"large","v":9007199254740993},
      #| {"n":"zero","v":-0},
      #| {"bv":0.1,"n":"sum","v":0.2}]
    ),
  ).resolve()
  let encoded = pack.to_json_string()
  assert_eq(encoded.contains("9007199254740993"), true)
  assert_eq(encoded.contains("\"v\":-0"), true)
  assert_eq(numeric(pack.record(2).unwrap()), 0.1 + 0.2)
  let again = @senweave.parse_json(encoded).resolve()
  assert_eq(again.to_json_string(), encoded)
}

///|
test "chronological sorting is stable at equal times across device changes" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"a:","bt":1793000000,"n":"later","v":1,"t":2},
      #| {"bn":"b:","n":"first","v":2,"t":1},
      #| {"n":"second","v":3,"t":1},{"n":"last","v":4,"t":2}]
    ),
  ).resolve()
  let indexes = [1, 2, 0, 3]
  for index in 0..<pack.len() {
    assert_eq(pack.record(index).unwrap().source_index, indexes[index])
  }
  assert_eq(pack.record(0).unwrap().name, "b:first")
  assert_eq(pack.record(2).unwrap().name, "a:later")
}

///|
test "every extracted measurement and filtered pack is independently reparsable" {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"urn:dev:test:","bu":"Cel","bt":1793000000,"bv":20},
      #| {"n":"temperature","v":2.50,"t":-2,"ut":30,"vendor":7},
      #| {"n":"door","vb":false,"u":"/"},
      #| {"n":"label","vs":"line\n\"\\☃","u":""},
      #| {"n":"blob","vd":"----____","u":"/"}]
    ),
  ).resolve()
  for index in 0..<pack.len() {
    let record = pack.record(index).unwrap()
    let singleton = @senweave.parse_json(record.to_json_string()).resolve()
    let again = singleton.record(0).unwrap()
    assert_eq(again.name, record.name)
    assert_eq(again.time.json_literal(), record.time.json_literal())
    assert_eq(again.unit, record.unit)
    assert_eq(singleton.to_json_string(), record.to_json_string())
    assert_eq(again.source_index, 0)
  }
  assert_eq(pack.record(0).unwrap().ignored_extension_count, 1)
  let mut calls = 0
  let selected = pack.filter(record => {
    calls += 1
    record.name.has_suffix("temperature")
  })
  assert_eq(calls, 4)
  assert_eq(selected.len(), 1)
  assert_eq(selected.record(0).unwrap().source_index, 1)
  assert_eq(numeric(selected.record(0).unwrap()), 22.5)
  assert_eq(@senweave.parse_json(selected.to_json_string()).resolve().len(), 1)
  assert_eq(pack.filter(_ => false).to_json_string(), "[]")
  assert_eq(pack.len(), 4)
}

///|
test "serialization emits only resolved standard fields and preserves update interval" {
  let pack = @senweave.parse_json(
    "[{\"bn\":\"sensor:\",\"bt\":1793000000,\"bver\":10,\"n\":\"x\",\"v\":1,\"ut\":15,\"vendor\":2}]",
  ).resolve()
  let raw = @senweave.parse_json(pack.to_json_string()).record(0).unwrap()
  assert_eq(raw.base_name, None)
  assert_eq(raw.base_time is None, true)
  assert_eq(raw.base_unit, None)
  assert_eq(raw.base_value is None, true)
  assert_eq(raw.base_sum is None, true)
  assert_eq(raw.base_version is None, true)
  assert_eq(raw.ignored_extension_count, 0)
  assert_eq(raw.update_time.unwrap().json_literal(), "15")
  assert_eq(raw.name, Some("sensor:x"))
}

///|
test "context-only packs emit no measurements and resolved indexing is safe" {
  for input in ["[]", "[{\"bn\":\"sensor:\",\"bt\":0,\"bv\":10}]"] {
    let pack = @senweave.parse_json(input).resolve()
    assert_eq(pack.len(), 0)
    assert_eq(pack.record(-1) is None, true)
    assert_eq(pack.record(0) is None, true)
    assert_eq(pack.to_json_string(), "[]")
  }
}

///|
test "expansion budgets cover escaping and repeated context before concatenation" {
  let _ = resolution_rejected(
    "[]",
    @senweave.InvalidLimits,
    max_expanded_code_units=0,
  )
  let _ = resolution_rejected(
    "[]",
    @senweave.ExpansionLimit,
    max_expanded_code_units=1,
  )
  assert_eq(
    @senweave.parse_json("[]")
    .resolve(max_expanded_code_units=2)
    .to_json_string(),
    "[]",
  )
  let input =
    #|[{"bn":"long-device-prefix:","bt":1793000000,"bu":"\"\\\n","n":"a","vs":"\u0001\u0002"},
    #| {"n":"b","vd":"----____"}]
  let pack = @senweave.parse_json(input).resolve(max_expanded_code_units=600)
  assert_eq(pack.to_json_string().length() <= 600, true)
  let error = resolution_rejected(
    input,
    @senweave.ExpansionLimit,
    max_expanded_code_units=400,
  )
  assert_eq(error.record_index, Some(1))
}

///|
test "repeated resolution has no leaked context and supports different reference clocks" {
  let raw = @senweave.parse_json("[{\"bn\":\"a:\",\"n\":\"x\",\"v\":1}]")
  let first = raw.resolve(reference_time=1793000000.0)
  let second = raw.resolve(reference_time=1793000010.0)
  assert_eq(first.record(0).unwrap().time.as_double(), 1793000000.0)
  assert_eq(second.record(0).unwrap().time.as_double(), 1793000010.0)
  let _ = resolution_rejected(
    "[{\"n\":\"x\",\"v\":1}]",
    @senweave.MissingReferenceTime,
  )
  let other = @senweave.parse_json("[{\"n\":\"x\",\"v\":1,\"t\":1793000000}]").resolve()
  assert_eq(other.record(0).unwrap().name, "x")
  assert_eq(other.record(0).unwrap().unit, None)
  assert_eq(other.record(0).unwrap().sum is None, true)
}
