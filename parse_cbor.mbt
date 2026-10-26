///|
/// Parse a bounded definite-length SenML CBOR pack into raw records.
/// limits controls records, fields, text/binary size, number text and item depth;
/// max_input_bytes replaces the JSON-only max_input_code_units input limit.
/// Known labels must use their RFC integer keys; extension labels use text.
pub fn parse_cbor(
  input : Bytes,
  limits~ : ParseLimits = ParseLimits::default(),
  max_input_bytes~ : Int32 = 1_048_576,
) -> Pack raise SenmlError {
  limits.validate()
  if max_input_bytes <= 0 {
    reject(InvalidLimits, None, None, "CBOR byte limit must be positive.")
  }
  if input.length() > max_input_bytes {
    reject(InputLimit, None, None, "CBOR input exceeds the byte limit.")
  }
  scan_cbor(input, limits)
  let root = @cbor.decode(input) catch {
    _ => {
      reject(InvalidCbor, None, None, "Invalid CBOR encoding or Unicode text.")
      @cbor.Array([])
    }
  }
  guard root is @cbor.Array(items) else {
    reject(InvalidRoot, None, None, "SenML CBOR must be an array.")
    return { records: [], }
  }
  let records = []
  for index, item in items {
    guard item is @cbor.Map(entries) else {
      reject(
        InvalidRecord,
        Some(index),
        None,
        "Each SenML CBOR record must be a map.",
      )
      continue
    }
    let fields : Map[String, Json] = Map([])
    let mut data : Bytes? = None
    for (key, value) in entries {
      let label = cbor_label(key, index)
      if fields.contains(label) {
        reject(
          DuplicateKey,
          Some(index),
          Some(label),
          "Duplicate SenML CBOR label.",
        )
      }
      let known = Label::from_json_name(label)
      fields[label] = match known {
        None => Json::null()
        Some(DataValue) => {
          guard value is @cbor.Bytes(bytes) else {
            reject(
              WrongType,
              Some(index),
              Some(label),
              "Expected a definite-length CBOR byte string.",
            )
            continue
          }
          if bytes.length() > limits.max_string_code_units {
            reject(
              StringLimit,
              Some(index),
              Some(label),
              "Binary data exceeds the configured byte limit.",
            )
          }
          data = Some(bytes)
          Json::null()
        }
        Some(BaseVersion) =>
          match value {
            @cbor.Integer(n) if n >= 0L =>
              Json::number(n.to_double(), repr=n.to_string())
            @cbor.Unsigned(n) => Json::number(n.to_double(), repr=n.to_string())
            _ => {
              reject(
                WrongType,
                Some(index),
                Some(label),
                "CBOR base version must be an unsigned integer.",
              )
              Json::null()
            }
          }
        Some(_) => cbor_field_json(value, index, label)
      }
    }
    records.push(parse_record(fields, index, limits, data?))
  }
  validated_pack(records)
}

///|
fn cbor_label(key : @cbor.CborValue, index : Int32) -> String raise SenmlError {
  let label = match key {
    @cbor.Integer(n) if n >= -6L && n <= 8L => Label::from_cbor_key(n.to_int())
    @cbor.Unsigned(n) if n <= 8UL => Label::from_cbor_key(n.to_int())
    @cbor.Text(text) if Label::from_json_name(text) is None => return text
    _ => None
  }
  match label {
    Some(label) => label.json_name()
    None => {
      reject(
        InvalidCborLabel,
        Some(index),
        None,
        "Expected an RFC integer label or a text extension label.",
      )
      ""
    }
  }
}

///|
fn cbor_integer_text(value : @cbor.CborValue) -> String? {
  match value {
    @cbor.Integer(n) => Some(n.to_string())
    @cbor.Unsigned(n) => Some(n.to_string())
    _ => None
  }
}

///|
fn cbor_field_json(
  value : @cbor.CborValue,
  index : Int32,
  label : String,
) -> Json raise SenmlError {
  match value {
    @cbor.Integer(n) => Json::number(n.to_double(), repr=n.to_string())
    @cbor.Unsigned(n) => Json::number(n.to_double(), repr=n.to_string())
    @cbor.Float64(n) => {
      if n.is_nan() || n.is_inf() {
        reject(
          InvalidNumber,
          Some(index),
          Some(label),
          "SenML numeric fields must be finite.",
        )
      }
      Json::number(n)
    }
    @cbor.Text(text) => Json::string(text)
    @cbor.Simple(20) => Json::boolean(false)
    @cbor.Simple(21) => Json::boolean(true)
    @cbor.Tag(4UL, @cbor.Array([exponent, mantissa])) => {
      guard cbor_integer_text(exponent) is Some(exponent) &&
        cbor_integer_text(mantissa) is Some(mantissa) else {
        reject(
          WrongType,
          Some(index),
          Some(label),
          "Decimal fraction requires an integer exponent and mantissa.",
        )
        return Json::null()
      }
      // Reuse the standard decimal-to-binary64 parser, retaining the decimal
      // fraction's exact exponent/mantissa text for the shared number validator.
      @json.parse("\{mantissa}e\{exponent}", preserve_number_repr=true) catch {
        _ => {
          reject(
            InvalidNumber,
            Some(index),
            Some(label),
            "Invalid CBOR decimal fraction.",
          )
          Json::null()
        }
      }
    }
    _ => Json::null()
  }
}
