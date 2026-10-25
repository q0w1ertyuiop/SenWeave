///|
fn main {
  for name in ["bn", "bt", "bu", "n", "v", "t", "vd"] {
    if @senweave.Label::from_json_name(name) is Some(label) {
      println("\{label.json_name()} -> CBOR key \{label.cbor_key()}")
    }
  }
}
