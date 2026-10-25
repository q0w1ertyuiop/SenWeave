///|
/// Parse RFC 8428 SenML JSON using the documented bounded version-10 profile.
/// Duplicate decoded keys are rejected, optional extensions are ignored, and
/// unknown underscore-suffixed extensions fail closed. Input is already-decoded
/// Unicode; a byte-oriented caller must decode UTF-8 strictly before this call.
/// This returns RAW records. It does not resolve time, units, or base values.
pub fn parse_json(
  input : String,
  limits~ : ParseLimits = ParseLimits::default(),
) -> Pack raise SenmlError {
  limits.validate()
  if input.length() > limits.max_input_code_units {
    reject(
      InputLimit,
      None,
      None,
      "Input exceeds the configured UTF-16 code-unit limit.",
    )
  }
  let root = @json.parse(
    input,
    max_nesting_depth=limits.max_depth,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    @json.DuplicateKey(position, key) => {
      reject(
        DuplicateKey,
        None,
        Some(key),
        "Duplicate decoded JSON member name.",
        line=position.line,
        column=position.column,
      )
      Json::null()
    }
    @json.DepthLimitExceeded => {
      reject(
        NestingLimit,
        None,
        None,
        "JSON nesting exceeds the configured limit.",
      )
      Json::null()
    }
    @json.InvalidChar(position, _)
    | @json.InvalidNumber(position, _)
    | @json.InvalidIdentEscape(position) => {
      reject(
        InvalidJson,
        None,
        None,
        "Invalid JSON syntax or Unicode string.",
        line=position.line,
        column=position.column,
      )
      Json::null()
    }
    @json.InvalidEof => {
      reject(InvalidJson, None, None, "Incomplete JSON input.")
      Json::null()
    }
  }
  let items = match root {
    Json::Array(items) => items
    _ => {
      reject(InvalidRoot, None, None, "SenML JSON must be an array of records.")
      []
    }
  }
  if items.length() > limits.max_records {
    reject(RecordLimit, None, None, "Pack exceeds the configured record limit.")
  }
  let records = []
  let mut base_name = ""
  for index, item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ => {
        reject(
          InvalidRecord,
          Some(index),
          None,
          "Each SenML record must be a JSON object.",
        )
        {}
      }
    }
    let record = parse_record(fields, index, limits)
    if record.base_name is Some(name) {
      base_name = name
    }
    if record.is_measurement() {
      validate_name(base_name, record.name.unwrap_or(""), index)
    }
    records.push(record)
  }
  { records, }
}

///|
fn parse_record(
  fields : Map[String, Json],
  index : Int32,
  limits : ParseLimits,
) -> Record raise SenmlError {
  if fields.length() > limits.max_fields_per_record {
    reject(
      FieldLimit,
      Some(index),
      None,
      "Record exceeds the configured member limit.",
    )
  }
  let mut ignored_extension_count = 0
  for key, _ in fields {
    if key.length() > limits.max_string_code_units {
      reject(
        StringLimit,
        Some(index),
        None,
        "Member name exceeds the configured string limit.",
      )
    }
    if Label::from_json_name(key) is None {
      if key.has_suffix("_") {
        reject(
          UnsupportedExtension,
          Some(index),
          Some(key),
          "Unknown extension requires explicit understanding.",
        )
      }
      ignored_extension_count += 1
    }
  }
  let base_name = read_text(fields, index, "bn", limits)
  let base_time = read_number(fields, index, "bt", limits)
  let base_unit = read_text(fields, index, "bu", limits)
  let base_value = read_number(fields, index, "bv", limits)
  let base_sum = read_number(fields, index, "bs", limits)
  let base_version = read_number(fields, index, "bver", limits)
  if base_version is Some(version) && !version.is_version_ten() {
    reject(
      UnsupportedVersion,
      Some(index),
      Some("bver"),
      "This input profile supports SenML version 10 only.",
    )
  }
  let name = read_text(fields, index, "n", limits)
  let unit = read_text(fields, index, "u", limits)
  let sum = read_number(fields, index, "s", limits)
  let time = read_number(fields, index, "t", limits)
  let update_time = read_number(fields, index, "ut", limits)
  let mut value_count = 0
  for key in ["v", "vs", "vb", "vd"] {
    if fields.contains(key) {
      value_count += 1
    }
  }
  if value_count > 1 {
    reject(
      ConflictingValues,
      Some(index),
      None,
      "A record may contain at most one measurement value field.",
    )
  }
  let value = if fields.contains("v") {
    read_number(fields, index, "v", limits).map(number => {
      MeasurementValue::Numeric(number)
    })
  } else if fields.contains("vs") {
    read_text(fields, index, "vs", limits).map(text => {
      MeasurementValue::Text(text)
    })
  } else if fields.contains("vb") {
    match fields.get("vb") {
      Some(Json::True) => Some(MeasurementValue::Boolean(true))
      Some(Json::False) => Some(MeasurementValue::Boolean(false))
      _ => {
        reject(WrongType, Some(index), Some("vb"), "Expected a JSON boolean.")
        None
      }
    }
  } else if fields.contains("vd") {
    let text = read_text(fields, index, "vd", limits).unwrap()
    Some(MeasurementValue::Data(read_data(text, index)))
  } else {
    None
  }
  if value is None && sum is None {
    let has_base = base_name is Some(_) ||
      base_time is Some(_) ||
      base_unit is Some(_) ||
      base_value is Some(_) ||
      base_sum is Some(_) ||
      base_version is Some(_)
    let has_regular = name is Some(_) ||
      unit is Some(_) ||
      time is Some(_) ||
      update_time is Some(_)
    if !has_base || has_regular {
      reject(
        MissingValue,
        Some(index),
        None,
        "A measurement needs one value or a sum; base-only context records are allowed.",
      )
    }
  }
  {
    base_name,
    base_time,
    base_unit,
    base_value,
    base_sum,
    base_version,
    name,
    unit,
    value,
    sum,
    time,
    update_time,
    ignored_extension_count,
  }
}
