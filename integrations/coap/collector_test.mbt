///|
fn request(
  payload : Bytes,
  mid~ : Int32 = 10,
  format~ : Int32 = 110,
  path~ : String = "ingest",
  verb~ : @protocol.Method = @protocol.Post,
) -> Bytes {
  let message = @protocol.Message::new(
    @protocol.Confirmable,
    @protocol.Code::request(verb),
    mid,
  )
  message.token = b"\x01"
  message.options = [@protocol.option_text(11, path)]
  if format >= 0 {
    message.options.push(@protocol.option_uint(12, format.to_int64()).unwrap())
  }
  message.payload = payload
  @protocol.encode(message, {
    ..@protocol.Limits::default(),
    max_payload: 9000,
    max_datagram: 10000,
  }).unwrap()
}

///|
fn accepted(events : Array[@coap.Event]) -> @senweave.ResolvedPack? {
  for event in events {
    if event is @coap.Accepted(_, pack) {
      return Some(pack)
    }
  }
  None
}

///|
fn response(events : Array[@coap.Event]) -> @protocol.Message? {
  for event in events {
    if event is @coap.SendDatagram(_, wire) {
      return Some(@protocol.decode(wire, @protocol.Limits::default()).unwrap())
    }
  }
  None
}

///|
test "collector accepts JSON at reception time and replies with matching ACK identity" {
  let collector = @coap.Collector::new()
  let events = collector.receive(
    "peer-a",
    request(
      b"[{\"bn\":\"sensor:\",\"bv\":20},{\"n\":\"t\",\"v\":2.5,\"t\":-3}]",
    ),
    100L,
    1793000000.0,
  )
  let pack = accepted(events).unwrap()
  assert_eq(pack.record(0).unwrap().name, "sensor:t")
  assert_eq(pack.record(0).unwrap().time.as_double(), 1792999997.0)
  let reply = response(events).unwrap()
  assert_eq(reply.code.value, 68)
  assert_eq(reply.msg_type, @protocol.Acknowledgement)
  assert_eq(reply.mid, 10)
  assert_eq(reply.token, b"\x01")
}

///|
test "CBOR payload retains binary data without JSON-host conversion" {
  let collector = @coap.Collector::new()
  let raw = @senweave.parse_json(
    "[{\"n\":\"blob\",\"vd\":\"----____\",\"t\":1793000000}]",
  )
  let events = collector.receive(
    "peer-a",
    request(raw.to_cbor_bytes(), format=112),
    0L,
    1793000000.0,
  )
  assert_eq(
    accepted(events).unwrap().to_json_string(),
    raw.resolve().to_json_string(),
  )
}

///|
test "duplicate requests replay the cached ACK and never accept a second measurement" {
  let collector = @coap.Collector::new()
  let wire = request(b"[{\"n\":\"x\",\"v\":1}]")
  let first = collector.receive("peer-a", wire, 1L, 1793000000.0)
  let second = collector.receive("peer-a", wire, 2L, 1793000100.0)
  assert_eq(accepted(first) is Some(_), true)
  assert_eq(accepted(second) is None, true)
  assert_eq(response(second).unwrap(), response(first).unwrap())
  let other = collector.receive("peer-b", wire, 3L, 1793000200.0)
  assert_eq(accepted(other) is Some(_), true)
}

///|
test "payload errors are redacted and optional extensions are strict by default" {
  let collector = @coap.Collector::new()
  let bad = collector.receive(
    "p",
    request(b"private-sensor-value"),
    0L,
    1793000000.0,
  )
  assert_eq(accepted(bad) is None, true)
  assert_eq(response(bad).unwrap().code.value, 128)
  assert_eq(response(bad).unwrap().payload, b"InvalidJson")
  let wire = request(b"[{\"n\":\"x\",\"v\":1,\"vendor\":true}]", mid=11)
  let strict = collector.receive("p", wire, 1L, 1793000000.0)
  assert_eq(accepted(strict) is None, true)
  assert_eq(response(strict).unwrap().payload, b"IgnoredExtensions")
  let permissive = @coap.Collector::new(reject_extensions=false)
  assert_eq(
    accepted(permissive.receive("p", wire, 0L, 1793000000.0)) is Some(_),
    true,
  )
}

///|
test "format route and method negotiation fail before ingestion" {
  for
    (wire, code) in [
      (request(b"[]", format=-1), 143),
      (request(b"[]", format=50), 143),
      (request(b"[]", path="other"), 132),
      (request(b"[]", verb=@protocol.Get), 133),
    ] {
    let events = @coap.Collector::new().receive("p", wire, 0L, 1793000000.0)
    assert_eq(accepted(events) is None, true)
    guard response(events) is Some(reply) else {
      fail("Missing reply for expected response code \{code}.")
    }
    assert_eq(reply.code.value, code)
  }
}

///|
test "invalid clocks do not consume requests and monotonic time cannot regress" {
  let collector = @coap.Collector::new()
  let wire = request(b"[{\"n\":\"x\",\"v\":1}]")
  let invalid = collector.receive("p", wire, 0L, 0.0)
  assert_eq(invalid[0] is @coap.InvalidClock, true)
  assert_eq(
    accepted(collector.receive("p", wire, 10L, 1793000000.0)) is Some(_),
    true,
  )
  let regressed = collector.receive(
    "p",
    request(b"[]", mid=11),
    9L,
    1793000000.0,
  )
  assert_eq(regressed[0] is @coap.InvalidClock, true)
}

///|
test "expired exchange identity may be reused without retaining old base context" {
  let collector = @coap.Collector::new()
  let first = request(b"[{\"bn\":\"a:\"},{\"n\":\"x\",\"v\":1}]")
  let _ = collector.receive("p", first, 0L, 1793000000.0)
  let _ = collector.poll(247001L)
  let second = collector.receive(
    "p",
    request(b"[{\"n\":\"x\",\"v\":1}]"),
    247002L,
    1793001000.0,
  )
  let record = accepted(second).unwrap().record(0).unwrap()
  assert_eq(record.name, "x")
  assert_eq(record.time.as_double(), 1793001000.0)
}

///|
test "oversized and malformed datagrams never produce accepted events" {
  let collector = @coap.Collector::new()
  let malformed = collector.receive("p", b"\x00", 0L, 1793000000.0)
  assert_eq(accepted(malformed) is None, true)
  let buffer = Buffer()
  for _ in 0..<8193 {
    buffer.write_byte(32)
  }
  let oversized = collector.receive(
    "p",
    request(buffer.to_bytes()),
    1L,
    1793000000.0,
  )
  assert_eq(accepted(oversized) is None, true)
}
