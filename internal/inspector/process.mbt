///|
fn error_result(code : String, message : String) -> String {
  Json::object({
    "ok": Json::boolean(false),
    "error": Json::object({
      "code": Json::string(code),
      "message": Json::string(message),
    }),
  }).stringify()
}

///|
/// String-only host bridge. JSON payload text stays opaque to the JS host so
/// its exact integer literals never pass through a host Number conversion.
pub fn process_input(
  input : String,
  input_format : String,
  action : String,
  output_format : String,
  reference_time_text : String,
  name : String,
) -> String {
  process_input_with_policy(
    input, input_format, action, output_format, reference_time_text, name, "{}",
  )
}

///|
/// Apply explicit host quotas and extension policy before semantic expansion.
/// The six-argument entry point preserves the default CLI profile.
pub fn process_input_with_policy(
  input : String,
  input_format : String,
  action : String,
  output_format : String,
  reference_time_text : String,
  name : String,
  policy_text : String,
) -> String {
  guard parse_policy(policy_text) is Some(policy) else {
    return error_result(
      "InvalidLimits", "Policy requires bounded positive integer quotas and a boolean extension setting.",
    )
  }
  if (input_format != "json" && input_format != "cbor" && input_format != "xml") ||
    (action != "check" && action != "resolve") ||
    (
      output_format != "json" &&
      output_format != "cbor" &&
      output_format != "xml"
    ) {
    return error_result(
      "InvalidArguments", "Unknown input format, command or output format.",
    )
  }
  let reference_time = if reference_time_text == "" {
    None
  } else {
    let value = Some(@string.parse_double(reference_time_text)) catch {
      _ => None
    }
    guard value is Some(n) && !n.is_nan() && !n.is_inf() else {
      return error_result(
        "InvalidReferenceTime", "Reference time must be finite POSIX seconds.",
      )
    }
    Some(n)
  }
  let bytes = if input_format == "cbor" {
    if input.length() > 2 * policy.max_input_bytes {
      return error_result(
        "InputLimit", "CBOR hex input exceeds the byte limit.",
      )
    }
    @hex.decode(input) catch {
      _ => return error_result("InvalidCbor", "Invalid CBOR hex transport.")
    }
  } else {
    if input.length() > policy.max_input_bytes {
      return error_result("InputLimit", "Text input exceeds the input limit.")
    }
    @utf8.encode(input)
  }
  let result = try {
    let format = if input_format == "json" {
      @senweave.SenmlJson
    } else if input_format == "xml" {
      @senweave.SenmlXml
    } else {
      @senweave.SenmlCbor
    }
    let raw = @senweave.parse_payload(
      bytes,
      format,
      limits=policy.parse_limits,
      max_input_bytes=policy.max_input_bytes,
      reject_extensions=policy.reject_extensions,
    )
    let ignored_extensions = raw.ignored_extension_count()
    let resolved = raw.resolve(
      reference_time?,
      max_expanded_code_units=policy.max_expanded_code_units,
    )
    let selected = if name == "" {
      resolved
    } else {
      resolved.filter(record => record.name == name)
    }
    let data = if action == "check" {
      Json::object({
        "valid": Json::boolean(true),
        "stage": Json::string("resolved"),
        "raw_records": Json::number(raw.len().to_double()),
        "measurements": Json::number(resolved.len().to_double()),
        "ignored_extensions": Json::number(ignored_extensions.to_double()),
      }).stringify()
    } else if output_format == "json" {
      selected.to_json_string()
    } else if output_format == "xml" {
      selected.to_xml_string(max_output_code_units=policy.max_output_bytes)
    } else {
      @hex.encode(
        selected.to_cbor_bytes(max_output_bytes=policy.max_output_bytes),
      )
    }
    if action == "resolve" &&
      output_format != "cbor" &&
      @utf8.encode(data).length() > policy.max_output_bytes {
      return error_result("OutputLimit", "Text output exceeds the byte limit.")
    }
    Json::object({
      "ok": Json::boolean(true),
      "data": Json::string(data),
      "ignored_extensions": Json::number(ignored_extensions.to_double()),
    }).stringify()
  } catch {
    error => {
      let diagnostic = error.diagnostic()
      let fields : Map[String, Json] = {
        "code": Json::string("\{Repr(diagnostic.code)}"),
        "message": Json::string(diagnostic.message),
      }
      if diagnostic.record_index is Some(n) {
        fields["record_index"] = Json::number(n.to_double())
      }
      if diagnostic.field is Some(field) {
        fields["field"] = Json::string(field)
      }
      if diagnostic.line is Some(n) {
        fields["line"] = Json::number(n.to_double())
      }
      if diagnostic.column is Some(n) {
        fields["column"] = Json::number(n.to_double())
      }
      Json::object({ "ok": Json::boolean(false), "error": Json::object(fields) }).stringify()
    }
  }
  result
}
