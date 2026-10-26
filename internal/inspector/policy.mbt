///|
// The bridge accepts only tighter quotas than the default library profile.
// These are host admission settings, never SenML fields.
priv struct Policy {
  parse_limits : @senweave.ParseLimits
  max_input_bytes : Int32
  max_expanded_code_units : Int32
  max_output_bytes : Int32
  reject_extensions : Bool
}

///|
fn parse_policy(text : String) -> Policy? {
  if text.length() > 2048 {
    return None
  }
  let root = @json.parse(text, max_nesting_depth=2, reject_duplicate_keys=true) catch {
    _ => return None
  }
  guard root is Json::Object(fields) else { return None }
  let quotas : Map[String, Int32] = {
    "maxInputBytes": 1_048_576,
    "maxRecords": 4096,
    "maxDepth": 32,
    "maxFieldsPerRecord": 64,
    "maxStringCodeUnits": 65_536,
    "maxNumberCodeUnits": 128,
    "maxExpandedCodeUnits": 4_194_304,
    "maxOutputBytes": 4_194_304,
  }
  for key, value in fields {
    if key == "rejectExtensions" {
      continue
    }
    guard quotas.get(key) is Some(ceiling) else { return None }
    guard value is Json::Number(number, ..) &&
      number >= 1.0 &&
      number <= ceiling.to_double() &&
      number.to_int().to_double() == number else {
      return None
    }
    quotas[key] = number.to_int()
  }
  let reject_extensions = match fields.get("rejectExtensions") {
    None | Some(Json::False) => false
    Some(Json::True) => true
    _ => return None
  }
  Some({
    parse_limits: {
      max_input_code_units: quotas.get("maxInputBytes").unwrap(),
      max_records: quotas.get("maxRecords").unwrap(),
      max_depth: quotas.get("maxDepth").unwrap(),
      max_fields_per_record: quotas.get("maxFieldsPerRecord").unwrap(),
      max_string_code_units: quotas.get("maxStringCodeUnits").unwrap(),
      max_number_code_units: quotas.get("maxNumberCodeUnits").unwrap(),
    },
    max_input_bytes: quotas.get("maxInputBytes").unwrap(),
    max_expanded_code_units: quotas.get("maxExpandedCodeUnits").unwrap(),
    max_output_bytes: quotas.get("maxOutputBytes").unwrap(),
    reject_extensions,
  })
}
