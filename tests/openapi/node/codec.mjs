// The bodies the golden applications of zefir-openapi read and write,
// against the schemas of their documents, with ajv (JSON Schema 2020-12):
//
//     node codec.mjs <records.json> <golden dir>
//
// Each record of codec.zig is a request to an application and its response,
// with the version of the document to check them against,
// <golden dir>/<app>-<version>.json. The operation is that of the record's
// method and of the path template its target matches past the prefix.
// - A request answered below 400 had its body accepted: that body must
//   pass the schema of its media type in the operation's requestBody.
// - Every response, errors too, must be a status of the operation, and its
//   body must pass the schema of its media type there; a response without
//   a body must be one the document gives no content.
// A form (application/x-www-form-urlencoded) is an object of its fields,
// each value turned into the type of its schema, as the server reads it. A
// stream of events (text/event-stream) is, in 3.2, its events, each
// against itemSchema, the data of each against the contentSchema of its
// event; in 3.1, a string. Prints `<n> exchanges, <k> invalid` and each
// invalid one, and exits with 1 when there is one.
//
// The schemas compile strictly: a keyword that JSON Schema does not have
// is an error. Formats are not checked: they are hints, as in regex.mjs.
// Then the check checks itself: copies of records broken in a request
// body, a response body, a form and the data of events must each be found
// invalid.
import { readFileSync } from "node:fs";
import Ajv2020 from "ajv/dist/2020.js";

const [recordsPath, goldenDir] = process.argv.slice(2);
const records = JSON.parse(readFileSync(recordsPath, "utf8"));

const options = { validateFormats: false, unicodeRegExp: true, strictTypes: false, strictTuples: false, allErrors: true };
const ajv = new Ajv2020(options);
// The values of a form are strings: this one turns each into the type of
// its schema, and a lone value into a list where a list goes.
const forms = new Ajv2020({ ...options, coerceTypes: "array" });
// A document is added whole, so that its $refs resolve; these keywords of
// an OpenAPI document hold no schema of their own.
for (const a of [ajv, forms]) a.addVocabulary(["openapi", "info", "jsonSchemaDialect", "servers", "paths", "webhooks", "components", "security", "tags", "externalDocs"]);

const documents = new Map();
function documentOf(app, version) {
  const key = `${app}-${version}`;
  if (!documents.has(key)) {
    const doc = JSON.parse(readFileSync(`${goldenDir}/${key}.json`, "utf8"));
    const id = `https://zefir.test/golden/${key}.json`;
    for (const a of [ajv, forms]) a.addSchema(doc, id);
    documents.set(key, { doc, id });
  }
  return documents.get(key);
}

/// The URI of the schema at `parts` of the document `id`: a JSON pointer.
function at(id, parts) {
  return `${id}#` + parts.map((p) => "/" + encodeURIComponent(String(p).replaceAll("~", "~0").replaceAll("/", "~1"))).join("");
}

/// The errors of `value` against the schema at `parts`, or null when it
/// passes.
function check(validators, id, parts, value) {
  let validate;
  try {
    validate = validators.getSchema(at(id, parts));
  } catch (error) {
    return [`the schema ${parts.join(" ")} does not compile: ${error.message}`];
  }
  if (validate === undefined) return [`no schema at ${parts.join(" ")}`];
  if (validate(value)) return null;
  return validate.errors.slice(0, 5).map((e) => `${e.instancePath || "/"} ${e.message} ${JSON.stringify(e.params)}`);
}

/// The path template of `paths` that `path` matches, as the router picks
/// it: one of as many segments, else one whose last parameter takes the
/// rest of the path; of those, the one with a literal segment where the
/// others have a parameter, from the left (`/todos/count` before
/// `/todos/{id}`).
function templateOf(paths, path) {
  const kinds = (template) => template.split("/").map((s) => (s.startsWith("{") ? 1 : 0));
  const before = (a, b) => {
    const [x, y] = [kinds(a), kinds(b)];
    for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] < y[i];
    return x.length > y.length;
  };
  for (const rest of [false, true]) {
    let best = null;
    for (const template of Object.keys(paths)) {
      if (matches(template.split("/"), path.split("/"), rest) && (best === null || before(template, best))) best = template;
    }
    if (best !== null) return best;
  }
  return null;
}

