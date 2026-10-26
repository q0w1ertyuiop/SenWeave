///|
fn main {

}

///|
pub fn new_collector() -> @collector.Collector {
  @collector.Collector::new()
}

///|
fn events_json(events : Array[@collector.Event]) -> String {
  Json::array(
    events.map(event => {
      match event {
        @collector.SendDatagram(peer, wire) =>
          Json::object({
            "kind": Json::string("send"),
            "peer": Json::string(peer),
            "hex": Json::string(@hex.encode(wire)),
          })
        @collector.Accepted(peer, pack) =>
          Json::object({
            "kind": Json::string("accepted"),
            "peer": Json::string(peer),
            "json": Json::string(pack.to_json_string()),
          })
        @collector.Rejected(peer, diagnostic) =>
          Json::object({
            "kind": Json::string("rejected"),
            "peer": Json::string(peer),
            "code": Json::string("\{Repr(diagnostic.code)}"),
          })
        @collector.ProtocolError(_) =>
          Json::object({ "kind": Json::string("protocol-error") })
        @collector.InvalidClock =>
          Json::object({ "kind": Json::string("invalid-clock") })
      }
    }),
  ).stringify()
}

///|
fn monotonic_valid(value : Double) -> Bool {
  !value.is_nan() &&
  !value.is_inf() &&
  value >= 0.0 &&
  value <= 9007199254740991.0 &&
  value.to_int64().to_double() == value
}

///|
pub fn receive(
  collector : @collector.Collector,
  peer : String,
  wire_hex : String,
  monotonic_ms : Double,
  received_at : Double,
) -> String {
  if !monotonic_valid(monotonic_ms) {
    return events_json([@collector.InvalidClock])
  }
  if wire_hex.length() > 18000 {
    return events_json([@collector.ProtocolError(peer)])
  }
  let wire = @hex.decode(wire_hex) catch {
    _ => return events_json([@collector.ProtocolError(peer)])
  }
  events_json(
    collector.receive(peer, wire, monotonic_ms.to_int64(), received_at),
  )
}

///|
pub fn poll(collector : @collector.Collector, monotonic_ms : Double) -> String {
  if !monotonic_valid(monotonic_ms) {
    return events_json([@collector.InvalidClock])
  }
  events_json(collector.poll(monotonic_ms.to_int64()))
}
