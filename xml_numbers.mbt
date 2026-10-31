///|
// XML Schema numbers have a different lexical space from JSON numbers.
// Normalize signs, leading zeros, decimal points and exponents before reusing
// the shared finite-number checks. Exact integer digits never pass through JS.
fn xml_number(
  text : String,
  index : Int32,
  label : String,
  limits : ParseLimits,
) -> Json raise SenmlError {
  let text = text.trim(chars=" \t\r\n").to_owned()
  if text.length() > limits.max_number_code_units {
    reject(
      NumberLimit,
      Some(index),
      Some(label),
      "XML number exceeds the configured limit.",
    )
  }
  let units = text.code_units().to_owned()
  let mut position = 0
  let negative = units.get(position) == Some(45)
  if negative || units.get(position) == Some(43) {
    position += 1
  }
  let integer_start = position
  while position < units.length() &&
        units[position] >= 48 &&
        units[position] <= 57 {
    position += 1
  }
  let integer_end = position
  let mut fraction_start = position
  let mut fraction_end = position
  let has_decimal = units.get(position) == Some(46)
  if has_decimal {
    position += 1
    fraction_start = position
    while position < units.length() &&
          units[position] >= 48 &&
          units[position] <= 57 {
      position += 1
    }
    fraction_end = position
  }
  let exponent_start = position
  if units.get(position) == Some(101) || units.get(position) == Some(69) {
    position += 1
    if units.get(position) == Some(43) || units.get(position) == Some(45) {
      position += 1
    }
    let digit_start = position
    while position < units.length() &&
          units[position] >= 48 &&
          units[position] <= 57 {
      position += 1
    }
    if digit_start == position {
      reject(
        InvalidNumber,
        Some(index),
        Some(label),
        "Invalid XML numeric lexical form.",
      )
    }
  }
  if position != units.length() ||
    (integer_start == integer_end && fraction_start == fraction_end) ||
    (label == "bver" && (has_decimal || exponent_start != position)) {
    reject(
      InvalidNumber,
      Some(index),
      Some(label),
      "Expected a finite XML number or integral version.",
    )
  }
  let builder = StringBuilder()
  if negative {
    builder.write_string("-")
  }
  let mut significant_start = integer_start
  while significant_start < integer_end && units[significant_start] == 48 {
    significant_start += 1
  }
  if significant_start == integer_end {
    builder.write_string("0")
  } else {
    builder.write_string(text[significant_start:integer_end].to_owned())
  }
  if has_decimal {
    builder.write_string(".")
    if fraction_start == fraction_end {
      builder.write_string("0")
    } else {
      builder.write_string(text[fraction_start:fraction_end].to_owned())
    }
  }
  if exponent_start < units.length() {
    builder.write_string("e")
    builder.write_string(text[exponent_start + 1:].to_owned())
  }
  let literal = builder.to_string()
  let value = @string.parse_double(literal) catch {
    _ => {
      reject(
        InvalidNumber,
        Some(index),
        Some(label),
        "Invalid XML numeric lexical form.",
      )
      0.0
    }
  }
  Json::number(value, repr=literal)
}
