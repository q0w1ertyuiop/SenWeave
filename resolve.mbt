///|
/// Apply bases before extracting measurements. Relative times require an
/// explicit reference_time (POSIX seconds >= 2**28); no system clock is read.
/// Arithmetic uses binary64, can round, and rejects non-finite results.
/// A conservative bound on serialized UTF-16 size limits expansion, including
/// repeated names/units and JSON escaping. Context-only records are not emitted.
pub fn Pack::resolve(
  self : Pack,
  reference_time? : Double,
  max_expanded_code_units~ : Int32 = 4_194_304,
) -> ResolvedPack raise SenmlError {
  if max_expanded_code_units <= 0 {
    reject(InvalidLimits, None, None, "Expansion limit must be positive.")
  }
  if reference_time is Some(now) &&
    (now.is_nan() || now.is_inf() || now < 268435456.0) {
    reject(
      InvalidReferenceTime,
      None,
      None,
      "Reference time must be finite absolute POSIX seconds at least 2**28.",
    )
  }
  let records : Array[ResolvedRecord] = []
  let mut base_name = ""
  let mut base_unit : String? = None
  let mut base_time : Number? = None
  let mut base_value : Number? = None
  let mut base_sum : Number? = None
  let mut expanded_cost : Int64 = 2L
  if expanded_cost > max_expanded_code_units.to_int64() {
    reject(
      ExpansionLimit,
      None,
      None,
      "Resolved JSON exceeds the expansion limit.",
    )
  }
  for index, record in self.records {
    if record.base_name is Some(name) {
      base_name = name
    }
    if record.base_unit is Some(unit) {
      base_unit = Some(unit)
    }
    if record.base_time is Some(time) {
      base_time = Some(time)
    }
    if record.base_value is Some(value) {
      base_value = Some(value)
    }
    if record.base_sum is Some(sum) {
      base_sum = Some(sum)
    }
    if !record.is_measurement() {
      continue
    }
    let time = resolve_time(base_time, record.time, reference_time, index)
    let value = match record.value {
      Some(Numeric(value)) =>
        Some(Numeric(add_numbers(base_value, Some(value), index, "v").unwrap()))
      // A sum-only measurement can still have an inherited numeric base value.
      None => base_value.map(n => MeasurementValue::Numeric(n))
      value => value
    }
    let sum = add_numbers(base_sum, record.sum, index, "s")
    let unit = match record.unit {
      Some(_) => record.unit
      None => base_unit
    }
    let name = record.name.unwrap_or("")
    // Check BEFORE allocating a potentially very long concatenated name.
    expanded_cost += expanded_record_cost(
      base_name.length().to_int64() + name.length().to_int64(),
      unit,
      value,
      sum,
      time,
      record.update_time,
    )
    if expanded_cost > max_expanded_code_units.to_int64() {
      reject(
        ExpansionLimit,
        Some(index),
        None,
        "Resolved JSON exceeds the conservative expansion limit.",
      )
    }
    records.push({
      name: base_name + name,
      time,
      unit,
      value,
      sum,
      update_time: record.update_time,
      source_index: index,
      ignored_extension_count: record.ignored_extension_count,
    })
  }
  // sort_by is unstable; the source-index tie-break makes equal-time order
  // deterministic across backends without depending on sort stability.
  records.sort_by((a, b) => {
    if a.time.approximate < b.time.approximate {
      -1
    } else if a.time.approximate > b.time.approximate {
      1
    } else {
      a.source_index - b.source_index
    }
  })
  { records, }
}

///|
fn add_numbers(
  base : Number?,
  offset : Number?,
  index : Int32,
  field : String,
) -> Number? raise SenmlError {
  match (base, offset) {
    (None, value) | (value, None) => value
    (Some(base), Some(offset)) => {
      // Identity operations retain exact source text, including large integers.
      if base.approximate == 0.0 {
        return Some(offset)
      }
      if offset.approximate == 0.0 {
        return Some(base)
      }
      Some(computed_number(base.approximate + offset.approximate, index, field))
    }
  }
}

///|
fn computed_number(
  value : Double,
  index : Int32,
  field : String,
) -> Number raise SenmlError {
  if value.is_nan() || value.is_inf() {
    reject(
      ArithmeticOverflow,
      Some(index),
      Some(field),
      "Arithmetic produced a non-finite result.",
    )
  }
  {
    approximate: value,
    literal: Json::number(value).stringify().replace_all(old="E", new="e"),
  }
}

///|
fn resolve_time(
  base : Number?,
  offset : Number?,
  reference : Double?,
  index : Int32,
) -> Number raise SenmlError {
  let combined = add_numbers(base, offset, index, "t").unwrap_or({
    approximate: 0.0,
    literal: "0",
  })
  if combined.approximate >= 268435456.0 {
    return combined
  }
  let now = match reference {
    Some(now) => now
    None => {
      reject(
        MissingReferenceTime,
        Some(index),
        Some("t"),
        "Relative time requires an explicit reference time.",
      )
      0.0
    }
  }
  let absolute = computed_number(now + combined.approximate, index, "t")
  if absolute.approximate < 268435456.0 {
    reject(
      UnrepresentableTime,
      Some(index),
      Some("t"),
      "Resolved time is below the smallest SenML absolute timestamp.",
    )
  }
  absolute
}

///|
// Each UTF-16 code unit needs at most six JSON characters (a Unicode escape).
// Int64 accounting prevents overflow even with caller-increased parse limits.
// The fixed allowance covers keys, delimiters, bools and per-record commas.
fn expanded_record_cost(
  name_length : Int64,
  unit : String?,
  value : MeasurementValue?,
  sum : Number?,
  time : Number,
  update_time : Number?,
) -> Int64 {
  let mut cost = 128L + 6L * name_length + time.literal.length().to_int64()
  if unit is Some(text) {
    cost += 6L * text.length().to_int64()
  }
  match value {
    Some(Numeric(number)) => cost += number.literal.length().to_int64()
    Some(Text(text)) => cost += 6L * text.length().to_int64()
    Some(Data(bytes)) => cost += (bytes.length().to_int64() + 2L) / 3L * 4L
    _ => ()
  }
  if sum is Some(number) {
    cost += number.literal.length().to_int64()
  }
  if update_time is Some(number) {
    cost += number.literal.length().to_int64()
  }
  cost
}
