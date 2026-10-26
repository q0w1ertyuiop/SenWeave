///|
test "business identity accepts paired bounded ASCII identifiers without normalization" {
  assert_eq(@coap.BusinessKey::from_queries([]), Ok(None))
  let key = @coap.BusinessKey::from_queries(["key=Batch-01", "source=Room_A.1"])
    .unwrap()
    .unwrap()
  assert_eq(key.source, "Room_A.1")
  assert_eq(key.key, "Batch-01")
  for
    queries in [
      ["source=a"],
      ["key=a"],
      ["source=a", "source=b"],
      ["key=a", "key=b"],
      ["source=a", "key="],
      ["source=a", "key=b", "extra=c"],
      ["source=a", "key=a=b"],
      ["Source=a", "key=b"],
      ["source=设备", "key=b"],
      ["source=a", "key=a b"],
      ["source=a", "key=a%20b"],
      ["source=a", "unknown=b"],
      [
        "source=a", "key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      ],
    ] {
    assert_eq(@coap.BusinessKey::from_queries(queries), Err(()))
  }
}

///|
test "business query profile is opt in and pending delivery carries original transport bytes" {
  let payload = b"[{\"n\":\"temperature\",\"v\":22.50,\"t\":-3}]"
  let wire = request(payload, queries=["source=room-a", "key=batch-1"])
  let disabled = @coap.Collector::new(deferred=true)
  assert_eq(
    response(disabled.receive("p", wire, 0L, 1793000000.0)).unwrap().code.value,
    128,
  )
  assert_eq(disabled.pending_count(), 0)
  let collector = @coap.Collector::new(deferred=true, idempotency=true)
  let handle = delivery(collector.receive("p", wire, 0L, 1793000000.0))
  assert_eq(handle.business_key().unwrap().source, "room-a")
  assert_eq(handle.business_key().unwrap().key, "batch-1")
  assert_eq(handle.payload(), payload)
  assert_eq(handle.format(), @senweave.SenmlJson)
}

///|
test "host reported duplicate and key conflict schedule distinct outcomes once" {
  for (outcome, code) in [(@coap.AlreadyStored, 68), (@coap.KeyConflict, 137)] {
    let collector = @coap.Collector::new(deferred=true, idempotency=true)
    let handle = delivery(
      collector.receive(
        "p",
        request(b"[]", queries=["source=a", "key=b"]),
        0L,
        1793000000.0,
      ),
    )
    let events = handle.complete(outcome, 1L)
    assert_eq(response(events).unwrap().code.value, code)
    if code == 68 {
      assert_eq(events[0] is @coap.Duplicate(_, "p"), true)
    } else {
      assert_eq(events[0] is @coap.Conflict(_, "p"), true)
    }
    assert_eq(collector.pending_count(), 0)
    assert_eq(
      handle.complete(@coap.Stored, 2L)[0] is @coap.InvalidDelivery(_),
      true,
    )
  }
}

///|
test "key-specific outcomes cannot consume unkeyed delivery and expiry still wins" {
  let collector = @coap.Collector::new(deferred=true, idempotency=true)
  let handle = delivery(
    collector.receive("p", request(b"[]"), 0L, 1793000000.0),
  )
  assert_eq(
    handle.complete(@coap.AlreadyStored, 1L)[0] is @coap.InvalidDelivery(_),
    true,
  )
  assert_eq(collector.pending_count(), 1)
  assert_eq(response(handle.finish(stored=true, 2L)).unwrap().code.value, 68)
  let late_collector = @coap.Collector::new(deferred=true, idempotency=true)
  let late = delivery(
    late_collector.receive(
      "p",
      request(b"[]", mid=11, queries=["source=a", "key=b"]),
      3L,
      1793000000.0,
    ),
  )
  let events = late.complete(@coap.AlreadyStored, 30003L)
  assert_eq(response(events).unwrap().code.value, 163)
  assert_eq(events[events.length() - 1] is @coap.InvalidDelivery(_), true)
}
