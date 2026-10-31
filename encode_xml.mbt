///|
fn xml_output_attributes(record : Json) -> Array[(String, String)] {
  guard record is Json::Object(fields) else { return [] }
  let attributes = []
  for
    label in [
      "bn", "bt", "bu", "bv", "bs", "bver", "n", "u", "v", "vs", "vb", "vd", "s",
      "t", "ut",
    ] {
    if fields.get(label) is Some(value) {
      let text = match value {
        Json::String(text) => text
        Json::Number(number, repr~) =>
          if label == "bver" {
            "10"
          } else {
            repr.unwrap_or_else(() => Json::number(number).stringify())
          }
        Json::True => "true"
        Json::False => "false"
        _ => ""
      }
      attributes.push((label, text))
    }
  }
  attributes
}

///|
fn encode_xml_records(
  records : Iter[Json],
  max_output_code_units : Int32,
) -> String raise SenmlError {
  if max_output_code_units <= 0 {
    reject(InvalidLimits, None, None, "XML output limit must be positive.")
  }
  // Six characters cover every escaped UTF-16 unit, including attribute
  // newlines/tabs. Check before asking Writer to allocate serialized output.
  let mut size = "<sensml xmlns=\"urn:ietf:params:xml:ns:senml\"></sensml>"
    .length()
    .to_int64()
  let rows = []
  for record in records {
    let attributes = xml_output_attributes(record)
    size += 8L
    for (label, value) in attributes {
      size += label.length().to_int64() + 4L + 6L * value.length().to_int64()
    }
    if size > max_output_code_units.to_int64() {
      reject(
        OutputLimit,
        None,
        None,
        "XML output exceeds the conservative code-unit limit.",
      )
    }
    rows.push(attributes)
  }
  if size > max_output_code_units.to_int64() {
    reject(
      OutputLimit,
      None,
      None,
      "XML output exceeds the conservative code-unit limit.",
    )
  }
  try {
    let writer = @xml.Writer::new()
    writer.start_element("sensml", [("xmlns", senml_xml_namespace())])
    for attributes in rows {
      writer.empty_element("senml", attributes)
    }
    writer.end_element("sensml")
    writer.to_string()
  } catch {
    _ => {
      reject(
        InvalidXml,
        None,
        None,
        "A value contains characters that XML 1.0 cannot represent.",
      )
      ""
    }
  }
}

///|
/// Encode a raw pack, retaining bases, explicit resets and original order.
/// XML 1.0 cannot represent every JSON string; invalid characters raise an
/// error. Attribute whitespace is escaped to survive XML normalization.
pub fn Pack::to_xml_string(
  self : Pack,
  max_output_code_units~ : Int32 = 4_194_304,
) -> String raise SenmlError {
  encode_xml_records(
    self.records.iter().map(record => record.to_json()),
    max_output_code_units,
  )
}

///|
/// Encode chronologically ordered independent XML measurements.
pub fn ResolvedPack::to_xml_string(
  self : ResolvedPack,
  max_output_code_units~ : Int32 = 4_194_304,
) -> String raise SenmlError {
  encode_xml_records(
    self.records.iter().map(record => record.to_json()),
    max_output_code_units,
  )
}

///|
/// Encode a single independent measurement in a complete sensml document.
pub fn ResolvedRecord::to_xml_string(
  self : ResolvedRecord,
  max_output_code_units~ : Int32 = 4_194_304,
) -> String raise SenmlError {
  encode_xml_records([self.to_json()].iter(), max_output_code_units)
}
