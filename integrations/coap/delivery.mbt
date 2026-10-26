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
  priv business_key : BusinessKey?
  priv payload : Bytes
  priv format : @senweave.Format
}

///|
pub fn Delivery::business_key(self : Delivery) -> BusinessKey? {
  self.business_key
}

///|
pub fn Delivery::payload(self : Delivery) -> Bytes {
  self.payload
}

///|
pub fn Delivery::format(self : Delivery) -> @senweave.Format {
  self.format
}

///|
/// Outcomes are reported by the host after its storage transaction.
pub(all) enum Completion {
  Stored
  AlreadyStored
  KeyConflict
  Failed
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
  self.complete(if stored { Stored } else { Failed }, monotonic_ms)
}

///|
/// AlreadyStored and KeyConflict require a business key. They respectively
/// schedule 2.04 and 4.09 without asking the library to write anything again.
pub fn Delivery::complete(
  self : Delivery,
  outcome : Completion,
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
  if self.business_key is None &&
    (outcome is AlreadyStored || outcome is KeyConflict) {
    events.push(InvalidDelivery(self.id))
    return events
  }
  let code = match outcome {
    Stored | AlreadyStored => 68
    KeyConflict => 137
    Failed => 160
  }
  let reply : @protocol.Response = {
    code: { value: code, },
    options: [],
    payload: b"",
  }
  match collector.endpoint.respond(self.id, reply, monotonic_ms, 0) {
    Err(_) => events.push(ProtocolError(pending.peer))
    Ok(_) => {
      collector.pending.remove(self.id)
      match outcome {
        Stored => events.push(Completed(self.id, pending.peer))
        AlreadyStored => events.push(Duplicate(self.id, pending.peer))
        KeyConflict => events.push(Conflict(self.id, pending.peer))
        Failed => events.push(StorageFailed(self.id, pending.peer))
      }
    }
  }
  append_sends(events, collector.endpoint.drain())
  events
}
