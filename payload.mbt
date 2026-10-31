///|
/// Finite-pack representations supported by SenWeave.
pub(all) enum Format {
  SenmlJson
  SenmlCbor
  SenmlXml
} derive(Eq, Debug)

///|
pub extend Format with Eq::{equal, not_equal}

///|
pub extend Format with Debug::{to_repr}

///|
pub fn Format::content_type(self : Format) -> String {
  match self {
    SenmlJson => "application/senml+json"
    SenmlCbor => "application/senml+cbor"
    SenmlXml => "application/senml+xml"
  }
}

///|
pub fn Format::coap_content_format(self : Format) -> Int32 {
  match self {
    SenmlJson => 110
    SenmlCbor => 112
    SenmlXml => 310
  }
}

///|
/// Recognize the bounded ingress Content-Type profile. Names are ASCII case
/// insensitive; JSON and XML may have one charset=utf-8 parameter. Other parameters,
/// duplicate parameters and SenSML streams return None.
pub fn Format::from_content_type(content_type : String) -> Format? {
  if content_type.length() > 256 {
    return None
  }
  let parts = content_type
    .split(";")
    .map(part => part.to_owned().trim(chars=" \t").to_owned().to_lower())
    .to_array()
  if parts.length() == 1 {
    match parts[0] {
      "application/senml+json" => Some(SenmlJson)
      "application/senml+cbor" => Some(SenmlCbor)
      "application/senml+xml" => Some(SenmlXml)
      _ => None
    }
  } else if parts.length() == 2 &&
    (
      parts[0] == "application/senml+json" ||
      parts[0] == "application/senml+xml"
    ) {
    let parameter = parts[1]
      .split("=")
      .map(part => part.to_owned().trim(chars=" \t").to_owned())
      .to_array()
    if parameter is ["charset", "utf-8" | "\"utf-8\""] {
      if parts[0] == "application/senml+xml" {
        Some(SenmlXml)
      } else {
        Some(SenmlJson)
      }
    } else {
      None
    }
  } else {
    None
  }
}

///|
/// RFC 8428 Table 8. SenSML (111/113) is a separate streaming format.
pub fn Format::from_coap_content_format(value : Int32) -> Format? {
  match value {
    110 => Some(SenmlJson)
    112 => Some(SenmlCbor)
    310 => Some(SenmlXml)
    _ => None
  }
}

///|
/// Decode transport bytes with strict UTF-8 for JSON/XML and admission limits
/// before decoding. XML accepts a leading BOM; JSON syntax rejects it.
/// Call resolve() with the host's reception time before extracting records.
pub fn parse_payload(
  input : Bytes,
  format : Format,
  limits~ : ParseLimits = ParseLimits::default(),
  max_input_bytes~ : Int32 = 1_048_576,
  reject_extensions~ : Bool = false,
) -> Pack raise SenmlError {
  limits.validate()
  if max_input_bytes <= 0 {
    reject(InvalidLimits, None, None, "Payload byte limit must be positive.")
  }
  if input.length() > max_input_bytes {
    reject(InputLimit, None, None, "Payload exceeds the configured byte limit.")
  }
  let pack = match format {
    SenmlJson | SenmlXml => {
      let text = @utf8.decode(input, ignore_bom=false) catch {
        _ => {
          reject(InvalidUtf8, None, None, "Payload is not valid UTF-8.")
          ""
        }
      }
      if format == SenmlXml {
        parse_xml(text, limits~)
      } else {
        parse_json(text, limits~)
      }
    }
    SenmlCbor => parse_cbor(input, limits~, max_input_bytes~)
  }
  if reject_extensions && pack.ignored_extension_count() > 0 {
    reject(
      IgnoredExtensions,
      None,
      None,
      "Optional extensions are rejected by the ingress policy.",
    )
  }
  pack
}
