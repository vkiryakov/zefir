// The regex vectors of zefir-validator in ajv: JSON Schema draft 2020-12,
// each `pattern` an ECMA-262 regular expression with the u flag.
//
//     node regex.mjs <vectors.json>
//
// A record agrees when `exact ? valid == pass : (!pass || valid)`: an exact
// schema says what the rule says, an approximate one passes every input the
// rule passes. Formats are not checked: they are hints. Prints
// `<n> records, <k> disagreements` and each disagreement, and exits with 1
// when there is one or a schema does not compile.
import { readFileSync } from "node:fs";
import Ajv2020 from "ajv/dist/2020.js";

const records = JSON.parse(readFileSync(process.argv[2], "utf8"));
// strictSchema stays on: an unknown keyword is an error.
const ajv = new Ajv2020({ validateFormats: false, unicodeRegExp: true, strictTypes: false, strictTuples: false });

const compiled = new Map();
let failures = 0;
let disagreements = 0;
for (const record of records) {
  const key = JSON.stringify(record.schema);
  if (!compiled.has(key)) {
    try {
      compiled.set(key, ajv.compile({ type: "string", ...record.schema }));
    } catch (error) {
      console.log(`${record.rule}: the schema does not compile: ${error.message}`);
      compiled.set(key, null);
      failures++;
    }
  }
  const validate = compiled.get(key);
  if (validate === null) continue;
  const valid = validate(record.input);
  const agrees = record.exact ? valid === record.pass : !record.pass || valid;
  if (!agrees) {
    disagreements++;
    console.log(`${record.rule}: ${JSON.stringify(record.input)}: the rule ${record.pass ? "passes" : "fails"} it, the schema ${valid ? "passes" : "fails"} it`);
  }
}
console.log(`${records.length} records, ${disagreements} disagreements`);
if (failures > 0 || disagreements > 0) process.exit(1);
