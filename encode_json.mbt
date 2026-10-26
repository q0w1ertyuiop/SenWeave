///|
fn Number::to_json(self : Number) -> Json {
  Json::number(self.approximate, repr=self.literal)
}

///|
fn ResolvedRecord::to_json(self : ResolvedRecord) -> Json {
  let fields : Map[String, Json] = {
    "n": Json::string(self.name),
    "t": self.time.to_json(),
  }
  if self.unit is Some(unit) {
    fields["u"] = Json::string(unit)
  }
  match self.value {
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
  if self.sum is Some(sum) {
    fields["s"] = sum.to_json()
  }
  if self.update_time is Some(time) {
    fields["ut"] = time.to_json()
  }
  Json::object(fields)
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
