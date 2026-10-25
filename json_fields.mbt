///|
fn read_text(
  fields : Map[String, Json],
  index : Int32,
  field : String,
  limits : ParseLimits,
) -> String? raise SenmlError {
  match fields.get(field) {
    None => None
    Some(Json::String(text)) => {
      if text.length() > limits.max_string_code_units {
        reject(
          StringLimit,
          Some(index),
          Some(field),
          "String exceeds the configured limit.",
        )
      }
      Some(text)
    }
    Some(_) => {
      reject(WrongType, Some(index), Some(field), "Expected a JSON string.")
      None
    }
  }
}

///|
fn read_number(
  fields : Map[String, Json],
  index : Int32,
  field : String,
  limits : ParseLimits,
) -> Number? raise SenmlError {
  match fields.get(field) {
    None => None
    Some(Json::Number(value, repr~)) => {
      let literal = repr.unwrap_or_else(() => Json::number(value).stringify())
      if literal.length() > limits.max_number_code_units {
        reject(
          NumberLimit,
          Some(index),
          Some(field),
          "Number text exceeds the configured limit.",
        )
      }
      let mut nonzero_mantissa = false
      for code_unit in literal.code_units() {
        let code = code_unit.to_int()
        if code == 'E' {
          reject(
            InvalidNumber,
            Some(index),
            Some(field),
            "SenML uses a lowercase exponent marker.",
          )
        }
        if code == 'e' {
          break
        }
        if code >= '1' && code <= '9' {
          nonzero_mantissa = true
        }
      }
      if value.is_inf() || value.is_nan() || (value == 0.0 && nonzero_mantissa) {
        reject(
          InvalidNumber,
          Some(index),
          Some(field),
          "Number is outside the finite binary64 input profile.",
        )
      }
      Some({ approximate: value, literal, })
    }
    Some(_) => {
      reject(WrongType, Some(index), Some(field), "Expected a JSON number.")
      None
    }
  }
}

///|
// Only called with a syntactically valid, bounded JSON number. Comparing the
// Double alone would accept a version such as 10.0000000000000001 as 10.
fn Number::is_version_ten(self : Number) -> Bool {
  if self.approximate != 10.0 {
    return false
  }
  let mut seen_one = false
  let mut after_decimal = false
  let mut fraction_digits = 0
  let mut trailing_zeros = 0
  let mut in_exponent = false
  let mut exponent_negative = false
  let mut exponent = 0
  for code_unit in self.literal.code_units() {
    let code = code_unit.to_int()
    if in_exponent {
      if code == '-' {
        exponent_negative = true
      } else if code != '+' && exponent < 100_000 {
        exponent = exponent * 10 + code - '0'
      }
    } else if code == 'e' {
      in_exponent = true
    } else if code == '.' {
      after_decimal = true
    } else {
      if after_decimal {
        fraction_digits += 1
      }
      if code == '1' && !seen_one {
        seen_one = true
      } else if code == '0' {
        if seen_one {
          trailing_zeros += 1
        }
      } else {
        return false
      }
    }
  }
  if exponent_negative {
    exponent = -exponent
  }
  seen_one && trailing_zeros - fraction_digits + exponent == 1
}

///|
fn read_data(text : String, index : Int32) -> Bytes raise SenmlError {
  for code_unit in text.code_units() {
    let code = code_unit.to_int()
    if !(code >= 'A' && code <= 'Z') &&
      !(code >= 'a' && code <= 'z') &&
      !(code >= '0' && code <= '9') &&
      code != '-' &&
      code != '_' {
      reject(
        InvalidData,
        Some(index),
        Some("vd"),
        "Expected unpadded base64url data.",
      )
    }
  }
  let standard = text
    .replace_all(old="-", new="+")
    .replace_all(old="_", new="/")
  @base64.decode(standard) catch {
    _ => {
      reject(
        InvalidData,
        Some(index),
        Some("vd"),
        "Invalid base64url length or unused bits.",
      )
      b""
    }
  }
}

///|
fn validate_name(
  base : String,
  name : String,
  index : Int32,
) -> Unit raise SenmlError {
  let mut at_start = true
  for part in [base, name] {
    for code_unit in part.code_units() {
      let code = code_unit.to_int()
      let alphanumeric = (code >= 'A' && code <= 'Z') ||
        (code >= 'a' && code <= 'z') ||
        (code >= '0' && code <= '9')
      if !alphanumeric &&
        (
          at_start ||
          (
            code != '-' &&
            code != ':' &&
            code != '.' &&
            code != '/' &&
            code != '_'
          )
        ) {
        reject(
          InvalidName,
          Some(index),
          Some("n"),
          "Combined base name and name violate the SenML name syntax.",
        )
      }
      at_start = false
    }
  }
  if at_start {
    reject(
      InvalidName,
      Some(index),
      Some("n"),
      "A measurement needs a nonempty combined name.",
    )
  }
}
