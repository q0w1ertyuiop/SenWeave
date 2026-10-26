///|
fn main raise {
  // A host supplies the reception time once, before archiving or forwarding.
  let received_at = 1793000000.0
  let raw = @senweave.parse_json(
    (
      #|[{"bn":"urn:dev:gateway:demo:","bu":"Cel","bv":20},
      #| {"n":"temperature","v":2.5,"t":-30},
      #| {"n":"door","vb":false,"u":"/"},
      #| {"n":"temperature","v":3,"t":-60}]
    ),
  )
  let resolved = raw.resolve(reference_time=received_at)
  let temperatures = resolved.filter(record => {
    record.name.has_suffix("temperature")
  })
  println(
    "gateway: \{raw.len()} raw records -> \{temperatures.len()} temperature measurements",
  )
  println(temperatures.to_json_string())
  for index in 0..<temperatures.len() {
    let record = temperatures.record(index).unwrap()
    let reparsed = @senweave.parse_json(record.to_json_string()).resolve()
    assert_eq(reparsed.len(), 1)
    assert_eq(reparsed.record(0).unwrap().name, record.name)
  }
  println(
    "independent reparse: 2/2 measurements, no base context or clock required",
  )
}
