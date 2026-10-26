///|
// Check wire lengths and recursion before the dependency allocates a tree.
// This ingress profile accepts definite-length containers and strings only.
priv struct CborScan {
  input : Bytes
  mut offset : Int32
  limits : ParseLimits
}

///|
fn CborScan::byte(self : CborScan) -> Int32 raise SenmlError {
  if self.offset >= self.input.length() {
    reject(InvalidCbor, None, None, "Truncated CBOR input.")
  }
  let value = self.input[self.offset].to_int()
  self.offset += 1
  value
}

///|
fn CborScan::header(self : CborScan) -> (Int32, UInt64) raise SenmlError {
  let initial = self.byte()
  let major = initial >> 5
  let info = initial & 31
  if info < 24 {
    return (major, info.to_uint64())
  }
  let width = match info {
    24 => 1
    25 => 2
    26 => 4
    27 => 8
    _ => {
      reject(
        UnsupportedCborType,
        None,
        None,
        "Reserved or indefinite-length CBOR item.",
      )
      0
    }
  }
  let mut argument = 0UL
  for _ in 0..<width {
    argument = (argument << 8) | self.byte().to_uint64()
  }
  (major, argument)
}

///|
fn CborScan::item(self : CborScan, depth : Int32) -> Unit raise SenmlError {
  if depth > self.limits.max_depth {
    reject(
      NestingLimit,
      None,
      None,
      "CBOR item nesting exceeds the configured limit.",
    )
  }
  let (major, argument) = self.header()
  if depth == 1 && major != 4 {
    reject(
      InvalidRoot,
      None,
      None,
      "SenML CBOR must be a definite-length array.",
    )
  }
  if depth == 2 && major != 5 {
    reject(InvalidRecord, None, None, "Each SenML CBOR record must be a map.")
  }
  let remaining = self.input.length() - self.offset
  match major {
    2 | 3 => {
      if argument > remaining.to_uint64() {
        reject(
          InvalidCbor,
          None,
          None,
          "CBOR string length exceeds remaining input.",
        )
      }
      self.offset += argument.to_int()
    }
    4 | 5 => {
      if depth == 1 && argument > self.limits.max_records.to_uint64() {
        reject(
          RecordLimit,
          None,
          None,
          "Pack exceeds the configured record limit.",
        )
      }
      if depth == 2 && argument > self.limits.max_fields_per_record.to_uint64() {
        reject(
          FieldLimit,
          None,
          None,
          "Record exceeds the configured member limit.",
        )
      }
      let minimum_bytes = if major == 5 { 2 } else { 1 }
      if argument > (remaining / minimum_bytes).to_uint64() {
        reject(
          InvalidCbor,
          None,
          None,
          "CBOR container count exceeds remaining input.",
        )
      }
      for _ in 0..<argument.to_int() {
        self.item(depth + 1)
        if major == 5 {
          self.item(depth + 1)
        }
      }
    }
    6 => self.item(depth + 1)
    _ => ()
  }
}

///|
fn scan_cbor(input : Bytes, limits : ParseLimits) -> Unit raise SenmlError {
  let scan = { input, offset: 0, limits, }
  scan.item(1)
  if scan.offset != input.length() {
    reject(InvalidCbor, None, None, "Trailing bytes after SenML CBOR pack.")
  }
}
