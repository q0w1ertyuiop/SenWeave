///|
/// Parse a bounded finite SenML CBOR pack into raw records. Record maps may
/// have indefinite length; nonpreferred argument widths are accepted. Known
/// labels use RFC integer keys, and extension labels use text.
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
  let reader = { input, offset: 0, limits, }
  let root = reader.head(1)
  if root.major != 4 {
    reject(InvalidRoot, None, None, "SenML CBOR must be an array.")
  }
  if root.info == 31 {
    reject(
      UnsupportedCborType,
      None,
      None,
      "Finite SenML packs require a definite-length array.",
    )
  }
  if root.argument > limits.max_records.to_uint64() {
    reject(RecordLimit, None, None, "Pack exceeds the configured record limit.")
  }
  let count = reader.count(root, 1)
  let records = []
  for index in 0..<count {
    records.push(reader.record(index))
  }
  if reader.offset != input.length() {
    reject(InvalidCbor, None, None, "Trailing bytes after SenML CBOR pack.")
  }
  validated_pack(records)
}

///|
fn CborReader::label(
  self : CborReader,
  head : CborHead,
  index : Int32,
) -> String raise SenmlError {
  let known = if head.major == 0 && head.argument <= 8UL {
    Label::from_cbor_key(head.argument.to_int())
  } else if head.major == 1 && head.argument <= 5UL {
    Label::from_cbor_key(-1 - head.argument.to_int())
  } else if head.major == 3 {
    let text = self.text(head, 3, index~)
    if Label::from_json_name(text) is None {
      return text
    }
    None
  } else {
    None
  }
  match known {
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
fn CborReader::field(
  self : CborReader,
  head : CborHead,
  index : Int32,
  label : String,
) -> Json raise SenmlError {
  if head.major == 0 ||
    head.major == 1 ||
    (head.major == 7 && head.info >= 25 && head.info <= 27) ||
    (head.major == 6 && head.argument == 4UL) {
    return self.number(head, 3, index, label)
  }
  if head.major == 3 {
    return Json::string(
      self.text(head, 3, definite=label == "vs", index~, label~),
    )
  }
  if head.major == 7 && (head.info == 20 || head.info == 21) {
    return Json::boolean(head.info == 21)
  }
  self.skip(head, 3)
  Json::null()
}

///|
fn CborReader::record(
  self : CborReader,
  index : Int32,
) -> Record raise SenmlError {
  let map = self.head(2)
  if map.major != 5 {
    reject(
      InvalidRecord,
      Some(index),
      None,
      "Each SenML CBOR record must be a map.",
    )
  }
  if map.info != 31 &&
    map.argument > self.limits.max_fields_per_record.to_uint64() {
    reject(
      FieldLimit,
      Some(index),
      None,
      "Record exceeds the configured member limit.",
    )
  }
  let count = if map.info == 31 { -1 } else { self.count(map, 2) }
  let fields : Map[String, Json] = Map([])
  let mut data : Bytes? = None
  let mut members = 0
  while members != count {
    if count == -1 && self.take_break() {
      break
    }
    if members >= self.limits.max_fields_per_record {
      reject(
        FieldLimit,
        Some(index),
        None,
        "Record exceeds the configured member limit.",
      )
    }
    let label = self.label(self.head(3), index)
    if fields.contains(label) {
      reject(
        DuplicateKey,
        Some(index),
        Some(label),
        "Duplicate SenML CBOR label.",
      )
    }
    let value = self.head(3)
    fields[label] = match Label::from_json_name(label) {
      None if is_content_format_label(label) => self.field(value, index, label)
      None => {
        self.skip(value, 3)
        Json::null()
      }
      Some(DataValue) => {
        if value.major != 2 {
          reject(
            WrongType,
            Some(index),
            Some(label),
            "Expected a CBOR byte string.",
          )
        }
        if value.info == 31 {
          reject(
            UnsupportedCborType,
            Some(index),
            Some(label),
            "SenML data values must have definite length.",
          )
        }
        if value.argument > (self.input.length() - self.offset).to_uint64() {
          reject(
            InvalidCbor,
            None,
            None,
            "CBOR length exceeds remaining input.",
          )
        }
        if value.argument > self.limits.max_string_code_units.to_uint64() {
          reject(
            StringLimit,
            Some(index),
            Some(label),
            "Binary data exceeds the configured byte limit.",
          )
        }
        data = Some(self.take(value.argument).to_owned())
        Json::null()
      }
      Some(BaseVersion) => {
        if value.major != 0 {
          reject(
            WrongType,
            Some(index),
            Some(label),
            "CBOR base version must be an unsigned integer.",
          )
        }
        self.number(value, 3, index, label)
      }
      Some(_) => self.field(value, index, label)
    }
    members += 1
  }
  parse_record(fields, index, self.limits, data?)
}
