///|
fn transmitted(events : Array[@coap.SenderEvent]) -> Bytes {
  for event in events {
    if event is @coap.Transmit(wire) {
      return wire
    }
  }
  abort("Expected a datagram.")
}

///|
fn has_transmission(events : Array[@coap.SenderEvent]) -> Bool {
  events.any(event => event is @coap.Transmit(_))
}

///|
fn sender_reply(
  request : Bytes,
  code~ : Int32 = 68,
  separate~ : Bool = false,
) -> Bytes {
  let original = @protocol.decode(request, @protocol.Limits::default()).unwrap()
  let reply = @protocol.Message::new(
    if separate {
      @protocol.Confirmable
    } else {
      @protocol.Acknowledgement
    },
    { value: code, },
    if separate {
      99
    } else {
      original.mid
    },
  )
  reply.token = original.token
  @protocol.encode(reply, @protocol.Limits::default()).unwrap()
}

///|
test "sender validates configuration and raw SenML before emitting bytes" {
  for
    (peer, seed, timeout) in [
      ("", 1L, 10000L),
      ("p\n", 1L, 10000L),
      ("p", -1L, 10000L),
      ("p", 9223372036854775807L, 10000L),
      ("p", 1L, 1999L),
      ("p", 1L, 247001L),
    ] {
    assert_eq(
      @coap.Sender::new(peer, seed, response_timeout_ms=timeout)
      is Err(@coap.InvalidConfig),
      true,
    )
  }
  let sender = @coap.Sender::new("p", 1L).unwrap()
  for payload in [b"\xff", b"[{\"n\":\"x\",\"v\":1,\"vendor\":true}]", b"[{}]"] {
    let events = sender.send(payload, @senweave.SenmlJson, 0L, 0)
    assert_eq(events[0] is @coap.Rejected(@coap.InvalidPayload(_)), true)
    assert_eq(has_transmission(events), false)
    assert_eq(sender.is_pending(), false)
  }
  assert_eq(
    sender.send(b"[]", @senweave.SenmlJson, 0L, -1)[0]
    is @coap.Rejected(@coap.InvalidRequest),
    true,
  )
}

///|
test "sender preserves JSON CBOR and application identity on POST ingest" {
  let key = @coap.BusinessKey::from_queries(["source=room-a", "key=one"])
    .unwrap()
    .unwrap()
  for
    (payload, format) in [
      (b"[{\"n\":\"x\",\"v\":9007199254740993,\"t\":-3}]", @senweave.SenmlJson),
      (b"\x81\xa2\x00\x61x\x02\x01", @senweave.SenmlCbor),
      (
        b"<sensml xmlns='urn:ietf:params:xml:ns:senml'><senml n='x' v='1'/></sensml>",
        @senweave.SenmlXml,
      ),
    ] {
    let sender = @coap.Sender::new("p", 123L, initial_mid=65535).unwrap()
    let wire = transmitted(
      sender.send(payload, format, 0L, 0, business_key=key),
    )
    let message = @protocol.decode(wire, @protocol.Limits::default()).unwrap()
    assert_eq(message.payload, payload)
    assert_eq(message.mid, 65535)
    assert_eq(message.token.length(), 8)
    assert_eq(message.code.verb(), Some(@protocol.Post))
    assert_eq(@protocol.request_path(message), Ok("/ingest"))
    assert_eq(
      @protocol.request_queries(message),
      Ok(["source=room-a", "key=one"]),
    )
    assert_eq(
      @protocol.message_uint(message, 12, -1L),
      Ok(format.coap_content_format().to_int64()),
    )
  }
}

///|
test "lost request retransmission retains byte identity and applies exponential backoff" {
  let sender = @coap.Sender::new("p", 1L).unwrap()
  let first = transmitted(sender.send(b"[]", @senweave.SenmlJson, 0L, 0))
  assert_eq(sender.next_deadline(), Some(2000L))
  assert_eq(has_transmission(sender.poll(1999L)), false)
  assert_eq(transmitted(sender.poll(2000L)), first)
  assert_eq(sender.next_deadline(), Some(6000L))
  assert_eq(sender.poll(1999L)[0] is @coap.Rejected(@coap.Clock), true)
  assert_eq(sender.is_pending(), true)
  assert_eq(transmitted(sender.poll(6000L)), first)
  let random = @coap.Sender::new("p", 1L).unwrap()
  ignore(random.send(b"[]", @senweave.SenmlJson, 0L, 1000000))
  assert_eq(random.next_deadline(), Some(3000L))
}

///|
test "empty ACK stops request retries while the response deadline remains active" {
  let sender = @coap.Sender::new("p", 1L, initial_mid=10).unwrap()
  ignore(sender.send(b"[]", @senweave.SenmlJson, 0L, 0))
  let ack = sender.receive("p", b"\x60\x00\x00\x0a", 1L)
  assert_eq(ack[0] is @coap.Acknowledged(1), true)
  assert_eq(sender.is_pending(), true)
  assert_eq(has_transmission(sender.poll(6000L)), false)
  assert_eq(sender.poll(10000L)[0] is @coap.Failed(1, @coap.TimedOut), true)
  assert_eq(sender.is_pending(), false)
}

