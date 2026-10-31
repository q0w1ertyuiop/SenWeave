///|
/// A validated number represented by JSON text. JSON input retains its source
/// spelling; CBOR input generates integer, floating-point or decimal-tag text.
/// The Double projection can round; use json_literal() when exact source text
/// matters. This type does not provide decimal arithmetic.
pub struct Number {
  priv approximate : Double
  priv literal : String
} derive(Debug)

///|
pub extend Number with Debug::{to_repr}

///|
/// Return the binary64 approximation; this can round the exact source number.
pub fn Number::as_double(self : Number) -> Double {
  self.approximate
}

///|
/// Return the validated JSON number text, including its sign and exponent.
pub fn Number::json_literal(self : Number) -> String {
  self.literal
}

///|
pub(all) enum MeasurementValue {
  Numeric(Number)
  Text(String)
  Boolean(Bool)
  Data(Bytes)
} derive(Debug)

///|
pub extend MeasurementValue with Debug::{to_repr}

///|
/// A validated raw JSON/CBOR/XML record. Bases have not been applied.
/// A base-only record updates pack context and is not a measurement.
/// Unknown, non-mandatory extensions are ignored rather than retained.
pub struct Record {
  base_name : String?
  base_time : Number?
  base_unit : String?
  base_value : Number?
  base_sum : Number?
  base_version : Number?
  base_content_format : ContentFormatSpec?
  name : String?
  unit : String?
  value : MeasurementValue?
  sum : Number?
  time : Number?
  update_time : Number?
  content_format : ContentFormatSpec?
  ignored_extension_count : Int32
} derive(Debug)

///|
pub extend Record with Debug::{to_repr}

///|
pub fn Record::is_measurement(self : Record) -> Bool {
  self.value is Some(_) || self.sum is Some(_)
}

///|
/// The record container is private so consumers cannot reorder raw context.
pub struct Pack {
  priv records : Array[Record]
}

///|
/// Counts all raw records, including base-only context updates.
pub fn Pack::len(self : Pack) -> Int32 {
  self.records.length()
}

///|
pub fn Pack::record(self : Pack, index : Int32) -> Record? {
  self.records.get(index)
}

///|
pub fn Pack::measurement_count(self : Pack) -> Int32 {
  let mut count = 0
  for record in self.records {
    if record.is_measurement() {
      count += 1
    }
  }
  count
}

///|
/// Count optional fields discarded by the parser across the complete raw pack.
pub fn Pack::ignored_extension_count(self : Pack) -> Int32 {
  let mut count = 0
  for record in self.records {
    count += record.ignored_extension_count
  }
  count
}
