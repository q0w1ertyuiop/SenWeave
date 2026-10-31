///|
/// A validated RFC 9193 Content-Format-Spec for a binary data value. The
/// original spelling is retained; no registry lookup or content decoding occurs.
pub struct ContentFormatSpec {
  priv literal : String
  priv number : Int32?
} derive(Debug)

///|
pub extend ContentFormatSpec with Debug::{to_repr}

///|
pub fn ContentFormatSpec::as_string(self : ContentFormatSpec) -> String {
  self.literal
}

///|
/// Return the CoAP number for a numeric specification, otherwise None.
pub fn ContentFormatSpec::coap_number(self : ContentFormatSpec) -> Int32? {
  self.number
}

///|
/// Check RFC 9193 Section 6 syntax, including parameters and ordered codings.
/// Numeric identifiers need not be registered. String length counts UTF-16
/// code units; pack parsing uses the caller's ParseLimits instead.
pub fn ContentFormatSpec::parse(
  input : String,
  max_code_units~ : Int32 = 65_536,
) -> ContentFormatSpec raise SenmlError {
  if max_code_units <= 0 {
    reject(
      InvalidLimits,
      None,
      None,
      "Content-format length limit must be positive.",
    )
  }
  if input.length() > max_code_units {
    reject(StringLimit, None, None, "Content format exceeds the string limit.")
  }
  checked_content_format(input, None, None)
}

///|
fn content_format_alnum(code : UInt16) -> Bool {
  (code >= 48 && code <= 57) ||
  (code >= 65 && code <= 90) ||
  (code >= 97 && code <= 122)
}

///|
fn content_format_token(code : UInt16) -> Bool {
  content_format_alnum(code) ||
  (match code {
    33
    | 35
    | 36
    | 37
    | 38
    | 39
    | 42
    | 43
    | 45
    | 46
    | 94
    | 95
    | 96
    | 124
    | 126 => true
    _ => false
  })
}

///|
fn content_format_name(units : Array[UInt16], start : Int32) -> Int32 {
  if start >= units.length() || !content_format_alnum(units[start]) {
    return -1
  }
  let mut end = start + 1
  while end < units.length() {
    let code = units[end]
    if !content_format_alnum(code) &&
      !(code == 33 ||
      code == 35 ||
      code == 36 ||
      code == 38 ||
      code == 45 ||
      code == 94 ||
      code == 95 ||
      code == 46 ||
      code == 43) {
      break
    }
    end += 1
  }
  if end - start > 127 {
    -1
  } else {
    end
  }
}

///|
fn content_format_string_valid(units : Array[UInt16]) -> Bool {
  let slash = content_format_name(units, 0)
  if slash < 0 || slash >= units.length() || units[slash] != 47 {
    return false
  }
  let mut cursor = content_format_name(units, slash + 1)
  if cursor < 0 {
    return false
  }
  // Parameters are scanned before codings so an @ inside a quoted value is
  // data. Splitting on @ or semicolons would corrupt legal parameter strings.
  while cursor < units.length() && units[cursor] != 64 {
    while cursor < units.length() && units[cursor] == 32 {
      cursor += 1
    }
    if cursor >= units.length() || units[cursor] != 59 {
      return false
    }
    cursor += 1
    while cursor < units.length() && units[cursor] == 32 {
      cursor += 1
    }
    let start = cursor
    while cursor < units.length() && content_format_token(units[cursor]) {
      cursor += 1
    }
    if cursor == start || cursor >= units.length() || units[cursor] != 61 {
      return false
    }
    cursor += 1
    if cursor < units.length() && units[cursor] == 34 {
      cursor += 1
      let mut closed = false
      while cursor < units.length() {
        let code = units[cursor]
        cursor += 1
        if code == 34 {
          closed = true
          break
        }
        if code == 92 {
          if cursor >= units.length() ||
            units[cursor] < 32 ||
            units[cursor] > 126 {
            return false
          }
          cursor += 1
        } else if code < 32 || code > 126 {
          return false
        }
      }
      if !closed {
        return false
      }
    } else {
      let start = cursor
      while cursor < units.length() && content_format_token(units[cursor]) {
        cursor += 1
      }
      if cursor == start {
        return false
      }
    }
  }
  while cursor < units.length() {
    if units[cursor] != 64 {
      return false
    }
    cursor += 1
    let start = cursor
    while cursor < units.length() && content_format_token(units[cursor]) {
      cursor += 1
    }
    if cursor == start {
      return false
    }
  }
  true
}

///|
fn checked_content_format(
  input : String,
  index : Int32?,
  field : String?,
) -> ContentFormatSpec raise SenmlError {
  let units = input.code_units().to_owned()
  let digits = !units.is_empty() && units.all(code => code >= 48 && code <= 57)
  let mut number : Int32? = None
  let valid = if digits {
    if units.length() > 5 || (units.length() > 1 && units[0] == 48) {
      false
    } else {
      let mut value = 0
      for code in units {
        value = value * 10 + code.to_int() - 48
      }
      number = Some(value)
      value <= 65535
    }
  } else {
    content_format_string_valid(units)
  }
  if !valid {
    reject(
      InvalidContentFormat,
      index,
      field,
      "Expected an RFC 9193 content-format string or decimal number from 0 to 65535.",
    )
  }
  { literal: input, number, }
}

///|
fn read_content_format(
  fields : Map[String, Json],
  index : Int32,
  field : String,
  limits : ParseLimits,
) -> ContentFormatSpec? raise SenmlError {
  read_text(fields, index, field, limits).map(text => {
    checked_content_format(text, Some(index), Some(field))
  })
}
