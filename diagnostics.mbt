///|
/// Stable categories for bounded version-10 parsing and measurement resolution.
pub(all) enum ErrorCode {
  InvalidLimits
  InputLimit
  NestingLimit
  RecordLimit
  FieldLimit
  StringLimit
  NumberLimit
  InvalidJson
  InvalidXml
  UnsupportedXmlFeature
  DuplicateKey
  InvalidRoot
  InvalidRecord
  WrongType
  InvalidNumber
  MissingValue
  ConflictingValues
  UnsupportedExtension
  UnsupportedVersion
  InvalidName
  InvalidData
  InvalidContentFormat
  MissingReferenceTime
  InvalidReferenceTime
  ArithmeticOverflow
  UnrepresentableTime
  ExpansionLimit
  InvalidCbor
  InvalidCborLabel
  UnsupportedCborType
  OutputLimit
  InvalidUtf8
  IgnoredExtensions
} derive(Eq, Debug)

///|
pub extend ErrorCode with Eq::{equal, not_equal}

///|
pub extend ErrorCode with Debug::{to_repr}

///|
/// A diagnostic contains locations and a fixed explanation, never a value dump.
/// Record indexes are zero-based. Line/column, when present, come from the JSON
/// parser. Only standard SenML field names are retained; extension names may
/// contain application metadata and are never copied into a diagnostic.
pub struct Diagnostic {
  code : ErrorCode
  record_index : Int32?
  field : String?
  line : Int32?
  column : Int32?
  message : String
} derive(Debug)

///|
pub extend Diagnostic with Debug::{to_repr}

///|
pub(all) suberror SenmlError {
  Invalid(Diagnostic)
} derive(Debug)

///|
pub extend SenmlError with Debug::{to_repr}

///|
pub fn SenmlError::diagnostic(self : SenmlError) -> Diagnostic {
  let Invalid(diagnostic) = self
  diagnostic
}

///|
fn reject(
  code : ErrorCode,
  record_index : Int32?,
  field : String?,
  message : String,
  line? : Int32,
  column? : Int32,
) -> Unit raise SenmlError {
  let safe_field = match field {
    Some(name) if is_understood_label(name) => Some(name)
    _ => None
  }
  raise Invalid({
    code,
    record_index,
    field: safe_field,
    line,
    column,
    message,
  })
}
