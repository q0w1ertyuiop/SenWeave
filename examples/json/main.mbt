///|
fn main raise {
  let pack = @senweave.parse_json(
    (
      #|[{"bn":"urn:dev:mac:001122334455:","bu":"Cel"},
      #| {"n":"temperature","v":22.50,"t":-30},
      #| {"n":"door","vb":false},
      #| {"n":"identity","vd":"AQID"}]
    ),
  )
  println(
    "raw records: \{pack.len()}, measurements: \{pack.measurement_count()}",
  )
  for index in 0..<pack.len() {
    let record = pack.record(index).unwrap()
    if record.value is Some(@senweave.Numeric(number)) {
      println("record \{index}: exact JSON number \{number.json_literal()}")
    }
  }
  try
    @senweave.parse_json("[{\"n\":\"temperature\",\"v\":1,\"vendor_\":true}]")
  catch {
    error => {
      let diagnostic = error.diagnostic()
      println(
        "rejected extension at record \{diagnostic.record_index.unwrap()}: \{diagnostic.field.unwrap()}",
      )
    }
  } noraise {
    _ => fail("A mandatory unknown extension must be rejected.")
  }
}