///|
test "separate response is ACKed again without a second delivery" {
  let sender = @coap.Sender::new("p", 1L).unwrap()
  let wire = transmitted(sender.send(b"[]", @senweave.SenmlJson, 0L, 0))
  let reply = sender_reply(wire, separate=true)
  let events = sender.receive("p", reply, 1L)
  assert_eq(transmitted(events), b"\x60\x00\x00\x63")
  assert_eq(events.any(event => event is @coap.Received(1, 68, _)), true)
  assert_eq(sender.is_pending(), false)
  let duplicate = sender.receive("p", reply, 2L)
  assert_eq(transmitted(duplicate), b"\x60\x00\x00\x63")
  assert_eq(duplicate.any(event => event is @coap.Received(_, _, _)), false)
}

///|
test "foreign peer wrong token wrong MID and request code cannot complete an upload" {
  let sender = @coap.Sender::new("p", 1L).unwrap()
  let wire = transmitted(sender.send(b"[]", @senweave.SenmlJson, 0L, 0))
  let reply = sender_reply(wire)
  ignore(sender.receive("other", reply, 1L))
  for index in [0, 3, 4] {
    let invalid = Bytes::makei(reply.length(), i => {
      if i == index {
        reply[i] ^ 1
      } else {
        reply[i]
      }
    })
    ignore(sender.receive("p", invalid, 2L))
    assert_eq(sender.is_pending(), true)
  }
  let request_code = Bytes::makei(reply.length(), i => {
    if i == 1 {
      2
    } else {
      reply[i]
    }
  })
  assert_eq(
    sender.receive("p", request_code, 3L)[0] is @coap.IgnoredDatagram,
    true,
  )
  assert_eq(sender.is_pending(), true)
  assert_eq(sender.receive("p", reply, 4L)[0] is @coap.Received(1, 68, _), true)
}

///|
test "busy sender cancellation timeout and peer reset have explicit outcomes" {
  let sender = @coap.Sender::new("p", 1L).unwrap()
  ignore(sender.send(b"[]", @senweave.SenmlJson, 0L, 0))
  assert_eq(
    sender.send(b"[]", @senweave.SenmlJson, 1L, 0)[0]
    is @coap.Rejected(@coap.Busy),
    true,
  )
  assert_eq(sender.cancel(2L)[0] is @coap.Cancelled(1), true)
  assert_eq(sender.is_pending(), false)
  ignore(sender.send(b"[]", @senweave.SenmlJson, 3L, 0))
  assert_eq(sender.poll(10003L)[0] is @coap.Failed(2, @coap.TimedOut), true)
  assert_eq(sender.poll(10004L).length(), 0)
  ignore(sender.send(b"[]", @senweave.SenmlJson, 10005L, 0))
  assert_eq(
    sender.receive("p", b"\x70\x00\x00\x02", 10006L)[0]
    is @coap.Failed(3, @coap.ResetByPeer),
    true,
  )
}

///|
test "sequential uploads allocate new tokens and MID leases across wraparound" {
  let sender = @coap.Sender::new("p", 42L, initial_mid=65535).unwrap()
  let first = transmitted(sender.send(b"[]", @senweave.SenmlJson, 0L, 0))
  let reply = sender_reply(first)
  ignore(sender.receive("p", reply, 1L))
  let second = transmitted(sender.send(b"[]", @senweave.SenmlJson, 2L, 0))
  let a = @protocol.decode(first, @protocol.Limits::default()).unwrap()
  let b = @protocol.decode(second, @protocol.Limits::default()).unwrap()
  assert_eq(a.token != b.token, true)
  assert_eq(b.mid, 0)
  ignore(sender.receive("p", reply, 3L))
  assert_eq(sender.is_pending(), true)
  assert_eq(
    sender.receive("p", sender_reply(second, code=137), 4L)[0]
    is @coap.Received(2, 137, _),
    true,
  )
}

///|
test "cancellation at a retry deadline emits no new request" {
  let sender = @coap.Sender::new("p", 1L).unwrap()
  ignore(sender.send(b"[]", @senweave.SenmlJson, 0L, 0))
  let events = sender.cancel(2000L)
  assert_eq(events.length(), 1)
  assert_eq(events[0] is @coap.Cancelled(1), true)
  assert_eq(has_transmission(sender.poll(6000L)), false)
}

///|
test "MID history capacity fails explicitly and recovers after lifetime expiry" {
  let sender = @coap.Sender::new("p", 1L).unwrap()
  for _ in 0..<128 {
    assert_eq(
      has_transmission(sender.send(b"[]", @senweave.SenmlJson, 0L, 0)),
      true,
    )
    ignore(sender.cancel(0L))
  }
  assert_eq(
    sender.send(b"[]", @senweave.SenmlJson, 0L, 0)[0]
    is @coap.Rejected(@coap.Capacity),
    true,
  )
  assert_eq(sender.is_pending(), false)
  ignore(sender.poll(247000L))
  assert_eq(
    has_transmission(sender.send(b"[]", @senweave.SenmlJson, 247000L, 0)),
    true,
  )
}
