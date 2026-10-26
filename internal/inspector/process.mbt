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
  if (input_format != "json" && input_format != "cbor") ||
    (action != "check" && action != "resolve") ||
    (output_format != "json" && output_format != "cbor") {
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
    if input.length() > 2_097_152 {
      return error_result(
        "InputLimit", "CBOR hex input exceeds the byte limit.",
      )
    }
    @hex.decode(input) catch {
      _ => return error_result("InvalidCbor", "Invalid CBOR hex transport.")
    }
  } else {
    b""
  }
  let result = try {
    let raw = if input_format == "json" {
      @senweave.parse_json(input)
    } else {
      @senweave.parse_cbor(bytes)
    }
    let mut ignored_extensions = 0
    for i in 0..<raw.len() {
      ignored_extensions += raw.record(i).unwrap().ignored_extension_count
    }
    let resolved = raw.resolve(reference_time?)
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
    } else {
      @hex.encode(selected.to_cbor_bytes())
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
