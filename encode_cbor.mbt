///|
// Decimal source spellings do not exist on the CBOR wire. Preserve ordinary
// 64-bit integer literals exactly; other numbers use their binary64 projection.
fn Number::to_cbor(self : Number) -> @cbor.CborValue {
  if self.literal != "-0" &&
    !self.literal.contains(".") &&
    !self.literal.contains("e") {
    if self.literal.has_prefix("-") {
      let integer = Some(@string.parse_int64(self.literal, base=10)) catch {
        _ => None
      }
      if integer is Some(n) {
        return @cbor.Integer(n)
      }
    } else {
      let integer = Some(@string.parse_uint64(self.literal, base=10)) catch {
        _ => None
      }
      if integer is Some(n) {
        return @cbor.Unsigned(n)
      }
    }
  }
  @cbor.Float64(self.approximate)
}

///|
fn cbor_measurement_fields(
  name : String?,
  unit : String?,
  value : MeasurementValue?,
  sum : Number?,
  time : Number?,
  update_time : Number?,
) -> Array[(@cbor.CborValue, @cbor.CborValue)] {
  let fields = []
  if name is Some(text) {
    fields.push((@cbor.Integer(0L), @cbor.Text(text)))
  }
  if unit is Some(text) {
    fields.push((@cbor.Integer(1L), @cbor.Text(text)))
  }
  match value {
    Some(Numeric(number)) => fields.push((@cbor.Integer(2L), number.to_cbor()))
    Some(Text(text)) => fields.push((@cbor.Integer(3L), @cbor.Text(text)))
    Some(Boolean(flag)) =>
      fields.push((@cbor.Integer(4L), @cbor.Simple(if flag { 21 } else { 20 })))
    Some(Data(bytes)) => fields.push((@cbor.Integer(8L), @cbor.Bytes(bytes)))
    None => ()
  }
  if sum is Some(number) {
    fields.push((@cbor.Integer(5L), number.to_cbor()))
  }
  if time is Some(number) {
    fields.push((@cbor.Integer(6L), number.to_cbor()))
  }
  if update_time is Some(number) {
    fields.push((@cbor.Integer(7L), number.to_cbor()))
  }
  fields
}

///|
fn Record::to_cbor(self : Record) -> @cbor.CborValue {
  let fields = cbor_measurement_fields(
    self.name,
    self.unit,
    self.value,
    self.sum,
    self.time,
    self.update_time,
  )
  if self.base_name is Some(text) {
    fields.push((@cbor.Integer(-2L), @cbor.Text(text)))
  }
  if self.base_unit is Some(text) {
    fields.push((@cbor.Integer(-4L), @cbor.Text(text)))
  }
  if self.base_time is Some(number) {
    fields.push((@cbor.Integer(-3L), number.to_cbor()))
  }
  if self.base_value is Some(number) {
    fields.push((@cbor.Integer(-5L), number.to_cbor()))
  }
  if self.base_sum is Some(number) {
    fields.push((@cbor.Integer(-6L), number.to_cbor()))
  }
  // The parser has validated version 10. RFC 8428 requires unsigned encoding.
  if self.base_version is Some(_) {
    fields.push((@cbor.Integer(-1L), @cbor.Unsigned(10UL)))
  }
  @cbor.Map(fields)
}

///|
fn ResolvedRecord::to_cbor(self : ResolvedRecord) -> @cbor.CborValue {
  @cbor.Map(
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
// Bound UTF-8 encoding and header costs before invoking the shared encoder.
// These locally constructed trees contain only shallow arrays/maps/scalars.
fn cbor_size_bound(value : @cbor.CborValue) -> Int64 {
  match value {
    @cbor.Text(text) => 9L + 3L * text.length().to_int64()
    @cbor.Bytes(bytes) => 9L + bytes.length().to_int64()
    @cbor.Array(items) => {
      let mut cost = 9L
      for item in items {
        cost += cbor_size_bound(item)
      }
      cost
    }
    @cbor.Map(entries) => {
      let mut cost = 9L
      for (key, value) in entries {
        cost += cbor_size_bound(key) + cbor_size_bound(value)
      }
      cost
    }
    _ => 9L
  }
}

///|
fn encode_cbor_records(
  records : Array[@cbor.CborValue],
  max_output_bytes : Int32,
) -> Bytes raise SenmlError {
  if max_output_bytes <= 0 {
    reject(InvalidLimits, None, None, "CBOR output limit must be positive.")
  }
  let mut size = 1L
  // The empty array needs one byte; allow an exact one-byte empty output.
  if !records.is_empty() {
    size = 9L
  }
  for record in records {
    size += cbor_size_bound(record)
    if size > max_output_bytes.to_int64() {
      reject(
        OutputLimit,
        None,
        None,
        "CBOR output exceeds the conservative byte limit.",
      )
    }
  }
  @cbor.encode(@cbor.Array(records))
}

///|
/// Encode raw records in their original order, retaining base context.
/// Unknown extensions were discarded at parse time. Non-integer-literal
/// numbers use binary64; exact decimal source spellings are not retained.
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
