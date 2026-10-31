///|
// Output is limited to shallow SenML record maps. Keep major-type-one
// arguments unsigned so the complete negative integer range remains exact.
priv enum CborOutput {
  Scalar(@cbor.CborValue)
  NegativeInteger(UInt64)
  RecordMap(Array[(Int32, CborOutput)])
}

///|
fn Number::to_cbor(self : Number) -> CborOutput {
  if self.literal != "-0" &&
    !self.literal.contains(".") &&
    !self.literal.contains("e") {
    if self.literal == "-18446744073709551616" {
      return NegativeInteger(18446744073709551615UL)
    }
    if self.literal.has_prefix("-") {
      let magnitude = Some(
        @string.parse_uint64(self.literal[1:].to_owned(), base=10),
      ) catch {
        _ => None
      }
      if magnitude is Some(n) && n > 0UL {
        return NegativeInteger(n - 1UL)
      }
    } else {
      let integer = Some(@string.parse_uint64(self.literal, base=10)) catch {
        _ => None
      }
      if integer is Some(n) {
        return Scalar(@cbor.Unsigned(n))
      }
    }
  }
  Scalar(@cbor.Float64(self.approximate))
}

///|
fn cbor_measurement_fields(
  name : String?,
  unit : String?,
  value : MeasurementValue?,
  sum : Number?,
  time : Number?,
  update_time : Number?,
) -> Array[(Int32, CborOutput)] {
  let fields = []
  if name is Some(text) {
    fields.push((0, Scalar(@cbor.Text(text))))
  }
  if unit is Some(text) {
    fields.push((1, Scalar(@cbor.Text(text))))
  }
  match value {
    Some(Numeric(number)) => fields.push((2, number.to_cbor()))
    Some(Text(text)) => fields.push((3, Scalar(@cbor.Text(text))))
    Some(Boolean(flag)) =>
      fields.push((4, Scalar(@cbor.Simple(if flag { 21 } else { 20 }))))
    Some(Data(bytes)) => fields.push((8, Scalar(@cbor.Bytes(bytes))))
    None => ()
  }
  if sum is Some(number) {
    fields.push((5, number.to_cbor()))
  }
  if time is Some(number) {
    fields.push((6, number.to_cbor()))
  }
  if update_time is Some(number) {
    fields.push((7, number.to_cbor()))
  }
  fields
}

///|
fn Record::to_cbor(self : Record) -> CborOutput {
  let fields = cbor_measurement_fields(
    self.name,
    self.unit,
    self.value,
    self.sum,
    self.time,
    self.update_time,
  )
  if self.base_name is Some(text) {
    fields.push((-2, Scalar(@cbor.Text(text))))
  }
  if self.base_unit is Some(text) {
    fields.push((-4, Scalar(@cbor.Text(text))))
  }
  if self.base_time is Some(number) {
    fields.push((-3, number.to_cbor()))
  }
  if self.base_value is Some(number) {
    fields.push((-5, number.to_cbor()))
  }
  if self.base_sum is Some(number) {
    fields.push((-6, number.to_cbor()))
  }
  if self.base_version is Some(_) {
    fields.push((-1, Scalar(@cbor.Unsigned(10UL))))
  }
  RecordMap(fields)
}

///|
fn ResolvedRecord::to_cbor(self : ResolvedRecord) -> CborOutput {
  RecordMap(
    cbor_measurement_fields(
      Some(self.name),
      self.unit,
      self.value,
      self.sum,
      Some(self.time),
      self.update_time,
    ),
  )
}

///|
fn CborOutput::size_bound(self : CborOutput) -> Int64 {
  match self {
    Scalar(@cbor.Text(text)) => 9L + 3L * text.length().to_int64()
    Scalar(@cbor.Bytes(bytes)) => 9L + bytes.length().to_int64()
    RecordMap(fields) => {
      let mut size = 9L
      for (_, value) in fields {
        size += 9L + value.size_bound()
      }
      size
    }
    _ => 9L
  }
}

///|
fn write_cbor_head(buffer : Buffer, major : Int32, argument : UInt64) -> Unit {
  let prefix = major << 5
  if argument < 24UL {
    buffer.write_byte((prefix | argument.to_int()).to_byte())
    return
  }
  let (info, width) = if argument <= 255UL {
    (24, 1)
  } else if argument <= 65535UL {
    (25, 2)
  } else if argument <= 4294967295UL {
    (26, 4)
  } else {
    (27, 8)
  }
  buffer.write_byte((prefix | info).to_byte())
  for index in 0..<width {
    buffer.write_byte((argument >> ((width - index - 1) * 8)).to_byte())
  }
}

///|
fn cbor_label_order(label : Int32) -> Int32 {
  if label < 0 {
    31 - label
  } else {
    label
  }
}

///|
fn CborOutput::write(self : CborOutput, buffer : Buffer) -> Unit {
  match self {
    Scalar(value) => @cbor.encode_to_buffer(value, buffer)
    NegativeInteger(argument) => write_cbor_head(buffer, 1, argument)
    RecordMap(fields) => {
      // Every standard key fits one byte; preserve the codec's existing order.
      fields.sort_by((a, b) => cbor_label_order(a.0) - cbor_label_order(b.0))
      write_cbor_head(buffer, 5, fields.length().to_uint64())
      for (key, value) in fields {
        @cbor.encode_to_buffer(@cbor.Integer(key.to_int64()), buffer)
        value.write(buffer)
      }
    }
  }
}

///|
fn encode_cbor_records(
  records : Array[CborOutput],
  max_output_bytes : Int32,
) -> Bytes raise SenmlError {
  if max_output_bytes <= 0 {
    reject(InvalidLimits, None, None, "CBOR output limit must be positive.")
  }
  let mut size = if records.is_empty() { 1L } else { 9L }
  for record in records {
    size += record.size_bound()
    if size > max_output_bytes.to_int64() {
      reject(
        OutputLimit,
        None,
        None,
        "CBOR output exceeds the conservative byte limit.",
      )
    }
  }
  let buffer = Buffer()
  write_cbor_head(buffer, 4, records.length().to_uint64())
  for record in records {
    record.write(buffer)
  }
  buffer.to_bytes()
}

///|
/// Encode raw records in their original order, retaining base context.
/// Plain integer literals in the complete CBOR range remain exact. Other
/// numeric spellings use binary64; optional extensions are not retained.
pub fn Pack::to_cbor_bytes(
  self : Pack,
  max_output_bytes~ : Int32 = 4_194_304,
) -> Bytes raise SenmlError {
  encode_cbor_records(
    self.records.map(record => record.to_cbor()),
    max_output_bytes,
  )
}

///|
/// Encode chronologically ordered, context-free SenML CBOR measurements.
pub fn ResolvedPack::to_cbor_bytes(
  self : ResolvedPack,
  max_output_bytes~ : Int32 = 4_194_304,
) -> Bytes raise SenmlError {
  encode_cbor_records(
    self.records.map(record => record.to_cbor()),
    max_output_bytes,
  )
}

///|
/// Encode a single independent measurement as a one-element SenML CBOR array.
pub fn ResolvedRecord::to_cbor_bytes(
  self : ResolvedRecord,
  max_output_bytes~ : Int32 = 4_194_304,
) -> Bytes raise SenmlError {
  encode_cbor_records([self.to_cbor()], max_output_bytes)
}