function matches(template, path, rest) {
  for (let i = 0; i < template.length; i++) {
    if (i >= path.length) return false;
    const param = template[i].startsWith("{");
    if (param && rest && i === template.length - 1) return true;
    if (!param && template[i] !== path[i]) return false;
  }
  return template.length === path.length;
}

const mediaType = (contentType) => (contentType ? contentType.split(";")[0].trim().toLowerCase() : null);
const isJson = (type) => type === "application/json" || type.endsWith("+json");

/// A form as an object: a field's values in a list when it comes more than
/// once.
function formObject(body) {
  const object = {};
  for (const [key, value] of new URLSearchParams(body)) {
    if (!(key in object)) object[key] = value;
    else if (Array.isArray(object[key])) object[key].push(value);
    else object[key] = [object[key], value];
  }
  return object;
}

/// The events of a stream: its blocks with data, each as an object of its
/// fields, `retry` a number.
function streamEvents(text) {
  const out = [];
  for (const block of text.split("\n\n")) {
    const event = {};
    const data = [];
    for (const line of block.split("\n")) {
      if (line === "" || line.startsWith(":")) continue;
      const colon = line.indexOf(":");
      const field = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? "" : line.slice(colon + 1);
      if (value.startsWith(" ")) value = value.slice(1);
      if (field === "data") data.push(value);
      else if (field === "retry" && /^\d+$/.test(value)) event.retry = Number(value);
      else event[field] = value;
    }
    if (data.length === 0) continue;
    event.data = data.join("\n");
    out.push(event);
  }
  return out;
}

/// What is wrong with the body of a request or a response of `type`
/// against the media type at `parts`, or null.
function checkBody(validators, id, parts, media, type, body) {
  if (media.itemSchema !== undefined) {
    const errors = [];
    for (const event of streamEvents(body)) {
      const wrong = check(validators, id, [...parts, "itemSchema"], event);
      if (wrong) {
        errors.push(`the event ${JSON.stringify(event)}: ${wrong.join("; ")}`);
        continue;
      }
      // contentSchema is an annotation in JSON Schema: the data is checked
      // against it here.
      const branches = media.itemSchema.oneOf ?? [media.itemSchema];
      const index = branches.findIndex((s) => s.properties?.event?.const === undefined || s.properties.event.const === event.event);
      const data = branches[index]?.properties?.data;
      if (data?.contentSchema === undefined) continue;
      const where = media.itemSchema.oneOf ? [...parts, "itemSchema", "oneOf", index, "properties", "data", "contentSchema"] : [...parts, "itemSchema", "properties", "data", "contentSchema"];
      let value;
      try {
        value = JSON.parse(event.data);
      } catch {
        errors.push(`the data of the event ${event.event} is not JSON: ${event.data}`);
        continue;
      }
      const bad = check(validators, id, where, value);
      if (bad) errors.push(`the data of the event ${event.event}: ${bad.join("; ")}`);
    }
    return errors.length > 0 ? errors : null;
  }
  if (media.schema === undefined) return null;
  let value = body;
  if (isJson(type)) {
    try {
      value = JSON.parse(body);
    } catch {
      return [`the body is not JSON: ${body}`];
    }
  } else if (type === "application/x-www-form-urlencoded") value = formObject(body);
  return check(validators, id, [...parts, "schema"], value);
}

