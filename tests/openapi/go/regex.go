// The regex vectors of zefir-validator in Go: JSON Schema draft 2020-12 by
// github.com/santhosh-tekuri/jsonschema, each `pattern` a regular expression
// of Go's regexp, the syntax of RE2.
//
//	go run ./regex.go <vectors.json>
//
// A record agrees when `exact ? valid == pass : (!pass || valid)`: an exact
// schema says what the rule says, an approximate one passes every input the
// rule passes. Formats are not checked: they are hints. Prints
// `<n> records, <k> disagreements` and each disagreement, and exits with 1
// when there is one or a schema does not compile.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strconv"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

type record struct {
	Rule   string          `json:"rule"`
	Schema json.RawMessage `json:"schema"`
	Input  string          `json:"input"`
	Pass   bool            `json:"pass"`
	Exact  bool            `json:"exact"`
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: regex <vectors.json>")
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var records []record
	if err := json.Unmarshal(data, &records); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	compiled := map[string]*jsonschema.Schema{}
	failures, disagreements := 0, 0
	for _, r := range records {
		key := string(r.Schema)
		schema, seen := compiled[key]
		if !seen {
			schema, err = compile(r.Schema)
			if err != nil {
				fmt.Printf("%s: the schema does not compile: %v\n", r.Rule, err)
				failures++
			}
			compiled[key] = schema
		}
		if schema == nil {
			continue
		}
		valid := schema.Validate(r.Input) == nil
		agrees := !r.Pass || valid
		if r.Exact {
			agrees = valid == r.Pass
		}
		if !agrees {
			disagreements++
			fmt.Printf("%s: %s: the rule %s it, the schema %s it\n", r.Rule, strconv.Quote(r.Input), verdict(r.Pass), verdict(valid))
		}
	}
	fmt.Printf("%d records, %d disagreements\n", len(records), disagreements)
	if failures > 0 || disagreements > 0 {
		os.Exit(1)
	}
}

// compile builds {"type":"string", ...keywords} with the default engine of
// the library for `pattern`, Go's regexp.
func compile(keywords json.RawMessage) (*jsonschema.Schema, error) {
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(keywords))
	if err != nil {
		return nil, err
	}
	object, ok := doc.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("the schema is not an object")
	}
	object["type"] = "string"
	c := jsonschema.NewCompiler()
	c.DefaultDraft(jsonschema.Draft2020)
	if err := c.AddResource("schema.json", object); err != nil {
		return nil, err
	}
	return c.Compile("schema.json")
}

func verdict(pass bool) string {
	if pass {
		return "passes"
	}
	return "fails"
}
