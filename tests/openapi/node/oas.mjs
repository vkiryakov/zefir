// The OpenAPI documents of zefir against the official JSON Schema of their
// version, the schema-base of OAS 3.1 or 3.2, with ajv (JSON Schema 2020-12):
//
//     node oas.mjs <oas dir> <zefir root>
//
// <oas dir> holds a folder per version (3.1, 3.2) with the files that
// spec.openapis.org publishes, as published: schema, schema-base, dialect
// and meta. The documents are those of src/openapi/tests/golden, and the
// openapi.json of the guides of zefir-openapi and zefir-http where they
// exist. Prints `<n> documents, <k> invalid` with the errors of each invalid
// one, and exits with 1 when one is invalid. Formats are not checked: they
// are hints, as in regex.mjs.
//
// ajv 8.20 resolves `$dynamicRef: "#meta"` of the schema file to the wrong
// definition: the schema of a parameter is checked as a parameter, every
// golden document fails, and pointing it at the schema file's own
// `$defs/schema` would check Schema Objects only for being objects. So this
// script loads the schema file with each `{"$dynamicRef": "#meta"}` turned
// into what the dynamic scope gives it when validation begins at
// schema-base: `{"$ref": "<schema-base>#/$defs/schema"}`, the Schema Object
// of the OAS dialect (JSON Schema 2020-12 and the OAS vocabulary). The files
// in <oas dir> stay as published.
//
// Then the check checks itself: copies of a golden document of each version
// are broken in a Schema Object of the components, of a property, of a
// parameter and of a media type, in an OAS keyword of a schema and outside
// any schema; ajv must find each of them invalid, and exits with 1 when it
// finds one valid.
import { existsSync, readFileSync, readdirSync } from "node:fs";
import Ajv2020 from "ajv/dist/2020.js";

const [oasDir, root] = process.argv.slice(2);
// The official schemas are not strict: they mention properties without
// their types.
const ajv = new Ajv2020({ strict: false, validateFormats: false, allErrors: true });

const read = (path) => JSON.parse(readFileSync(path, "utf8"));
const bases = {};
let failures = 0;
for (const version of ["3.1", "3.2"]) {
  const files = readdirSync(`${oasDir}/${version}`).filter((f) => f.endsWith(".json")).map((f) => read(`${oasDir}/${version}/${f}`));
  const base = files.find((s) => s.$id.includes("/schema-base/"));
  bases[version] = base.$id;
  for (const schema of files) {
    if (schema.$id === base.$ref) {
      const replaced = staticMeta(schema, `${base.$id}#/$defs/schema`);
      if (replaced === 0) {
        console.log(`${schema.$id}: no $dynamicRef "#meta" to replace; check whether ajv still needs it`);
        failures++;
      }
    }
    ajv.addSchema(schema);
  }
}

/// Turns each {"$dynamicRef": "#meta"} under `node` into {"$ref": ref};
/// returns how many.
function staticMeta(node, ref) {
  if (node === null || typeof node !== "object") return 0;
  let count = 0;
  for (const [key, value] of Object.entries(node)) {
    if (value !== null && typeof value === "object" && !Array.isArray(value) && value.$dynamicRef === "#meta" && Object.keys(value).length === 1) {
      node[key] = { $ref: ref };
      count++;
    } else count += staticMeta(value, ref);
  }
  return count;
}

const paths = readdirSync(`${root}/src/openapi/tests/golden`)
  .filter((f) => f.endsWith(".json"))
  .sort()
  .map((f) => `src/openapi/tests/golden/${f}`);
for (const guide of ["src/openapi/examples/openapi.json", "src/http/examples/openapi.json"]) {
  if (existsSync(`${root}/${guide}`)) paths.push(guide);
}

/// The validator of the schema-base of the version of `doc`, or null.
function validatorOf(doc) {
  const base = bases[String(doc.openapi).split(".").slice(0, 2).join(".")];
  return base ? ajv.getSchema(base) : null;
}

let invalid = 0;
for (const path of paths) {
  const doc = read(`${root}/${path}`);
  const validate = validatorOf(doc);
  if (validate === null) {
    invalid++;
    console.log(`${path}: no schema for OpenAPI ${doc.openapi}`);
  } else if (!validate(doc)) {
    invalid++;
    console.log(`${path}: invalid`);
    for (const e of validate.errors.slice(0, 10)) console.log(`  ${e.instancePath || "/"}: ${e.message} ${JSON.stringify(e.params)}`);
  }
}
console.log(`${paths.length} documents, ${invalid} invalid`);

// Each breaks a copy of a document, or returns false when the document has
// no place for it.
const breaks = {
  "a schema of the components of the type integr": (d) => {
    const name = Object.keys(d.components?.schemas ?? {})[0];
    if (name === undefined) return false;
    d.components.schemas[name].type = "integr";
    return true;
  },
  "a property of a schema with a negative maxLength": (d) => {
    const s = firstObjectSchema(d);
    if (s === undefined) return false;
    s.properties[Object.keys(s.properties)[0]].maxLength = -1;
    return true;
  },
  "a property of a schema with a discriminator without propertyName": (d) => {
    const s = firstObjectSchema(d);
    if (s === undefined) return false;
    s.properties[Object.keys(s.properties)[0]].discriminator = {};
    return true;
  },
  "the schema of a parameter of the type 7": (d) => {
    const p = operations(d).flatMap((op) => op.parameters ?? []).find((p) => p.schema);
    if (p === undefined) return false;
    p.schema = { type: 7 };
    return true;
  },
  "the schema of a media type with required not a list": (d) => {
    const m = operations(d)
      .flatMap((op) => Object.values(op.responses ?? {}))
      .flatMap((r) => Object.values(r.content ?? {}))
      .find((m) => m.schema);
    if (m === undefined) return false;
    m.schema = { required: "id" };
    return true;
  },
  "an info without its title": (d) => {
    delete d.info.title;
    return true;
  },
};

function firstObjectSchema(d) {
  return Object.values(d.components?.schemas ?? {}).find((s) => s.properties && Object.keys(s.properties).length > 0);
}

function operations(d) {
  return Object.values(d.paths ?? {}).flatMap((item) => Object.values(item).filter((op) => op && typeof op === "object" && op.responses));
}

let copies = 0;
let missed = 0;
for (const version of Object.keys(bases)) {
  const path = paths.find((p) => String(read(`${root}/${p}`).openapi).startsWith(`${version}.`));
  if (path === undefined) {
    console.log(`no document of OpenAPI ${version} to break`);
    failures++;
    continue;
  }
  const doc = read(`${root}/${path}`);
  const validate = validatorOf(doc);
  for (const [what, apply] of Object.entries(breaks)) {
    const copy = structuredClone(doc);
    if (!apply(copy)) {
      console.log(`${path}: no place for ${what}`);
      failures++;
      continue;
    }
    copies++;
    if (validate(copy)) {
      missed++;
      console.log(`${path} with ${what}: valid, but must not be`);
    }
  }
}
console.log(`${copies} broken copies, ${missed} found valid`);
if (invalid > 0 || missed > 0 || failures > 0) process.exit(1);