/// What is wrong with the record `r`, as a list of texts, or null.
function wrongWith(r) {
  const { doc, id } = documentOf(r.app, r.version);
  const end = r.target.indexOf("?");
  const path = r.target.slice(0, end < 0 ? r.target.length : end);
  if (!path.startsWith(r.prefix)) return [`the target is not under the prefix ${r.prefix}`];
  const template = templateOf(doc.paths, path.slice(r.prefix.length) || "/");
  if (template === null) return ["no path of the document matches the target"];
  const method = r.method.toLowerCase();
  const operation = doc.paths[template][method];
  if (operation === undefined) return [`no operation ${method} ${template}`];
  const wrong = [];

  if (r.status < 400 && r.request_body !== "") {
    const type = mediaType(r.request_type);
    const media = operation.requestBody?.content?.[type];
    if (media === undefined) wrong.push(`the request has a body of ${type}, which the requestBody of ${method} ${template} does not take`);
    else {
      const bad = checkBody(type === "application/x-www-form-urlencoded" ? forms : ajv, id, ["paths", template, method, "requestBody", "content", type], media, type, r.request_body);
      if (bad) wrong.push(`the body of the request: ${bad.join("; ")}`);
    }
  } else if (r.status < 400 && operation.requestBody?.required) wrong.push("the request has no body, which its requestBody requires");

  const response = operation.responses?.[String(r.status)];
  if (response === undefined) return [...wrong, `the status ${r.status} is not a response of ${method} ${template}`];
  const content = response.content ?? {};
  if (r.response_body === "") {
    if (Object.keys(content).length > 0) wrong.push(`the response has no body, but the document gives ${Object.keys(content).join(", ")}`);
  } else {
    const type = mediaType(r.response_type);
    const media = content[type];
    if (media === undefined) wrong.push(`the response has a body of ${type}, which the response ${r.status} does not give`);
    else {
      const bad = checkBody(ajv, id, ["paths", template, method, "responses", String(r.status), "content", type], media, type, r.response_body);
      if (bad) wrong.push(`the body of the response: ${bad.join("; ")}`);
    }
  }
  return wrong.length > 0 ? wrong : null;
}

let invalid = 0;
for (const r of records) {
  const wrong = wrongWith(r);
  if (wrong === null) continue;
  invalid++;
  console.log(`${r.app} ${r.version}: ${r.method} ${r.target} ${r.status}`);
  for (const line of wrong) console.log(`  ${line}`);
}
console.log(`${records.length} exchanges, ${invalid} invalid`);

// A body of the wrong type: an array for an object, else an object.
const wrongType = (body) => (JSON.stringify(JSON.parse(body)).startsWith("{") ? "[]" : "{}");
const broken = [];
const request = records.find((r) => r.status < 400 && r.request_type === "application/json" && r.request_body !== "");
if (request) broken.push({ what: "a request body of the wrong type", record: { ...request, request_body: wrongType(request.request_body) } });
const response = records.find((r) => isJson(mediaType(r.response_type) ?? "") && r.response_body !== "");
if (response) broken.push({ what: "a response body of the wrong type", record: { ...response, response_body: wrongType(response.response_body) } });
const form = records.find((r) => r.status < 400 && mediaType(r.request_type) === "application/x-www-form-urlencoded");
if (form) broken.push({ what: "a form without its fields", record: { ...form, request_body: "unknown=1" } });
const stream = records.find((r) => r.version === "3.2" && mediaType(r.response_type) === "text/event-stream" && r.status === 200);
if (stream) broken.push({ what: "events whose data is a list", record: { ...stream, response_body: stream.response_body.replace(/^data: .*$/gm, "data: []") } });
let missed = broken.length === 4 ? 0 : 1;
if (missed > 0) console.log("no record to break: one with a JSON request body, one with a JSON response body, one with a form, one with a stream of 3.2");
for (const { what, record } of broken) {
  if (wrongWith(record) !== null) continue;
  missed++;
  console.log(`${record.app} ${record.version}: ${record.method} ${record.target} with ${what}: valid, but must not be`);
}
console.log(`${broken.length} broken copies, ${missed} found valid`);
if (invalid > 0 || missed > 0) process.exit(1);
