///|
fn Number::to_json(self : Number) -> Json {
  Json::number(self.approximate, repr=self.literal)
}

///|
fn measurement_json_fields(
  name : String?,
  unit : String?,
  value : MeasurementValue?,
  sum : Number?,
  time : Number?,
  update_time : Number?,
  content_format : ContentFormatSpec?,
) -> Map[String, Json] {
  let fields : Map[String, Json] = Map([])
  if name is Some(name) {
    fields["n"] = Json::string(name)
  }
  if time is Some(time) {
    fields["t"] = time.to_json()
  }
  if unit is Some(unit) {
    fields["u"] = Json::string(unit)
  }
  match value {
    Some(Numeric(number)) => fields["v"] = number.to_json()
    Some(Text(text)) => fields["vs"] = Json::string(text)
    Some(Boolean(flag)) => fields["vb"] = Json::boolean(flag)
    Some(Data(bytes)) =>
      fields["vd"] = Json::string(
        @base64.encode(bytes, padding=false)
        .replace_all(old="+", new="-")
        .replace_all(old="/", new="_"),
      )
    None => ()
  }
  if sum is Some(sum) {
    fields["s"] = sum.to_json()
  }
  if update_time is Some(time) {
    fields["ut"] = time.to_json()
  }
  if content_format is Some(format) {
    fields["ct"] = Json::string(format.as_string())
  }
  fields
}

///|
fn ResolvedRecord::to_json(self : ResolvedRecord) -> Json {
  Json::object(
    measurement_json_fields(
      Some(self.name),
      self.unit,
      self.value,
      self.sum,
      Some(self.time),
      self.update_time,
      self.content_format,
    ),
  )
}

///|
fn Record::to_json(self : Record) -> Json {
  let fields = measurement_json_fields(
    self.name,
    self.unit,
    self.value,
    self.sum,
    self.time,
    self.update_time,
    self.content_format,
  )
  if self.base_name is Some(text) {
    fields["bn"] = Json::string(text)
  }
  if self.base_unit is Some(text) {
    fields["bu"] = Json::string(text)
  }
  if self.base_content_format is Some(format) {
    fields["bct"] = Json::string(format.as_string())
  }
  for
    (key, value) in [
      ("bt", self.base_time),
      ("bv", self.base_value),
      ("bs", self.base_sum),
      ("bver", self.base_version),
    ] {
    if value is Some(number) {
      fields[key] = number.to_json()
    }
  }
  Json::object(fields)
}

///|
fn json_output_cost(value : Json) -> Int64 {
  match value {
    Json::String(text) => 2L + 6L * text.length().to_int64()
    Json::Number(number, repr~) =>
      match repr {
        Some(text) => text.length().to_int64()
        None => Json::number(number).stringify().length().to_int64()
      }
    Json::Object(fields) => {
      let mut size = 2L
      for (key, value) in fields {
        size += 4L + 6L * key.length().to_int64() + json_output_cost(value)
      }
      size
    }
    _ => 5L
  }
}

///|
/// Serialize raw records without applying bases or reading a reference clock.
/// Standard fields and numeric text are retained; ignored extensions are not.
/// The positive UTF-16 budget is checked conservatively before serialization.
pub fn Pack::to_json_string(
  self : Pack,
  max_output_code_units~ : Int32 = 4_194_304,
) -> String raise SenmlError {
  if max_output_code_units <= 0 {
    reject(InvalidLimits, None, None, "JSON output limit must be positive.")
  }
  let mut size = 2L
  let records = []
  for record in self.records {
    let json = record.to_json()
    size += 1L + json_output_cost(json)
    if size > max_output_code_units.to_int64() {
      reject(
        OutputLimit,
        None,
        None,
        "JSON output exceeds the conservative code-unit limit.",
      )
    }
    records.push(json)
  }
  if size > max_output_code_units.to_int64() {
    reject(
      OutputLimit,
      None,
      None,
      "JSON output exceeds the conservative code-unit limit.",
    )
  }
  Json::array(records).stringify()
}

///|
/// Serialize a one-element SenML pack that can be reparsed independently.
/// Provenance and ignored-extension counts are not SenML fields and are omitted.
pub fn ResolvedRecord::to_json_string(self : ResolvedRecord) -> String {
  Json::array([self.to_json()]).stringify()
}

///|
/// Serialize chronologically ordered, context-free SenML JSON records.
/// This is not a lossless extension-preserving or canonical-JSON codec.
pub fn ResolvedPack::to_json_string(self : ResolvedPack) -> String {
  Json::array(self.records.map(record => record.to_json())).stringify()
}
