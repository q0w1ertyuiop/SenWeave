///|
fn payload(response : String) -> String raise {
  guard @json.parse(response) is Json::Object(fields) else { fail("object") }
  guard fields.get("data") is Some(Json::String(text)) else { fail("data") }
  text
}

///|
fn error_code(response : String) -> String raise {
  guard @json.parse(response) is Json::Object(fields) else { fail("object") }
  assert_eq(fields.get("ok") is Some(Json::False), true)
  guard fields.get("error") is Some(Json::Object(error)) else { fail("error") }
  guard error.get("code") is Some(Json::String(code)) else { fail("code") }
  code
}

///|
test "check applies resolution instead of only accepting syntactically valid input" {
  let input = "[{\"bn\":\"x:\"},{\"n\":\"t\",\"v\":1,\"vendor\":true}]"
  assert_eq(
    error_code(@inspector.process_input(input, "json", "check", "json", "", "")),
    "MissingReferenceTime",
  )
  let data = payload(
    @inspector.process_input(input, "json", "check", "json", "1793000000", ""),
  )
  assert_eq(data.contains("\"measurements\":1"), true)
  assert_eq(data.contains("\"ignored_extensions\":1"), true)
  assert_eq(data.contains("\"stage\":\"resolved\""), true)
}

///|
test "bridge preserves integer text and filters after applying base context" {
  let input =
    #|[{"bn":"x:","bt":1793000000},{"n":"counter","v":9007199254740993},{"n":"door","vb":false}]
  let data = payload(
    @inspector.process_input(input, "json", "resolve", "json", "", "x:counter"),
  )
  assert_eq(data.contains("9007199254740993"), true)
  assert_eq(data.contains("door"), false)
  assert_eq(
    payload(
      @inspector.process_input(input, "json", "resolve", "json", "", "missing"),
    ),
    "[]",
  )
}

///|
test "bridge accepts byte transport and emits independent CBOR" {
  let json = payload(
    @inspector.process_input(
      "81a20061780201", "cbor", "resolve", "json", "1793000000", "",
    ),
  )
  assert_eq(json.contains("\"n\":\"x\""), true)
  let wire = payload(
    @inspector.process_input(
      "81a20061780201", "cbor", "resolve", "cbor", "1793000000", "",
    ),
  )
  let again = payload(
    @inspector.process_input(wire, "cbor", "resolve", "json", "", ""),
  )
  assert_eq(again, json)
  assert_eq(
    error_code(@inspector.process_input("zz", "cbor", "check", "json", "", "")),
    "InvalidCbor",
  )
}

///|
test "bridge rejects invalid reference times invalid formats and arithmetic overflow" {
  for now in ["NaN", "inf", "bad", "1e999", "0"] {
    assert_eq(
      error_code(
        @inspector.process_input("[]", "json", "check", "json", now, ""),
      ),
      "InvalidReferenceTime",
    )
  }
  assert_eq(
    error_code(@inspector.process_input("[]", "bad", "check", "json", "", "")),
    "InvalidArguments",
  )
  assert_eq(
    error_code(@inspector.process_input("[]", "json", "bad", "json", "", "")),
    "InvalidArguments",
  )
  let bad = "[{\"n\":\"x\",\"v\":1e308,\"bv\":1e308,\"t\":1793000000}]"
  assert_eq(
    error_code(@inspector.process_input(bad, "json", "check", "json", "", "")),
    "ArithmeticOverflow",
  )
}
