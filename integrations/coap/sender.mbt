///|
/// Fixed failures never copy a peer, payload or upstream error message.
pub(all) enum SenderFailure {
  InvalidConfig
  InvalidRequest
  InvalidPayload(@senweave.Diagnostic)
  Busy
  Clock
  Capacity
  TimedOut
  ResetByPeer
  Protocol
} derive(Debug)

///|
pub extend SenderFailure with Debug::{to_repr}

///|
pub(all) enum SenderEvent {
  Transmit(Bytes)
  Acknowledged(Int32)
  Received(Int32, Int32, Bytes)
  Failed(Int32, SenderFailure)
  Cancelled(Int32)
  Rejected(SenderFailure)
  IgnoredDatagram
}

///|
/// One active SenML upload to one opaque peer key, without sockets or clocks.
/// Keep the instance alive to acknowledge retransmitted separate responses.
pub struct Sender {
  priv endpoint : @protocol.Endpoint
  priv peer : String
  priv mut pending : Int32?
  priv mut acknowledged : Bool
}

///|
fn sender_limits() -> @protocol.Limits {
  { ..@protocol.Limits::default(), max_datagram: 9000, max_payload: 8192, }
}

///|
/// Hosts supply a fresh nonnegative token seed and retry randomness. Default
/// CoAP retry timing is retained; a shorter response deadline may abort early.
pub fn Sender::new(
  peer : String,
  token_seed : Int64,
  initial_mid~ : Int32 = 0,
  response_timeout_ms~ : Int64 = 10000L,
) -> Result[Sender, SenderFailure] {
  if peer.is_empty() ||
    peer.length() > 256 ||
    peer.iter().any(c => c.to_int() < 32 || c.to_int() == 127) ||
    token_seed < 0L ||
    token_seed == 9223372036854775807L ||
    response_timeout_ms < 2000L ||
    response_timeout_ms > 247000L {
    return Err(InvalidConfig)
  }
  let config = {
    ..@protocol.Config::default(),
    limits: sender_limits(),
    initial_mid,
    token_seed,
    response_timeout_ms,
    max_peers: 1,
    max_exchanges: 1,
    max_queue: 0,
    max_dedup: 64,
    max_mid_leases: 128,
    max_actions: 128,
  }
  match @protocol.Endpoint::new(config) {
    Err(_) => Err(InvalidConfig)
    Ok(endpoint) => Ok({ endpoint, peer, pending: None, acknowledged: false, })
  }
}

///|
fn sender_failure(error : @protocol.Failure) -> SenderFailure {
  match error {
    @protocol.Clock(_) => Clock
    @protocol.Capacity(_) => Capacity
    @protocol.TimedOut => TimedOut
    @protocol.ResetByPeer => ResetByPeer
    _ => Protocol
  }
}

///|
fn Sender::drain(self : Sender, events : Array[SenderEvent]) -> Unit {
  for action in self.endpoint.drain() {
    match action {
      @protocol.SendDatagram(_, wire) => events.push(Transmit(wire))
      @protocol.ResponseReceived(id, message) => {
        self.pending = None
        events.push(Received(id, message.code.value, message.payload))
      }
      @protocol.Failed(id, error) => {
        self.pending = None
        events.push(Failed(id, sender_failure(error)))
      }
      @protocol.Cancelled(id) => {
        self.pending = None
        events.push(Cancelled(id))
      }
      _ => ()
    }
  }
  if !self.acknowledged &&
    self.pending is Some(id) &&
    self.endpoint
    .exchanges()
    .any(exchange => {
      exchange.id == id && exchange.phase == @protocol.WaitingResponse
    }) {
    self.acknowledged = true
    events.push(Acknowledged(id))
  }
}

///|
fn Sender::advance(
  self : Sender,
  now : Int64,
  events : Array[SenderEvent],
) -> Bool {
  match self.endpoint.poll(now) {
    Err(error) => {
      events.push(Rejected(sender_failure(error)))
      false
    }
    Ok(_) => {
      self.drain(events)
      true
    }
  }
}

///|
/// Validate raw SenML and preserve its exact bytes across protocol retries.
/// Relative times are resolved by the receiver, not by this sender. Unknown
/// optional extensions are rejected by this bounded upload profile.
pub fn Sender::send(
  self : Sender,
  payload : Bytes,
  format : @senweave.Format,
  now : Int64,
  random_sample : Int32,
  business_key? : BusinessKey,
) -> Array[SenderEvent] {
  let events = []
  if !self.advance(now, events) {
    return events
  }
  if self.pending is Some(_) {
    events.push(Rejected(Busy))
    return events
  }
  if random_sample < 0 || random_sample > 1000000 {
    events.push(Rejected(InvalidRequest))
    return events
  }
  ignore(
    @senweave.parse_payload(
      payload,
      format,
      max_input_bytes=8192,
      reject_extensions=true,
    ),
  ) catch {
    error => {
      events.push(Rejected(InvalidPayload(error.diagnostic())))
      return events
    }
  }
  let options = [
    @protocol.option_text(11, "ingest"),
    @protocol.option_uint(12, format.coap_content_format().to_int64()).unwrap(),
  ]
  if business_key is Some(identity) {
    if !identifier_valid(identity.source) || !identifier_valid(identity.key) {
      events.push(Rejected(InvalidRequest))
      return events
    }
    options.push(@protocol.option_text(15, "source=\{identity.source}"))
    options.push(@protocol.option_text(15, "key=\{identity.key}"))
  }
  let request : @protocol.Request = {
    verb: @protocol.Post,
    options,
    payload,
    confirmable: true,
  }
  match self.endpoint.request(self.peer, request, now, random_sample) {
    Err(error) => events.push(Rejected(sender_failure(error)))
    Ok(id) => {
      self.pending = Some(id)
      self.acknowledged = false
    }
  }
  self.drain(events)
  events
}

///|
/// Foreign peers and malformed datagrams cannot complete or replace an upload.
pub fn Sender::receive(
  self : Sender,
  peer : String,
  wire : Bytes,
  now : Int64,
) -> Array[SenderEvent] {
  let events = []
  if !self.advance(now, events) {
    return events
  }
  if peer != self.peer {
    events.push(IgnoredDatagram)
    return events
  }
  match self.endpoint.receive_response(peer, wire, now) {
    Err(@protocol.Capacity(_)) => events.push(Rejected(Capacity))
    Err(_) => events.push(IgnoredDatagram)
    Ok(_) => ()
  }
  self.drain(events)
  events
}

///|
pub fn Sender::poll(self : Sender, now : Int64) -> Array[SenderEvent] {
  let events = []
  let _ = self.advance(now, events)
  events
}

///|
pub fn Sender::cancel(self : Sender, now : Int64) -> Array[SenderEvent] {
  let events = []
  // Cancel before polling: a due retry must not be emitted by cancellation.
  if self.pending is Some(id) {
    match self.endpoint.cancel(id, now) {
      Err(error) => events.push(SenderEvent::Rejected(sender_failure(error)))
      Ok(_) => ()
    }
  } else {
    let _ = self.advance(now, events)
  }
  self.drain(events)
  events
}

///|
pub fn Sender::is_pending(self : Sender) -> Bool {
  self.pending is Some(_)
}

///|
/// The host should poll at this absolute monotonic millisecond deadline.
pub fn Sender::next_deadline(self : Sender) -> Int64? {
  self.endpoint.next_deadline()
}
