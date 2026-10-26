///|
priv struct PendingRequest {
  peer : String
  deadline : Int64
}

///|
/// Opaque capability bound to the collector that admitted the measurement.
/// Finish only after the host's storage operation has returned its result.
pub struct Delivery {
  priv collector : Collector
  priv id : Int32
}

///|
/// A process-local correlation ID, never a persistent business identity.
pub fn Delivery::id(self : Delivery) -> Int32 {
  self.id
}

///|
pub fn Collector::pending_count(self : Collector) -> Int32 {
  self.pending.length()
}

///|
fn Collector::advance(
  self : Collector,
  monotonic_ms : Int64,
  events : Array[Event],
) -> Bool {
  match self.endpoint.poll(monotonic_ms) {
    Err(@protocol.Clock(_)) => {
      events.push(InvalidClock)
      return false
    }
    Err(_) => {
      events.push(ProtocolError(""))
      append_sends(events, self.endpoint.drain())
      return false
    }
    Ok(_) => ()
  }
  append_sends(events, self.endpoint.drain())
  for (id, pending) in self.pending.to_array() {
    if monotonic_ms >= pending.deadline {
      // A late poll may have already expired the protocol exchange. In either
      // case the host capability expires and cannot produce a success reply.
      let _ = self.endpoint.respond(
        id,
        @protocol.Response::error(163),
        monotonic_ms,
        0,
      )
      self.pending.remove(id)
      append_sends(events, self.endpoint.drain())
      events.push(Expired(id, pending.peer))
    }
  }
  true
}

///|
/// stored=true schedules 2.04 only after the host has committed. stored=false
/// schedules 5.00. Both consume the capability; clock failure leaves it live.
/// Expiration, double finish and stale capabilities never generate success.
pub fn Delivery::finish(
  self : Delivery,
  stored~ : Bool,
  monotonic_ms : Int64,
) -> Array[Event] {
  let collector = self.collector
  let events = []
  if !collector.advance(monotonic_ms, events) {
    return events
  }
  let pending = match collector.pending.get(self.id) {
    None => {
      events.push(InvalidDelivery(self.id))
      return events
    }
    Some(pending) => pending
  }
  let code = if stored { 68 } else { 160 }
  let reply : @protocol.Response = {
    code: { value: code, },
    options: [],
    payload: b"",
  }
  match collector.endpoint.respond(self.id, reply, monotonic_ms, 0) {
    Err(_) => events.push(ProtocolError(pending.peer))
    Ok(_) => {
      collector.pending.remove(self.id)
      if stored {
        events.push(Completed(self.id, pending.peer))
      } else {
        events.push(StorageFailed(self.id, pending.peer))
      }
    }
  }
  append_sends(events, collector.endpoint.drain())
  events
}
