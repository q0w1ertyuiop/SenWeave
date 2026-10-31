// The adapter calls the pinned upstream API without modifying its records.
// Raw encoding precedes Normalize, which can modify pointed-to value fields.
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"github.com/absmach/senml"
)

type request struct {
	Payload string `json:"payload"`
	Format  string `json:"format"`
}

func compare(q request) map[string]string {
	r := map[string]string{}
	format := senml.JSON
	data := []byte(q.Payload)
	if q.Format == "cbor" {
		format = senml.CBOR
		var err error
		data, err = hex.DecodeString(q.Payload)
		if err != nil {
			return map[string]string{"stage": "decode_validate", "error": "invalid hex"}
		}
	}
	// Decode invokes Validate in the pinned upstream version.
	p, err := senml.Decode(data, format)
	if err != nil {
		return map[string]string{"stage": "decode_validate", "error": err.Error()}
	}
	for _, f := range []senml.Format{senml.JSON, senml.CBOR} {
		encoded, err := senml.Encode(p, f)
		if err != nil {
			r["stage"], r["error"] = "encode_raw", err.Error()
			return r
		}
		if f == senml.JSON {
			r["raw_json"] = string(encoded)
		} else {
			r["raw_cbor"] = hex.EncodeToString(encoded)
		}
	}
	p, err = senml.Normalize(p)
	if err != nil {
		r["stage"], r["error"] = "normalize", err.Error()
		return r
	}
	for _, f := range []senml.Format{senml.JSON, senml.CBOR} {
		encoded, err := senml.Encode(p, f)
		if err != nil {
			r["stage"], r["error"] = "encode_normalized", err.Error()
			return r
		}
		if f == senml.JSON {
			r["normalized_json"] = string(encoded)
		} else {
			r["normalized_cbor"] = hex.EncodeToString(encoded)
		}
	}
	r["stage"] = "normalized"
	return r
}

func main() {
	var requests []request
	if err := json.NewDecoder(os.Stdin).Decode(&requests); err != nil {
		fmt.Fprintln(os.Stderr, "Invalid comparison request envelope")
		os.Exit(1)
	}
	results := make([]map[string]string, 0, len(requests))
	for _, q := range requests {
		results = append(results, compare(q))
	}
	if err := json.NewEncoder(os.Stdout).Encode(results); err != nil {
		os.Exit(1)
	}
}
