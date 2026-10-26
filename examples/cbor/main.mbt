///|
fn main raise {
  let args = @env.args()
  let mut hex_input : String? = None
  for i in 0..<args.length() {
    if args[i] == "--hex" {
      guard args.get(i + 1) is Some(value) else {
        fail("--hex requires a CBOR hexadecimal payload.")
      }
      hex_input = Some(value)
    }
  }
  let raw = match hex_input {
    Some(text) => @senweave.parse_cbor(@hex.decode(text))
    None =>
      @senweave.parse_json(
        (
          #|[{"bn":"sensor:","bt":1793000000,"bu":"Cel","bv":20,"bs":100,"bver":10},
          #| {"n":"temperature","v":2.5,"s":3,"t":-30,"ut":15},
          #| {"n":"flag","vb":false,"u":"/"},
          #| {"n":"blob","vd":"AP8","u":"/","t":-10},
          #| {"n":"label","vs":"门\n🚪","u":"","t":-20},
          #| {"n":"counter","bv":0,"v":9007199254740993}]
        ),
      )
  }
  let resolved = raw.resolve(reference_time=1793000000.0)
  let report = Json::object({
    "raw_cbor_hex": Json::string(@hex.encode(raw.to_cbor_bytes())),
    "resolved_cbor_hex": Json::string(@hex.encode(resolved.to_cbor_bytes())),
    "resolved": @json.parse(
      resolved.to_json_string(),
      preserve_number_repr=true,
    ),
  })
  println(report.stringify())
}
