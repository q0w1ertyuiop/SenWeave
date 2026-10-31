///|
// A SenML wire reader: keep integer arguments unsigned until their meaning is
// known, and skip extensions without constructing a generic CBOR object tree.
priv struct CborReader {
  input : Bytes
  mut offset : Int32
  limits : ParseLimits
}

///|
priv struct CborHead {
  major : Int32
  info : Int32
  argument : UInt64
}

///|
fn CborReader::byte(self : CborReader) -> Int32 raise SenmlError {
  if self.offset >= self.input.length() {
    reject(InvalidCbor, None, None, "Truncated CBOR input.")
  }
  let value = self.input[self.offset].to_int()
  self.offset += 1
  value
}

///|
fn CborReader::head(
  self : CborReader,
  depth : Int32,
) -> CborHead raise SenmlError {
  if depth > self.limits.max_depth {
    reject(
      NestingLimit,
      None,
      None,
      "CBOR item nesting exceeds the configured limit.",
    )
  }
  let initial = self.byte()
  let major = initial >> 5
  let info = initial & 31
  if major == 7 && info == 31 {
    reject(InvalidCbor, None, None, "Unexpected CBOR break.")
  }
  let width = match info {
    0..<=23 => 0
    24 => 1
    25 => 2
    26 => 4
    27 => 8
    31 if major >= 2 && major <= 5 => 0
    _ => {
      reject(
        UnsupportedCborType,
        None,
        None,
        "Reserved CBOR item or unexpected break.",
      )
      0
    }
  }
  let mut argument = if info < 24 { info.to_uint64() } else { 0UL }
  for _ in 0..<width {
    argument = (argument << 8) | self.byte().to_uint64()
  }
  if major == 7 && info == 24 && argument < 32UL {
    reject(InvalidCbor, None, None, "Invalid two-byte CBOR simple value.")
  }
  { major, info, argument, }
}

///|
fn CborReader::take(
  self : CborReader,
  length : UInt64,
) -> BytesView raise SenmlError {
  if length > (self.input.length() - self.offset).to_uint64() {
    reject(InvalidCbor, None, None, "CBOR length exceeds remaining input.")
  }
  let start = self.offset
  self.offset += length.to_int()
  self.input.exact_view(start~, end=self.offset)
}

///|
fn CborReader::count(
  self : CborReader,
  head : CborHead,
  minimum : Int32,
) -> Int32 raise SenmlError {
  if head.argument > ((self.input.length() - self.offset) / minimum).to_uint64() {
    reject(
      InvalidCbor,
      None,
      None,
      "CBOR container count exceeds remaining input.",
    )
  }
  head.argument.to_int()
}

///|
fn CborReader::take_break(self : CborReader) -> Bool {
  if self.offset < self.input.length() && self.input[self.offset] == 0xff {
    self.offset += 1
    true
  } else {
    false
  }
}

///|
fn CborReader::text_chunk(
  self : CborReader,
  head : CborHead,
  max_units : Int32,
  index? : Int32,
  label? : String,
) -> String raise SenmlError {
  if head.argument > (self.input.length() - self.offset).to_uint64() {
    reject(InvalidCbor, None, None, "CBOR length exceeds remaining input.")
  }
  // Every Unicode scalar takes at most three UTF-8 bytes per UTF-16 unit.
  if head.argument > (3L * max_units.to_int64()).reinterpret_as_uint64() {
    reject(
      StringLimit,
      index,
      label,
      "CBOR text exceeds the configured string limit.",
    )
  }
  let text = @utf8.decode(self.take(head.argument), ignore_bom=false) catch {
    _ => {
      reject(InvalidCbor, None, None, "Invalid UTF-8 in CBOR text.")
      ""
    }
  }
  if text.length() > max_units {
    reject(
      StringLimit,
      index,
      label,
      "CBOR text exceeds the configured string limit.",
    )
  }
  text
}

