///|
/// An immutable, context-free version-10 measurement. Time is absolute POSIX
/// seconds, and source_index identifies the original raw record before sorting.
/// Unknown optional extensions were discarded during parsing.
pub struct ResolvedRecord {
  name : String
  time : Number
  unit : String?
  value : MeasurementValue?
  sum : Number?
  update_time : Number?
  content_format : ContentFormatSpec?
  source_index : Int32
  ignored_extension_count : Int32
} derive(Debug)

///|
pub extend ResolvedRecord with Debug::{to_repr}

///|
/// Measurements sorted by time, with input order retained for equal times.
pub struct ResolvedPack {
  priv records : Array[ResolvedRecord]
}

///|
pub fn ResolvedPack::len(self : ResolvedPack) -> Int32 {
  self.records.length()
}

///|
pub fn ResolvedPack::record(
  self : ResolvedPack,
  index : Int32,
) -> ResolvedRecord? {
  self.records.get(index)
}

///|
/// Select independently usable measurements without reapplying raw context.
/// The predicate is called once per record in chronological order.
pub fn ResolvedPack::filter(
  self : ResolvedPack,
  predicate : (ResolvedRecord) -> Bool,
) -> ResolvedPack {
  { records: self.records.filter(predicate), }
}
