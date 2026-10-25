///|
test "RFC 8428 Table 4 vocabulary maps between JSON and integer CBOR keys" {
  let cases = [
    ("bver", -1, @senweave.BaseVersion),
    ("bn", -2, @senweave.BaseName),
    ("bt", -3, @senweave.BaseTime),
    ("bu", -4, @senweave.BaseUnit),
    ("bv", -5, @senweave.BaseValue),
    ("bs", -6, @senweave.BaseSum),
    ("n", 0, @senweave.Name),
    ("u", 1, @senweave.Unit),
    ("v", 2, @senweave.NumericValue),
    ("vs", 3, @senweave.StringValue),
    ("vb", 4, @senweave.BooleanValue),
    ("s", 5, @senweave.Sum),
    ("t", 6, @senweave.Time),
    ("ut", 7, @senweave.UpdateTime),
    ("vd", 8, @senweave.DataValue),
  ]
  for (name, key, label) in cases {
    assert_eq(@senweave.Label::from_json_name(name), Some(label))
    assert_eq(@senweave.Label::from_cbor_key(key), Some(label))
    assert_eq(label.json_name(), name)
    assert_eq(label.cbor_key(), key)
  }
}

///|
test "extensions and altered spellings are not mistaken for base vocabulary" {
  for name in ["", "BN", " bn", "bn ", "-2", "vendor", "vendor_"] {
    assert_eq(@senweave.Label::from_json_name(name), None)
  }
  for key in [-2147483648, -7, 9, 2147483647] {
    assert_eq(@senweave.Label::from_cbor_key(key), None)
  }
}
