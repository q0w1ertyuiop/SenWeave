///|
/// Limits are admission policy, not additional SenML protocol fields.
/// Input/string lengths count UTF-16 code units. The depth limit also applies
/// to ignored extension values. Known numbers retain their original text.
pub(all) struct ParseLimits {
  max_input_code_units : Int32
  max_records : Int32
  max_depth : Int32
  max_fields_per_record : Int32
  max_string_code_units : Int32
  max_number_code_units : Int32
} derive(Debug)

///|
pub extend ParseLimits with Debug::{to_repr}

///|
pub fn ParseLimits::default() -> ParseLimits {
  {
    max_input_code_units: 1_048_576,
    max_records: 4096,
    max_depth: 32,
    max_fields_per_record: 64,
    max_string_code_units: 65_536,
    max_number_code_units: 128,
  }
}

///|
fn ParseLimits::validate(self : ParseLimits) -> Unit raise SenmlError {
  if self.max_input_code_units <= 0 ||
    self.max_records <= 0 ||
    self.max_fields_per_record <= 0 ||
    self.max_string_code_units <= 0 ||
    self.max_depth <= 0 ||
    self.max_depth > 128 ||
    self.max_number_code_units <= 0 ||
    self.max_number_code_units > 1024 {
    reject(
      InvalidLimits,
      None,
      None,
      "Limits must be positive; depth is at most 128 and number length at most 1024.",
    )
  }
}
