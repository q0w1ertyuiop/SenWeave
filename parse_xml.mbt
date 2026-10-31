///|
fn senml_xml_namespace() -> String {
  "urn:ietf:params:xml:ns:senml"
}

///|
fn next_xml_event(
  reader : @xml.NamespaceReader,
) -> @xml.NamespaceEvent raise SenmlError {
  reader.read_event() catch {
    @xml.At(span~, ..) =>
      raise Invalid({
        code: InvalidXml,
        record_index: None,
        field: None,
        line: Some(span.start.line),
        column: Some(span.start.column),
        message: "Malformed XML document or namespace structure.",
      })
  }
}

///|
fn xml_attributes_limit(
  element : @xml.NamespaceElement,
  limits : ParseLimits,
  index : Int32?,
) -> Unit raise SenmlError {
  if element.attributes.length().to_int64() +
    element.namespace_declarations.length().to_int64() >
    limits.max_fields_per_record.to_int64() {
    reject(
      FieldLimit,
      index,
      None,
      "XML element exceeds the configured attribute limit.",
    )
  }
  for declaration in element.namespace_declarations {
    if declaration.prefix.unwrap_or("").length() > limits.max_string_code_units ||
      (
        declaration.namespace_uri != senml_xml_namespace() &&
        declaration.namespace_uri.length() > limits.max_string_code_units
      ) {
      reject(
        StringLimit,
        index,
        None,
        "XML namespace declaration exceeds the configured limit.",
      )
    }
  }
}

///|
fn xml_record(
  element : @xml.NamespaceElement,
  index : Int32,
  limits : ParseLimits,
) -> Record raise SenmlError {
  xml_attributes_limit(element, limits, Some(index))
  let fields : Map[String, Json] = Map([])
  for attribute in element.attributes {
    // Default namespaces never apply to unprefixed attribute names. A foreign
    // qualified attribute is an extension, even if its local name is "v".
    let label = attribute.name.qualified_name
    if label.length() > limits.max_string_code_units {
      reject(
        StringLimit,
        Some(index),
        None,
        "XML attribute name exceeds the configured limit.",
      )
    }
    let kind = if attribute.name.namespace_uri is None {
      Label::from_json_name(label)
    } else {
      None
    }
    let value = attribute.value
    fields[label] = match kind {
      Some(
        BaseVersion
        | BaseTime
        | BaseValue
        | BaseSum
        | NumericValue
        | Sum
        | Time
        | UpdateTime
      ) => xml_number(value, index, label, limits)
      Some(BooleanValue) =>
        match value.trim(chars=" \t\r\n").to_owned() {
          "true" | "1" => Json::boolean(true)
          "false" | "0" => Json::boolean(false)
          _ => {
            reject(
              WrongType,
              Some(index),
              Some("vb"),
              "Expected an XML boolean lexical value.",
            )
            Json::null()
          }
        }
      _ => {
        if value.length() > limits.max_string_code_units {
          reject(
            StringLimit,
            Some(index),
            Some(label),
            "XML attribute value exceeds the configured string limit.",
          )
        }
        Json::string(value)
      }
    }
  }
  parse_record(fields, index, limits)
}

///|
/// Parse finite SenML XML with a namespace-aware XML 1.0 pull reader.
/// All fifteen RFC 8428 attributes share the JSON/CBOR model and validation.
/// DTDs are rejected before records are read; external resources are never
/// fetched. XML declarations must specify version 1.0 and UTF-8 if present.
pub fn parse_xml(
  input : String,
  limits~ : ParseLimits = ParseLimits::default(),
) -> Pack raise SenmlError {
  limits.validate()
  if input.length() > limits.max_input_code_units {
    reject(
      InputLimit,
      None,
      None,
      "XML input exceeds the configured code-unit limit.",
    )
  }
  let reader = @xml.NamespaceReader::from_string(input)
  let records : Array[Record] = []
  let mut depth = 0
  let mut seen_root = false
  let mut closed_root = false
  while true {
    let event = next_xml_event(reader)
    match event.kind {
      @xml.Start(element) | @xml.Empty(element) => {
        let next_depth = depth + 1
        if next_depth > limits.max_depth {
          reject(
            NestingLimit,
            None,
            None,
            "XML nesting exceeds the configured limit.",
          )
        }
        if element.name.namespace_uri != Some(senml_xml_namespace()) {
          reject(
            InvalidXml,
            None,
            None,
            "Expected the RFC 8428 SenML XML namespace.",
          )
        }
        if depth == 0 {
          if seen_root ||
            closed_root ||
            element.name.local_name != "sensml" ||
            !element.attributes.is_empty() {
            reject(
              InvalidXml,
              None,
              None,
              "Expected a single sensml root with namespace declarations.",
            )
          }
          xml_attributes_limit(element, limits, None)
          seen_root = true
        } else if depth == 1 && element.name.local_name == "senml" {
          if records.length() >= limits.max_records {
            reject(
              RecordLimit,
              None,
              None,
              "XML pack exceeds the configured record limit.",
            )
          }
          records.push(xml_record(element, records.length(), limits))
        } else {
          reject(
            InvalidXml,
            None,
            None,
            "SenML XML records contain attributes, not nested elements.",
          )
        }
        if event.kind is @xml.Start(_) {
          depth = next_depth
        } else if depth == 0 {
          closed_root = true
        }
      }
      @xml.End(_) => {
        depth -= 1
        if depth == 0 {
          closed_root = true
        }
      }
      @xml.Text(text) | @xml.CData(text) =>
        if text.trim(chars=" \t\r\n").length() != 0 {
          reject(
            InvalidXml,
            None,
            None,
            "SenML XML records use attributes rather than text content.",
          )
        }
      @xml.Decl(version~, encoding~, ..) =>
        if version != "1.0" ||
          (encoding is Some(name) && name.to_lower() != "utf-8") {
          reject(
            UnsupportedXmlFeature,
            None,
            None,
            "SenML XML requires XML 1.0 and UTF-8.",
          )
        }
      @xml.DocType(_) =>
        reject(
          UnsupportedXmlFeature,
          None,
          None,
          "DTD declarations are outside the XML ingress policy.",
        )
      @xml.Comment(_) | @xml.PI(..) => ()
      @xml.Eof => break
    }
  }
  if !seen_root || !closed_root || depth != 0 {
    reject(InvalidXml, None, None, "Incomplete SenML XML document.")
  }
  validated_pack(records)
}
