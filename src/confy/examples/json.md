# JSON

JSON is the richest source: values keep their types, objects nest as deep as
your structs, and it is the only source that can hold **lists of structs**. Use
it for the configuration that lives in the repository.

```zig
.sources = &.{.json("config.json")},
```

## Contents

- [At a glance](#at-a-glance)
- [Keys and objects](#keys-and-objects)
- [Strings](#strings)
- [Integers](#integers)
- [Floats](#floats)
- [Booleans](#booleans)
- [Enums](#enums)
- [Optional fields and null](#optional-fields-and-null)
- [Lists](#lists)
- [Nested objects](#nested-objects)
- [Lists of objects](#lists-of-objects)
- [Secrets](#secrets)
- [Problems](#problems)
- [Limits](#limits)

## At a glance

Every field type, and how JSON writes it:

**`main.zig`**

```zig
const Config = struct {
    name: []const u8,
    debug: bool = false,
    log_level: enum { debug, info, warn, err } = .info,
    http: struct {
        port: u16,
        timeout_s: f32 = 30,
        allowed_origins: []const []const u8 = &.{},
    },
    db: struct {
        url: []const u8,
        password: confy.Secret,
        replica_url: ?[]const u8,
        pool: struct { size: u8 = 4, max_idle: u8 = 2 },
    },
    upstreams: []const struct { host: []const u8, weight: u8 = 1 } = &.{},
};
```

**`config.json`**

```json
{
  "name": "zefir-demo",
  "log_level": "debug",
  "http": {
    "port": 8080,
    "timeout_s": 2.5,
    "allowed_origins": ["https://app.example.com", "https://admin.example.com"]
  },
  "db": {
    "url": "postgres://db.internal:5432/app",
    "password": "change-me",
    "replica_url": null,
    "pool": { "size": 8 }
  },
  "upstreams": [
    { "host": "10.0.0.1:9000", "weight": 3 },
    { "host": "10.0.0.2:9000" }
  ]
}
```

| Field                  | Value                                                      | Why                           |
| ---------------------- | ---------------------------------------------------------- | ----------------------------- |
| `name`                 | `"zefir-demo"`                                             |                               |
| `debug`                | `false`                                                    | not in the file: the default  |
| `log_level`            | `.debug`                                                   |                               |
| `http.port`            | `8080`                                                     |                               |
| `http.timeout_s`       | `2.5`                                                      |                               |
| `http.allowed_origins` | `"https://app.example.com"`, `"https://admin.example.com"` |                               |
| `db.url`               | `"postgres://db.internal:5432/app"`                        |                               |
| `db.password`          | `"change-me"`                                              | prints as `[redacted]`        |
| `db.replica_url`       | `null`                                                     | `null` in the file            |
| `db.pool.size`         | `8`                                                        |                               |
| `db.pool.max_idle`     | `2`                                                        | not in the file: the default  |
| `upstreams[0]`         | `.{ .host = "10.0.0.1:9000", .weight = 3 }`                |                               |
| `upstreams[1]`         | `.{ .host = "10.0.0.2:9000", .weight = 1 }`                | `weight` not set: the default |

## Keys and objects

A key is a field name; an object is a nested struct. The top level of the file
must be an object.

```json
{ "http": { "port": 8080 } }
```

sets `http.port`. Keys are matched exactly, including case. A key that matches
no field is a problem, with a suggestion when a field name is close — even when
only the case differs:

| You write             | You get                                    |
| --------------------- | ------------------------------------------ |
| `"port": 8080`        | `port = 8080`                              |
| `"Port": 8080`        | `Port: unknown key (did you mean "port"?)` |
| `"prot": 8080`        | `prot: unknown key (did you mean "port"?)` |
| `"listen_port": 8080` | `listen_port: unknown key`                 |

> [!TIP]
> Unknown keys make typos loud: a misspelled key never silently leaves a field
> at its default.

## Strings

For `[]const u8` fields. All JSON escapes work.

| You write               | You get                                |
| ----------------------- | -------------------------------------- |
| `"name": "zefir"`       | `"zefir"`                              |
| `"name": ""`            | `""`                                   |
| `"name": "line\nbreak"` | a newline in the middle                |
| `"name": "café"`        | `"café"`                               |
| `"name": "say \"hi\""`  | `say "hi"`                             |
| `"name": 42`            | problem: `invalid (expected a string)` |
| `"name": null`          | not set: the default, or `missing`     |

## Integers

For any integer type, signed or unsigned, up to 128 bits. The value must fit
the field's type, and the problem says which range it expected.

| Field | You write                     | You get                                           |
| ----- | ----------------------------- | ------------------------------------------------- |
| `u16` | `"port": 8080`                | `8080`                                            |
| `u16` | `"port": "8080"`              | `8080`: strings are parsed too                    |
| `u16` | `"port": 70000`               | problem: `invalid (expected an integer 0..65535)` |
| `u16` | `"port": -1`                  | problem: `invalid (expected an integer 0..65535)` |
| `u16` | `"port": 80.5`                | problem: `invalid (expected an integer 0..65535)` |
| `i8`  | `"offset": -3`                | `-3`                                              |
| `u64` | `"max": 18446744073709551615` | `18446744073709551615`                            |

## Floats

For `f32` and `f64`. Any JSON number works, whole or not.

| You write         | You get                                |
| ----------------- | -------------------------------------- |
| `"ratio": 0.25`   | `0.25`                                 |
| `"ratio": 1`      | `1.0`                                  |
| `"ratio": 2.5e-3` | `0.0025`                               |
| `"ratio": "0.25"` | `0.25`: strings are parsed too         |
| `"ratio": true`   | problem: `invalid (expected a number)` |

## Booleans

| You write                       | You get                                     |
| ------------------------------- | ------------------------------------------- |
| `"debug": true`                 | `true`                                      |
| `"debug": false`                | `false`                                     |
| `"debug": "yes"`, `"on"`, `"1"` | `true`: strings are parsed as in INI files  |
| `"debug": "no"`, `"off"`, `"0"` | `false`                                     |
| `"debug": 1`                    | problem: `invalid (expected true or false)` |

## Enums

An enum is a string with one of its tag names, in the same case.

```zig
log_level: enum { debug, info, warn, err } = .info,
```

| You write                | You get                                                      |
| ------------------------ | ------------------------------------------------------------ |
| `"log_level": "warn"`    | `.warn`                                                      |
| `"log_level": "WARN"`    | problem: `invalid (expected one of: debug, info, warn, err)` |
| `"log_level": "warning"` | problem: `invalid (expected one of: debug, info, warn, err)` |
| `"log_level": 2`         | problem: `invalid (expected one of: debug, info, warn, err)` |

## Optional fields and null

`null` means "not set". It is the same as leaving the key out.

| Field                      | You write                     | You get                       |
| -------------------------- | ----------------------------- | ----------------------------- |
| `replica_url: ?[]const u8` | nothing                       | `null`                        |
| `replica_url: ?[]const u8` | `"replica_url": null`         | `null`                        |
| `replica_url: ?[]const u8` | `"replica_url": "pg://r/app"` | `"pg://r/app"`                |
| `timeout_s: ?u32 = 30`     | `"timeout_s": null`           | `30`: the default             |
| `port: u16 = 8080`         | `"port": null`                | `8080`: the default           |
| `url: []const u8`          | `"url": null`                 | problem: `url: missing (...)` |

> [!NOTE]
> When several sources are combined, `null` also erases what an earlier source
> set: the field falls back to its default. See
> [several_sources.md](several_sources.md#null-removes-a-value).

## Lists

A `[]const T` field takes an array. Each item is parsed like a field of type `T`.

```zig
ports: []const u16 = &.{80},
```

| You write              | You get                                                     |
| ---------------------- | ----------------------------------------------------------- |
| `"ports": [80, 443]`   | `{ 80, 443 }`                                               |
| `"ports": []`          | `{}`: an empty list, not the default                        |
| `"ports": [80, "443"]` | `{ 80, 443 }`: string items are parsed                      |
| `"ports": "80, 443"`   | `{ 80, 443 }`: a comma-separated string works too           |
| `"ports": [80, 70000]` | problem: `ports[1]: invalid (expected an integer 0..65535)` |
| `"ports": 80`          | problem: `ports: invalid (expected a list)`                 |

A problem in an item names it by index: `ports[1]`.

## Nested objects

A nested struct is an object. It can be partial: missing keys take their
defaults.

```zig
db: struct {
    url: []const u8,
    pool: struct { size: u8 = 4, max_idle: u8 = 2 },
},
```

| You write                                              | You get                                                 |
| ------------------------------------------------------ | ------------------------------------------------------- |
| `"db": { "url": "pg://h/app" }`                        | `pool` = `{ .size = 4, .max_idle = 2 }`                 |
| `"db": { "url": "pg://h/app", "pool": { "size": 8 } }` | `pool` = `{ .size = 8, .max_idle = 2 }`                 |
| `"db": { "pool": { "size": 8 } }`                      | problem: `db.url: missing (...)`                        |
| `"db": "pg://h/app"`                                   | problem: `db: invalid (expected a section with fields)` |

## Lists of objects

Only JSON can fill a list of structs. Each item is an object, with the struct's
defaults for the keys it leaves out:

```zig
upstreams: []const struct {
    host: []const u8,
    weight: u8 = 1,
} = &.{},
```

```json
{
  "upstreams": [
    { "host": "10.0.0.1:9000", "weight": 3 },
    { "host": "10.0.0.2:9000" }
  ]
}
```

gives two upstreams, the second with `weight = 1`. Problems inside an item
carry its index:

| You write                                           | You get                                                     |
| --------------------------------------------------- | ----------------------------------------------------------- |
| `[{ "host": "a" }, { "host": "b", "weight": 300 }]` | `upstreams[1].weight: invalid (expected an integer 0..255)` |
| `[{ "host": "a", "wieght": 3 }]`                    | `upstreams[0].wieght: unknown key (did you mean "weight"?)` |
| `[{ "weight": 3 }]`                                 | `upstreams[0].host: missing (...)`                          |

A struct used as a list item can have its own `pub fn validate`; it runs for
every item.

## Secrets

A `confy.Secret` field takes a string:

| You write                 | You get                                |
| ------------------------- | -------------------------------------- |
| `"password": "change-me"` | a secret; `expose()` returns the value |
| `"password": 12345`       | problem: `invalid (expected a string)` |

> [!WARNING]
> A JSON file is usually committed. Keep real secrets out of it: put them in a
> `.env` file or the environment, which override the JSON file when listed
> after it.

## Problems

confy reads the whole file and reports every problem at once. This file:

**`config.json`**

```json
{
  "nmae": "zefir-demo",
  "log_level": "verbose",
  "http": { "port": 70000 },
  "db": { "url": "postgres://db.internal:5432/app", "password": 12345 }
}
```

with the struct from [At a glance](#at-a-glance) gives:

```text
error(confy): 5 configuration problems:
  name: missing (set "name" in a config file)
  config.json:3: log_level: invalid (expected one of: debug, info, warn, err)
  config.json:4: http.port: invalid (expected an integer 0..65535)
  config.json:5: db.password: invalid (expected a string)
  config.json:2: nmae: unknown key (did you mean "name"?)
```

### Syntax errors

A file that isn't valid JSON is skipped as a whole, so the fields it would have
set are reported as missing too. A trailing comma on line 3:

```text
error(confy): 5 configuration problems:
  config.json:3: syntax error (invalid JSON)
  name: missing (set "name" in a config file)
  http.port: missing (set "http.port" in a config file)
  db.url: missing (set "db.url" in a config file)
  db.password: missing (set "db.password" in a config file)
```

### Every kind of problem

| Situation                     | Problem                                                             |
| ----------------------------- | ------------------------------------------------------------------- |
| the file doesn't exist        | `config.json: cannot read file (file not found)`                    |
| the file is larger than 1 MiB | `config.json: cannot read file (larger than 1048576 bytes)`         |
| not valid JSON                | `config.json:3: syntax error (invalid JSON)`                        |
| the top level isn't an object | `config.json:1: syntax error (expected an object at the top level)` |
| nesting deeper than 64 levels | `config.json:2: syntax error (nested deeper than 64 levels)`        |
| a key repeated in one object  | `config.json:3: port: duplicate key (first set on line 2)`          |
| a key that matches no field   | `config.json:2: nmae: unknown key (did you mean "name"?)`           |
| a value that doesn't fit      | `config.json:4: http.port: invalid (expected an integer 0..65535)`  |
| a required field nobody sets  | `name: missing (set "name" in a config file)`                       |

For a repeated key, the first value is kept.

## Limits

- Standard JSON only: no comments, no trailing commas.
- Objects and arrays nest at most 64 levels deep.
- Files are at most 1 MiB.

See also: [INI](ini.md) · [.env](dotenv.md) · [Environment](env.md) ·
[Several sources](several_sources.md) · [Overview](README.md)
