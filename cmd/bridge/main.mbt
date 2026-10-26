///|
fn main {

}

///|
/// Host entry point; all parsing, resolution and diagnostics live in MoonBit.
pub fn process_input(
  input : String,
  input_format : String,
  action : String,
  output_format : String,
  reference_time : String,
  name : String,
) -> String {
  @inspector.process_input(
    input, input_format, action, output_format, reference_time, name,
  )
}

///|
pub fn process_input_with_policy(
  input : String,
  input_format : String,
  action : String,
  output_format : String,
  reference_time : String,
  name : String,
  policy : String,
) -> String {
  @inspector.process_input_with_policy(
    input, input_format, action, output_format, reference_time, name, policy,
  )
}
