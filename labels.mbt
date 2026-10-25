///|
/// The fifteen labels defined by RFC 8428, Section 6, Table 4.
///
/// Extension labels are deliberately outside this enum. An unrecognized label
/// is not a verdict about whether a complete SenML record is valid.
pub(all) enum Label {
  BaseVersion
  BaseName
  BaseTime
  BaseUnit
  BaseValue
  BaseSum
  Name
  Unit
  NumericValue
  StringValue
  BooleanValue
  Sum
  Time
  UpdateTime
  DataValue
} derive(Eq, Debug)

///|
pub extend Label with Eq::{equal, not_equal}

///|
pub extend Label with Debug::{to_repr}

///|
/// The case-sensitive JSON member name from RFC 8428.
pub fn Label::json_name(self : Label) -> String {
  match self {
    BaseVersion => "bver"
    BaseName => "bn"
    BaseTime => "bt"
    BaseUnit => "bu"
    BaseValue => "bv"
    BaseSum => "bs"
    Name => "n"
    Unit => "u"
    NumericValue => "v"
    StringValue => "vs"
    BooleanValue => "vb"
    Sum => "s"
    Time => "t"
    UpdateTime => "ut"
    DataValue => "vd"
  }
}

///|
/// The integer CBOR map key from RFC 8428, Section 6, Table 4.
pub fn Label::cbor_key(self : Label) -> Int32 {
  match self {
    BaseVersion => -1
    BaseName => -2
    BaseTime => -3
    BaseUnit => -4
    BaseValue => -5
    BaseSum => -6
    Name => 0
    Unit => 1
    NumericValue => 2
    StringValue => 3
    BooleanValue => 4
    Sum => 5
    Time => 6
    UpdateTime => 7
    DataValue => 8
  }
}

///|
/// Look up a known JSON label. Returns None for extensions and unknown names.
/// No whitespace trimming, aliasing, or case conversion is performed.
pub fn Label::from_json_name(name : String) -> Label? {
  match name {
    "bver" => Some(BaseVersion)
    "bn" => Some(BaseName)
    "bt" => Some(BaseTime)
    "bu" => Some(BaseUnit)
    "bv" => Some(BaseValue)
    "bs" => Some(BaseSum)
    "n" => Some(Name)
    "u" => Some(Unit)
    "v" => Some(NumericValue)
    "vs" => Some(StringValue)
    "vb" => Some(BooleanValue)
    "s" => Some(Sum)
    "t" => Some(Time)
    "ut" => Some(UpdateTime)
    "vd" => Some(DataValue)
    _ => None
  }
}

///|
/// Look up an RFC 8428 integer CBOR label. Unknown integer keys return None.
pub fn Label::from_cbor_key(key : Int32) -> Label? {
  match key {
    -1 => Some(BaseVersion)
    -2 => Some(BaseName)
    -3 => Some(BaseTime)
    -4 => Some(BaseUnit)
    -5 => Some(BaseValue)
    -6 => Some(BaseSum)
    0 => Some(Name)
    1 => Some(Unit)
    2 => Some(NumericValue)
    3 => Some(StringValue)
    4 => Some(BooleanValue)
    5 => Some(Sum)
    6 => Some(Time)
    7 => Some(UpdateTime)
    8 => Some(DataValue)
    _ => None
  }
}
