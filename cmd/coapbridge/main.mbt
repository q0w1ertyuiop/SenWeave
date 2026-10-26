///|
fn main {

}

///|
pub struct Session {
  priv collector : @collector.Collector
  priv deliveries : Map[Int32, @collector.Delivery]
}

///|
pub fn new_collector() -> Session {
  { collector: @collector.Collector::new(), deliveries: Map([]), }
}

///|
pub fn new_deferred_collector() -> Session {
  {
    collector: @collector.Collector::new(deferred=true, idempotency=true),
    deliveries: Map([]),
  }
}

///|
fn events_json(session : Session, events : Array[@collector.Event]) -> String {
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
        @collector.Pending(delivery, peer, pack) => {
          session.deliveries[delivery.id()] = delivery
          let source = match delivery.business_key() {
            Some(value) => Json::string(value.source)
            None => Json::null()
          }
          let key = match delivery.business_key() {
            Some(value) => Json::string(value.key)
            None => Json::null()
          }
          Json::object({
            "kind": Json::string("pending"),
            "id": Json::number(delivery.id().to_double()),
            "peer": Json::string(peer),
            "json": Json::string(pack.to_json_string()),
            "source": source,
            "key": key,
            "format": Json::number(
              delivery.format().coap_content_format().to_double(),
            ),
            "payloadhex": Json::string(@hex.encode(delivery.payload())),
          })
        }
        @collector.Completed(id, peer)
        | @collector.Duplicate(id, peer)
        | @collector.Conflict(id, peer)
        | @collector.StorageFailed(id, peer)
        | @collector.Expired(id, peer) => {
          session.deliveries.remove(id)
          let kind = match event {
            @collector.Completed(_, _) => "completed"
            @collector.Duplicate(_, _) => "duplicate"
            @collector.Conflict(_, _) => "conflict"
            @collector.StorageFailed(_, _) => "storage-failed"
            _ => "expired"
          }
          Json::object({
            "kind": Json::string(kind),
            "id": Json::number(id.to_double()),
            "peer": Json::string(peer),
          })
        }
        @collector.Busy(peer) =>
          Json::object({
            "kind": Json::string("busy"),
            "peer": Json::string(peer),
          })
        @collector.InvalidDelivery(id) =>
          Json::object({
            "kind": Json::string("invalid-delivery"),
            "id": Json::number(id.to_double()),
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
  session : Session,
  peer : String,
  wire_hex : String,
  monotonic_ms : Double,
  received_at : Double,
) -> String {
  if !monotonic_valid(monotonic_ms) {
    return events_json(session, [@collector.InvalidClock])
  }
  if wire_hex.length() > 18000 {
    return events_json(session, [@collector.ProtocolError(peer)])
  }
  let wire = @hex.decode(wire_hex) catch {
    _ => return events_json(session, [@collector.ProtocolError(peer)])
  }
  events_json(
    session,
    session.collector.receive(peer, wire, monotonic_ms.to_int64(), received_at),
  )
}

///|
pub fn poll(session : Session, monotonic_ms : Double) -> String {
  if !monotonic_valid(monotonic_ms) {
    return events_json(session, [@collector.InvalidClock])
  }
  events_json(session, session.collector.poll(monotonic_ms.to_int64()))
}

///|
pub fn finish(
  session : Session,
  id : Int32,
  stored : Bool,
  monotonic_ms : Double,
) -> String {
  if !monotonic_valid(monotonic_ms) {
    return events_json(session, [@collector.InvalidClock])
  }
  match session.deliveries.get(id) {
    Some(delivery) =>
      events_json(session, delivery.finish(stored~, monotonic_ms.to_int64()))
    None => events_json(session, [@collector.InvalidDelivery(id)])
  }
}

///|
pub fn complete(
  session : Session,
  id : Int32,
  outcome : String,
  monotonic_ms : Double,
) -> String {
  if !monotonic_valid(monotonic_ms) {
    return events_json(session, [@collector.InvalidClock])
  }
  let completion = match outcome {
    "stored" => @collector.Stored
    "duplicate" => @collector.AlreadyStored
    "conflict" => @collector.KeyConflict
    "failed" => @collector.Failed
    _ => return events_json(session, [@collector.InvalidDelivery(id)])
  }
  match session.deliveries.get(id) {
    Some(delivery) =>
      events_json(
        session,
        delivery.complete(completion, monotonic_ms.to_int64()),
      )
    None => events_json(session, [@collector.InvalidDelivery(id)])
  }
}
