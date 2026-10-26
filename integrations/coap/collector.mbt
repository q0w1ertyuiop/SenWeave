///|
/// Events contain no socket or system clock. Accepted means validation passed;
/// the host owns storage and sending the returned datagrams.
pub(all) enum Event {
  SendDatagram(String, Bytes)
  Accepted(String, @senweave.ResolvedPack)
  Rejected(String, @senweave.Diagnostic)
  ProtocolError(String)
  InvalidClock
}

///|
/// A bounded POST /ingest collector using MoonCoAP's exchange/deduplication core.
pub struct Collector {
  priv endpoint : @protocol.Endpoint
  priv reject_extensions : Bool
}

///|
pub fn Collector::new(reject_extensions~ : Bool = true) -> Collector {
  let defaults = @protocol.Config::default()
  let limits = { ..defaults.limits, max_datagram: 9000, max_payload: 8192, }
  let config = {
    ..defaults,
    limits,
    max_peers: 8,
    max_exchanges: 16,
    max_dedup: 64,
    max_mid_leases: 128,
    max_queue: 16,
    max_actions: 128,
  }
  { endpoint: @protocol.Endpoint::new(config).unwrap(), reject_extensions, }
}

///|
fn append_sends(
  events : Array[Event],
  actions : Array[@protocol.Action],
) -> Unit {
  for action in actions {
    if action is @protocol.SendDatagram(peer, wire) {
      events.push(SendDatagram(peer, wire))
    }
  }
}

///|
/// Provide monotonic milliseconds for CoAP lifetimes and a separate absolute
/// POSIX reception timestamp for relative SenML times. Never derive one clock
/// from the other. Each call drains protocol actions, even after a failure.
pub fn Collector::receive(
  self : Collector,
  peer : String,
  datagram : Bytes,
  monotonic_ms : Int64,
  received_at : Double,
) -> Array[Event] {
  if received_at.is_nan() || received_at.is_inf() || received_at < 268435456.0 {
    return [InvalidClock]
  }
  let events = []
  match self.endpoint.receive_request(peer, datagram, monotonic_ms) {
    Err(@protocol.Clock(_)) => events.push(InvalidClock)
    Err(_) => events.push(ProtocolError(peer))
    Ok(_) => ()
  }
  for action in self.endpoint.drain() {
    match action {
      @protocol.SendDatagram(peer, bytes) =>
        events.push(SendDatagram(peer, bytes))
      @protocol.RequestReceived(request) => {
        let message = request.message
        let response = if @protocol.request_path(message) != Ok("/ingest") {
          @protocol.Response::error(132)
        } else if message.code.verb() != Some(@protocol.Post) {
          @protocol.Response::error(133)
        } else if @protocol.request_queries(message) != Ok([]) {
          @protocol.Response::error(128)
        } else {
          match @protocol.message_uint(message, 12, -1L) {
            Ok(content_format) if content_format == 110L ||
              content_format == 112L => {
              let format = @senweave.Format::from_coap_content_format(
                content_format.to_int(),
              ).unwrap()
              try {
                let raw = @senweave.parse_payload(
                  message.payload,
                  format,
                  max_input_bytes=8192,
                  reject_extensions=self.reject_extensions,
                )
                let pack = raw.resolve(reference_time=received_at)
                let reply = @protocol.Response::{
                  code: { value: 68, },
                  options: [],
                  payload: b"",
                }
                if self.endpoint.respond(request.id, reply, monotonic_ms, 0)
                  is Ok(_) {
                  events.push(Accepted(peer, pack))
                } else {
                  events.push(ProtocolError(peer))
                }
                continue
              } catch {
                error => {
                  let diagnostic = error.diagnostic()
                  events.push(Rejected(peer, diagnostic))
                  @protocol.Response::{
                    code: { value: 128, },
                    options: [],
                    payload: @utf8.encode("\{Repr(diagnostic.code)}"),
                  }
                }
              }
            }
            _ => @protocol.Response::error(143)
          }
        }
        if self.endpoint.respond(request.id, response, monotonic_ms, 0)
          is Err(_) {
          events.push(ProtocolError(peer))
        }
      }
      _ => ()
    }
  }
  append_sends(events, self.endpoint.drain())
  events
}

///|
/// Expire deduplication records even when no new datagrams arrive.
pub fn Collector::poll(self : Collector, monotonic_ms : Int64) -> Array[Event] {
  let events = []
  match self.endpoint.poll(monotonic_ms) {
    Err(@protocol.Clock(_)) => events.push(InvalidClock)
    Err(_) => events.push(ProtocolError(""))
    Ok(_) => ()
  }
  append_sends(events, self.endpoint.drain())
  events
}
