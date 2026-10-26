///|
pub struct SenderSession {
  priv sender : @collector.Sender?
}

///|
pub fn new_sender(
  initial_mid : Int32,
  token_seed_hex : String,
  timeout_ms : Double,
) -> SenderSession {
  if !monotonic_valid(timeout_ms) || token_seed_hex.length() > 16 {
    return { sender: None, }
  }
  let seed = @string.parse_int64(token_seed_hex, base=16) catch {
    _ => return { sender: None, }
  }
  match
    @collector.Sender::new(
      "collector",
      seed,
      initial_mid~,
      response_timeout_ms=timeout_ms.to_int64(),
    ) {
    Ok(sender) => { sender: Some(sender), }
    Err(_) => { sender: None, }
  }
}

///|
fn sender_failure_code(failure : @collector.SenderFailure) -> String {
  match failure {
    @collector.InvalidConfig => "InvalidConfig"
    @collector.InvalidRequest => "InvalidRequest"
    @collector.InvalidPayload(_) => "InvalidPayload"
    @collector.Busy => "Busy"
    @collector.Clock => "InvalidClock"
    @collector.Capacity => "Capacity"
    @collector.TimedOut => "TimedOut"
    @collector.ResetByPeer => "ResetByPeer"
    @collector.Protocol => "Protocol"
  }
}

///|
fn sender_events_json(events : Array[@collector.SenderEvent]) -> String {
  Json::array(
    events.map(event => {
      match event {
        @collector.Transmit(bytes) =>
          Json::object({
            "kind": Json::string("send"),
            "hex": Json::string(@hex.encode(bytes)),
          })
        @collector.Acknowledged(_) =>
          Json::object({ "kind": Json::string("acknowledged") })
        @collector.Received(_, code, _) =>
          Json::object({
            "kind": Json::string("received"),
            "code": Json::number(code.to_double()),
          })
        @collector.Failed(_, reason) | @collector.Rejected(reason) =>
          Json::object({
            "kind": Json::string("failed"),
            "code": Json::string(sender_failure_code(reason)),
          })
        @collector.Cancelled(_) =>
          Json::object({ "kind": Json::string("cancelled") })
        @collector.IgnoredDatagram =>
          Json::object({ "kind": Json::string("ignored") })
      }
    }),
  ).stringify()
}

///|
pub fn sender_start(
  session : SenderSession,
  payload_hex : String,
  format : Int32,
  source : String,
  key : String,
  now : Double,
  random_sample : Int32,
) -> String {
  guard session.sender is Some(sender) else {
    return sender_events_json([@collector.Rejected(@collector.InvalidConfig)])
  }
  if !monotonic_valid(now) ||
    payload_hex.length() > 16384 ||
    source.length() > 64 ||
    key.length() > 64 {
    return sender_events_json([@collector.Rejected(@collector.InvalidRequest)])
  }
  guard @senweave.Format::from_coap_content_format(format) is Some(format) else {
    return sender_events_json([@collector.Rejected(@collector.InvalidRequest)])
  }
  let payload = @hex.decode(payload_hex) catch {
    _ =>
      return sender_events_json([@collector.Rejected(@collector.InvalidRequest)])
  }
  let queries = if source == "" && key == "" {
    []
  } else {
    ["source=\{source}", "key=\{key}"]
  }
  let identity = match @collector.BusinessKey::from_queries(queries) {
    Err(_) =>
      return sender_events_json([@collector.Rejected(@collector.InvalidRequest)])
    Ok(value) => value
  }
  sender_events_json(
    sender.send(
      payload,
      format,
      now.to_int64(),
      random_sample,
      business_key?=identity,
    ),
  )
}

///|
pub fn sender_receive(
  session : SenderSession,
  wire_hex : String,
  now : Double,
) -> String {
  guard session.sender is Some(sender) else { return "[]" }
  if !monotonic_valid(now) || wire_hex.length() > 18000 {
    return "[]"
  }
  let wire = @hex.decode(wire_hex) catch { _ => return "[]" }
  sender_events_json(sender.receive("collector", wire, now.to_int64()))
}

///|
pub fn sender_poll(session : SenderSession, now : Double) -> String {
  guard session.sender is Some(sender) else { return "[]" }
  if !monotonic_valid(now) {
    return "[]"
  }
  sender_events_json(sender.poll(now.to_int64()))
}

///|
pub fn sender_cancel(session : SenderSession, now : Double) -> String {
  guard session.sender is Some(sender) else { return "[]" }
  if !monotonic_valid(now) {
    return "[]"
  }
  sender_events_json(sender.cancel(now.to_int64()))
}

///|
pub fn sender_deadline(session : SenderSession) -> Double {
  match session.sender {
    Some(sender) =>
      match sender.next_deadline() {
        Some(deadline) => deadline.to_double()
        None => -1.0
      }
    None => -1.0
  }
}
