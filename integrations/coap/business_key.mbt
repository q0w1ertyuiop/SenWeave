///|
/// Application identity, separate from a CoAP MID or a SenML measurement name.
/// A production host must bind source to its authenticated producer identity.
pub struct BusinessKey {
  source : String
  key : String
} derive(Eq, Debug)

///|
pub extend BusinessKey with Eq::{equal, not_equal}

///|
pub extend BusinessKey with Debug::{to_repr}

///|
fn identifier_valid(value : String) -> Bool {
  if value.is_empty() || value.length() > 64 {
    return false
  }
  for unit in value.code_units() {
    let code = unit.to_int()
    if !((code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      code == 45 ||
      code == 46 ||
      code == 95) {
      return false
    }
  }
  true
}

///|
/// This application profile accepts no queries, or exactly source and key.
/// Values contain 1..64 ASCII letters, digits, '-', '.', '_'. Nothing is
/// decoded twice or silently normalized. Err does not echo received content.
pub fn BusinessKey::from_queries(
  queries : Array[String],
) -> Result[BusinessKey?, Unit] {
  if queries.is_empty() {
    return Ok(None)
  }
  if queries.length() != 2 {
    return Err(())
  }
  let mut source = None
  let mut key = None
  for query in queries {
    if query.length() > 71 {
      return Err(())
    }
    let parts = query.split("=").map(part => part.to_owned()).to_array()
    match parts {
      ["source", value] if source is None && identifier_valid(value) =>
        source = Some(value)
      ["key", value] if key is None && identifier_valid(value) =>
        key = Some(value)
      _ => return Err(())
    }
  }
  match (source, key) {
    (Some(source), Some(key)) => Ok(Some({ source, key, }))
    _ => Err(())
  }
}

///|
fn Collector::request_key(
  self : Collector,
  message : @protocol.Message,
) -> Result[BusinessKey?, Unit] {
  match @protocol.request_queries(message) {
    Ok(queries) =>
      if self.deferred && self.idempotency {
        BusinessKey::from_queries(queries)
      } else if queries.is_empty() {
        Ok(None)
      } else {
        Err(())
      }
    Err(_) => Err(())
  }
}
