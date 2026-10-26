///|
fn with_policy(
  input : String,
  policy : String,
  action~ : String = "check",
  output~ : String = "json",
) -> String {
  @inspector.process_input_with_policy(
    input, "json", action, output, "1793000000", "", policy,
  )
}

///|
test "bridge rejects malformed duplicate unknown and relaxed quota settings" {
  for
    policy in [
      "null", "[]", "{", "{\"extra\":1}", "{\"maxRecords\":0}", "{\"maxRecords\":4097}",
      "{\"maxRecords\":1.5}", "{\"maxRecords\":\"1\"}", "{\"maxRecords\":1,\"maxRecords\":2}",
      "{\"rejectExtensions\":1}", "{\"maxDepth\":33}",
    ] {
    assert_eq(error_code(with_policy("[]", policy)), "InvalidLimits")
  }
}

///|
test "bridge quotas constrain records fields strings numbers and nested extensions" {
  let input = "[{\"n\":\"abc\",\"v\":123,\"t\":1793000000},{\"n\":\"b\",\"v\":2}]"
  for
    (policy, code) in [
      ("{\"maxInputBytes\":2}", "InputLimit"),
      ("{\"maxRecords\":1}", "RecordLimit"),
      ("{\"maxFieldsPerRecord\":2}", "FieldLimit"),
      ("{\"maxStringCodeUnits\":2}", "StringLimit"),
      ("{\"maxNumberCodeUnits\":2}", "NumberLimit"),
      ("{\"maxExpandedCodeUnits\":2}", "ExpansionLimit"),
    ] {
    assert_eq(error_code(with_policy(input, policy)), code)
  }
  assert_eq(
    error_code(
      with_policy(
        "[{\"n\":\"x\",\"v\":1,\"vendor\":[[[]]]}]", "{\"maxDepth\":3}",
      ),
    ),
    "NestingLimit",
  )
}

///|
test "strict extension admission precedes missing clock and arithmetic expansion" {
  let input = "[{\"n\":\"x\",\"v\":1e308,\"bv\":1e308,\"vendor\":true}]"
  assert_eq(
    error_code(
      @inspector.process_input_with_policy(
        input, "json", "check", "json", "", "", "{\"rejectExtensions\":true}",
      ),
    ),
    "IgnoredExtensions",
  )
  assert_eq(
    error_code(
      @inspector.process_input_with_policy(
        "81a30061780201617af5", "cbor", "check", "json", "", "", "{\"rejectExtensions\":true}",
      ),
    ),
    "IgnoredExtensions",
  )
}

///|
test "output budgets distinguish JSON bytes and conservative CBOR encoding" {
  assert_eq(
    payload(with_policy("[]", "{\"maxOutputBytes\":2}", action="resolve")),
    "[]",
  )
  assert_eq(
    error_code(with_policy("[]", "{\"maxOutputBytes\":1}", action="resolve")),
    "OutputLimit",
  )
  assert_eq(
    payload(
      with_policy(
        "[]",
        "{\"maxOutputBytes\":1}",
        action="resolve",
        output="cbor",
      ),
    ),
    "80",
  )
  assert_eq(
    error_code(
      with_policy(
        "[{\"n\":\"x\",\"v\":1}]",
        "{\"maxOutputBytes\":1}",
        action="resolve",
        output="cbor",
      ),
    ),
    "OutputLimit",
  )
  assert_eq(
    payload(with_policy("[]", "{\"maxExpandedCodeUnits\":2}", action="resolve")),
    "[]",
  )
}

///|
test "JSON policy byte limits include multibyte UTF-8 and policies are per call" {
  let input = "[{\"n\":\"x\",\"vs\":\"中\"}]"
  let policy = "{\"maxInputBytes\":\{input.length()}}"
  assert_eq(error_code(with_policy(input, policy)), "InputLimit")
  assert_eq(
    error_code(with_policy("[]", "{\"maxInputBytes\":1}")),
    "InputLimit",
  )
  assert_eq(payload(with_policy("[]", "{}", action="resolve")), "[]")
}