///|
fn CborReader::text(
  self : CborReader,
  head : CborHead,
  depth : Int32,
  definite~ : Bool = false,
  index? : Int32,
  label? : String,
) -> String raise SenmlError {
  if head.info != 31 {
    return self.text_chunk(
      head,
      self.limits.max_string_code_units,
      index?,
      label?,
    )
  }
  if definite {
    reject(
      UnsupportedCborType,
      None,
      None,
      "SenML string values must have definite length.",
    )
  }
  let builder = StringBuilder()
  let mut units = 0
  while !self.take_break() {
    let chunk = self.head(depth + 1)
    if chunk.major != 3 || chunk.info == 31 {
      reject(InvalidCbor, None, None, "Invalid CBOR text chunk.")
    }
    let text = self.text_chunk(
      chunk,
      self.limits.max_string_code_units - units,
      index?,
      label?,
    )
    units += text.length()
    builder.write_string(text)
  }
  builder.to_string()
}

///|
fn CborReader::skip(
  self : CborReader,
  head : CborHead,
  depth : Int32,
) -> Unit raise SenmlError {
  match head.major {
    2 | 3 =>
      if head.info != 31 {
        if head.major == 3 {
          let _ = self.text_chunk(head, self.input.length())
        } else {
          let _ = self.take(head.argument)
        }
      } else {
        while !self.take_break() {
          let chunk = self.head(depth + 1)
          if chunk.major != head.major || chunk.info == 31 {
            reject(InvalidCbor, None, None, "Invalid CBOR string chunk.")
          }
          self.skip(chunk, depth + 1)
        }
      }
    4 | 5 => {
      let count = if head.info == 31 {
        -1
      } else {
        self.count(head, if head.major == 5 { 2 } else { 1 })
      }
      let mut index = 0
      while index != count {
        if count == -1 && self.take_break() {
          break
        }
        self.skip(self.head(depth + 1), depth + 1)
        if head.major == 5 {
          self.skip(self.head(depth + 1), depth + 1)
        }
        index += 1
      }
    }
    6 => self.skip(self.head(depth + 1), depth + 1)
    _ => ()
  }
}

///|
fn cbor_integer_literal(head : CborHead) -> String {
  if head.major == 0 {
    head.argument.to_string()
  } else if head.argument == 18446744073709551615UL {
    "-18446744073709551616"
  } else {
    "-\{head.argument + 1UL}"
  }
}

///|
fn CborReader::number(
  self : CborReader,
  head : CborHead,
  depth : Int32,
  index : Int32,
  label : String,
) -> Json raise SenmlError {
  if head.major == 0 || head.major == 1 {
    return @json.parse(cbor_integer_literal(head), preserve_number_repr=true) catch {
      _ => {
        reject(InvalidNumber, Some(index), Some(label), "Invalid CBOR integer.")
        Json::null()
      }
    }
  }
  if head.major == 7 && head.info >= 25 && head.info <= 27 {
    let width = if head.info == 25 {
      2
    } else if head.info == 26 {
      4
    } else {
      8
    }
    let bytes = self.input
      .exact_view(start=self.offset - width - 1, end=self.offset)
      .to_owned()
    let value = @cbor.decode(bytes) catch {
      _ => {
        reject(InvalidCbor, None, None, "Invalid CBOR floating-point encoding.")
        @cbor.Float64(0.0)
      }
    }
    guard value is @cbor.Float64(number) else { return Json::null() }
    if number.is_nan() || number.is_inf() {
      reject(
        InvalidNumber,
        Some(index),
        Some(label),
        "SenML numeric fields must be finite.",
      )
    }
    return Json::number(number)
  }
  // Tag 4 reuses the JSON decimal parser and the common numeric validator.
  let array = self.head(depth + 1)
  if array.major != 4 || (array.info != 31 && array.argument != 2UL) {
    reject(
      WrongType,
      Some(index),
      Some(label),
      "Decimal fraction requires two integers.",
    )
  }
  let exponent = self.head(depth + 2)
  if exponent.major != 0 && exponent.major != 1 {
    reject(
      WrongType,
      Some(index),
      Some(label),
      "Decimal fraction requires two integers.",
    )
  }
  let mantissa = self.head(depth + 2)
  if mantissa.major != 0 && mantissa.major != 1 {
    reject(
      WrongType,
      Some(index),
      Some(label),
      "Decimal fraction requires two integers.",
    )
  }
  if array.info == 31 && !self.take_break() {
    reject(
      WrongType,
      Some(index),
      Some(label),
      "Decimal fraction requires two integers.",
    )
  }
  @json.parse(
    "\{cbor_integer_literal(mantissa)}e\{cbor_integer_literal(exponent)}",
    preserve_number_repr=true,
  ) catch {
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
