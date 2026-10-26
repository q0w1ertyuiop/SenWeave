///|
fn delivery(events : Array[@coap.Event]) -> @coap.Delivery {
  for event in events {
    if event is @coap.Pending(handle, _, _) {
      return handle
    }
  }
  abort("Expected a pending delivery.")
}

///|
test "deferred ingestion acknowledges transport without confirming storage and deduplicates pending input" {
  let collector = @coap.Collector::new(deferred=true)
  let wire = request(b"[{\"n\":\"counter\",\"v\":9007199254740993}]")
  let events = collector.receive("p", wire, 0L, 1793000000.0)
  let handle = delivery(events)
  assert_eq(handle.id() > 0, true)
  assert_eq(accepted(events) is None, true)
  let ack = response(events).unwrap()
  assert_eq(ack.code.value, 0)
  assert_eq(ack.msg_type, @protocol.Acknowledgement)
  assert_eq(ack.token, b"")
  assert_eq(ack.mid, 10)
  let duplicate = collector.receive("p", wire, 1L, 1793000100.0)
  assert_eq(duplicate.length(), 1)
  assert_eq(response(duplicate).unwrap(), ack)
  assert_eq(collector.pending_count(), 1)
}

///|
test "successful storage schedules a separate response and peer ACK stops retransmission" {
  let collector = @coap.Collector::new(deferred=true)
  let handle = delivery(
    collector.receive("p", request(b"[]"), 0L, 1793000000.0),
  )
  let events = handle.finish(stored=true, 1L)
  assert_eq(events[0] is @coap.Completed(_, "p"), true)
  let success = response(events).unwrap()
  assert_eq(success.code.value, 68)
  assert_eq(success.msg_type, @protocol.Confirmable)
  assert_eq(success.token, b"\x01")
  assert_eq(collector.pending_count(), 0)
  assert_eq(response(collector.poll(2001L)).unwrap(), success)
  let ack = @protocol.encode(
    @protocol.empty_control(@protocol.Acknowledgement, success.mid),
    @protocol.Limits::default(),
  ).unwrap()
  let _ = collector.receive("p", ack, 2002L, 1793000002.0)
  assert_eq(response(collector.poll(6002L)) is None, true)
  assert_eq(
    handle.finish(stored=true, 6003L)[0] is @coap.InvalidDelivery(_),
    true,
  )
}

///|
test "failed storage never creates a successful response or a repeat delivery" {
  let collector = @coap.Collector::new(deferred=true)
  let wire = request(b"[{\"n\":\"x\",\"v\":1}]")
  let handle = delivery(collector.receive("p", wire, 0L, 1793000000.0))
  let failed = handle.finish(stored=false, 1L)
  assert_eq(failed[0] is @coap.StorageFailed(_, "p"), true)
  assert_eq(response(failed).unwrap().code.value, 160)
  assert_eq(collector.pending_count(), 0)
  assert_eq(handle.finish(stored=true, 2L)[0] is @coap.InvalidDelivery(_), true)
  let duplicate = collector.receive("p", wire, 3L, 1793000000.0)
  assert_eq(duplicate.length(), 1)
  assert_eq(response(duplicate).unwrap().code.value, 0)
}

///|
test "deadline expires pending storage and rejects a late success" {
  let collector = @coap.Collector::new(deferred=true)
  let handle = delivery(
    collector.receive("p", request(b"[]"), 0L, 1793000000.0),
  )
  assert_eq(collector.poll(29999L).length(), 0)
  let expired = collector.poll(30000L)
  assert_eq(response(expired).unwrap().code.value, 163)
  assert_eq(expired[expired.length() - 1] is @coap.Expired(_, "p"), true)
  assert_eq(collector.pending_count(), 0)
  assert_eq(
    handle.finish(stored=true, 30001L)[0] is @coap.InvalidDelivery(_),
    true,
  )
}

///|
test "pending capacity rejects overflow without evicting live work and is reusable" {
  let collector = @coap.Collector::new(deferred=true)
  let handles = []
  for mid in 0..<16 {
    handles.push(
      delivery(collector.receive("p", request(b"[]", mid~), 0L, 1793000000.0)),
    )
  }
  let busy = collector.receive("p", request(b"[]", mid=16), 0L, 1793000000.0)
  assert_eq(busy[0] is @coap.Busy("p"), true)
  assert_eq(response(busy).unwrap().code.value, 163)
  assert_eq(collector.pending_count(), 16)
  let _ = handles[0].finish(stored=true, 1L)
  let _ = delivery(
    collector.receive("p", request(b"[]", mid=17), 2L, 1793000000.0),
  )
  assert_eq(collector.pending_count(), 16)
}

///|
test "clock regression leaves a delivery live and collector handles cannot cross sessions" {
  let first = @coap.Collector::new(deferred=true)
  let second = @coap.Collector::new(deferred=true)
  let handle = delivery(first.receive("p", request(b"[]"), 10L, 1793000000.0))
  let _ = delivery(second.receive("p", request(b"[]"), 10L, 1793000000.0))
  assert_eq(handle.finish(stored=true, 9L)[0] is @coap.InvalidClock, true)
  assert_eq(first.pending_count(), 1)
  let _ = handle.finish(stored=true, 11L)
  assert_eq(first.pending_count(), 0)
  assert_eq(second.pending_count(), 1)
}

///|
test "nonconfirmable ingestion has no empty ACK and completes with NON response" {
  let collector = @coap.Collector::new(deferred=true)
  let events = collector.receive(
    "p",
    request(b"[]", msg_type=@protocol.NonConfirmable),
    0L,
    1793000000.0,
  )
  assert_eq(response(events) is None, true)
  let finished = delivery(events).finish(stored=true, 1L)
  assert_eq(response(finished).unwrap().msg_type, @protocol.NonConfirmable)
  assert_eq(response(finished).unwrap().code.value, 68)
}

///|
test "invalid data never enters the storage queue and stale handles remain invalid after exchange expiry" {
  let collector = @coap.Collector::new(deferred=true)
  let invalid = collector.receive("p", request(b"private"), 0L, 1793000000.0)
  assert_eq(response(invalid).unwrap().code.value, 128)
  assert_eq(collector.pending_count(), 0)
  let handle = delivery(
    collector.receive("p", request(b"[]", mid=11), 1L, 1793000000.0),
  )
  let _ = collector.poll(247002L)
  let fresh = delivery(
    collector.receive("p", request(b"[]", mid=11), 247003L, 1793001000.0),
  )
  assert_eq(handle.id() != fresh.id(), true)
  assert_eq(
    handle.finish(stored=true, 247004L)[0] is @coap.InvalidDelivery(_),
    true,
  )
  assert_eq(collector.pending_count(), 1)
}
