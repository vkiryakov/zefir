# INI

INI files are made for people: short lines, sections, and comments next to the
values they explain. Every value is text that confy parses into its field's type.
Use INI for hand-edited settings such as per-environment overrides.

```zig
.sources = &.{.ini("config.ini")},
```

## Contents

- [At a glance](#at-a-glance)
- [Lines](#lines)
- [Sections and nesting](#sections-and-nesting)
- [Values](#values)
- [Quotes](#quotes)
- [Comments](#comments)
- [Lists](#lists)
- [Keys](#keys)
- [Problems](#problems)
- [Limits](#limits)

## At a glance

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
};
```

**`config.ini`**

```ini
; Keys before the first section are top-level fields.
name = zefir-demo
debug = yes
log_level = debug

[http]
port = 8080
timeout_s = 2.5
allowed_origins = https://app.example.com, https://admin.example.com

[db]
url = "postgres://db.internal:5432/app"
password = change;me#now
pool.size = 8

[db.pool]
max_idle = 4
```

| Field                  | Value                                                      | Why                                 |
| ---------------------- | ---------------------------------------------------------- | ----------------------------------- |
| `name`                 | `"zefir-demo"`                                             | before any section: top level       |
| `debug`                | `true`                                                     | `yes` is true                       |
| `log_level`            | `.debug`                                                   |                                     |
| `http.port`            | `8080`                                                     |                                     |
| `http.timeout_s`       | `2.5`                                                      |                                     |
| `http.allowed_origins` | `"https://app.example.com"`, `"https://admin.example.com"` | comma-separated                     |
| `db.url`               | `"postgres://db.internal:5432/app"`                        | the quotes are removed              |
| `db.password`          | `"change;me#now"`                                          | `;` and `#` inside a value are kept |
| `db.replica_url`       | `null`                                                     | not in the file                     |
| `db.pool.size`         | `8`                                                        | dotted key in `[db]`                |
| `db.pool.max_idle`     | `4`                                                        | key in `[db.pool]`                  |

## Lines

| Line                       | Meaning                                         |
| -------------------------- | ----------------------------------------------- |
| `key = value`              | sets a field                                    |
| `[http]`                   | starts the section for the nested struct `http` |
| `[db.pool]`                | starts the section for `db.pool`                |
| `pool.size = 8`            | sets `pool.size` inside the current section     |
| `; comment` or `# comment` | a comment                                       |
| an empty line              | ignored                                         |

Spaces around `=` and at both ends of a line don't matter, and lines may end
with `\n` or `\r\n`.

## Sections and nesting

Keys before the first section belong to the top level. A section is a nested
struct, and a dotted section name goes deeper:

```ini
; Config.name
name = zefir-demo

; Config.db
[db]
url = postgres://db.internal:5432/app

; Config.db.pool
[db.pool]
size = 8
```

A dotted key reaches into nested structs from the current section, so these
three files set the same `db.pool.size`:

```ini
[db.pool]
size = 8
```

```ini
[db]
pool.size = 8
```

```ini
db.pool.size = 8
```

A section can be opened again later, and a section and dotted keys can fill
the same struct; the keys add up:

```ini
[db]
pool.size = 8

[http]
port = 8080

[db.pool]
max_idle = 4
```

gives `db.pool.size = 8` and `db.pool.max_idle = 4`.

## Values

A value is everything after the first `=`, trimmed. confy parses it into the
field's type:

| Field type     | You write                          | You get                                                      |
| -------------- | ---------------------------------- | ------------------------------------------------------------ |
| `[]const u8`   | `name = zefir demo`                | `"zefir demo"`                                               |
| `[]const u8`   | `url = pg://h/app?sslmode=require` | the whole URL, second `=` included                           |
| `[]const u8`   | `name =`                           | `""`                                                         |
| `u16`          | `port = 8080`                      | `8080`                                                       |
| `u16`          | `port = 70000`                     | problem: `invalid (expected an integer 0..65535)`            |
| `i8`           | `offset = -3`                      | `-3`                                                         |
| `f64`          | `ratio = 0.25`                     | `0.25`                                                       |
| `f64`          | `ratio = 1e3`                      | `1000`                                                       |
| `bool`         | `debug = true`, `yes`, `on`, `1`   | `true`                                                       |
| `bool`         | `debug = false`, `no`, `off`, `0`  | `false`                                                      |
| `bool`         | `debug = Yes`, `TRUE`              | `true`: any case                                             |
| `bool`         | `debug = enabled`                  | problem: `invalid (expected true or false)`                  |
| `enum`         | `log_level = warn`                 | `.warn`                                                      |
| `enum`         | `log_level = WARN`                 | problem: `invalid (expected one of: debug, info, warn, err)` |
| `confy.Secret` | `password = change-me`             | a secret                                                     |
| `?T`           | no key                             | `null`                                                       |

> [!NOTE]
> There is no way to write `null` in INI: leave the key out instead.

## Quotes

Quotes are optional. A value in matching double or single quotes loses them,
which keeps spaces at its edges. There are no escapes: a backslash is just a
backslash. The results are shown as Zig string literals:

| You write          | You get                                        |
| ------------------ | ---------------------------------------------- |
| `name = zefir`     | `"zefir"`                                      |
| `name = "zefir"`   | `"zefir"`                                      |
| `name = 'zefir'`   | `"zefir"`                                      |
| `prompt = "> "`    | `"> "`: the space after `>` is kept            |
| `path = "C:\temp"` | `"C:\\temp"`: the backslash stays as written   |
| `title = "zefir'`  | `"\"zefir'"`: quotes that don't match are kept |

## Comments

A line that starts with `;` or `#` is a comment. Anywhere else, `;` and `#` are
part of the value:

| You write                  | You get                                             |
| -------------------------- | --------------------------------------------------- |
| `; the port to listen on`  | a comment                                           |
| `# the port to listen on`  | a comment                                           |
| `password = change;me#now` | `"change;me#now"`                                   |
| `port = 8080 ; main port`  | the value `8080 ; main port`: problem, not a number |

> [!WARNING]
> Comments after a value are not supported. Put the comment on the line above.

## Lists

A `[]const T` field takes comma-separated values; spaces around the items are
trimmed.

| Field                | You write                                | You get                                                     |
| -------------------- | ---------------------------------------- | ----------------------------------------------------------- |
| `[]const u16`        | `ports = 80, 443`                        | `{ 80, 443 }`                                               |
| `[]const u16`        | `ports = 80`                             | `{ 80 }`                                                    |
| `[]const u16`        | `ports =`                                | `{}`                                                        |
| `[]const u16`        | `ports = 80, http`                       | problem: `ports[1]: invalid (expected an integer 0..65535)` |
| `[]const []const u8` | `origins = https://a.com, https://b.com` | two strings                                                 |

An item can't contain a comma. Lists of structs can't be written in INI:
`upstreams = a, b` and a `[upstreams]` section are both
`invalid (expected a list)`. Put them in a [JSON](json.md#lists-of-objects) file.

## Keys

Keys and section names are field names, exactly, including case. They are made
of letters, digits, `_` and `-`, with dots between nested names.

| You write     | You get                                                                    |
| ------------- | -------------------------------------------------------------------------- |
| `port = 1`    | sets `port`                                                                |
| `Port = 1`    | problem: `Port: unknown key (did you mean "port"?)`                        |
| `prot = 1`    | problem: `prot: unknown key (did you mean "port"?)`                        |
| `bad key = 1` | problem: `syntax error (expected a key like port or pool.size before '=')` |

A key that matches no field is a problem, so a typo never leaves a field at
its default unnoticed. A key set twice is a problem too.

## Problems

A line with a syntax error is skipped, and the rest of the file is still read,
so one run reports everything. This file:

**`config.ini`**

```ini
name = zefir-demo
log_level = verbose

[http]
port = 8080 ; main port
port = 8081

[db]
url = postgres://db.internal:5432/app
password = change-me
pool.size = 300
replica_ur = postgres://replica.internal:5432/app
```

with the struct from [At a glance](#at-a-glance) gives:

```text
error(confy): 5 configuration problems:
  config.ini:6: http.port: duplicate key (first set on line 5)
  config.ini:2: log_level: invalid (expected one of: debug, info, warn, err)
  config.ini:5: http.port: invalid (expected an integer 0..65535)
  config.ini:11: db.pool.size: invalid (expected an integer 0..255)
  config.ini:12: db.replica_ur: unknown key (did you mean "replica_url"?)
```

### Every kind of problem

| Line or situation             | Problem                                                           |
| ----------------------------- | ----------------------------------------------------------------- |
| the file doesn't exist        | `config.ini: cannot read file (file not found)`                   |
| `[db`                         | `syntax error (expected ']' at the end of the section name)`      |
| `[my db]`, `[]`, `[db..pool]` | `syntax error (expected a section name like [db] or [db.pool])`   |
| `just text`                   | `syntax error (expected key = value)`                             |
| `bad key = 1`                 | `syntax error (expected a key like port or pool.size before '=')` |
| `host` set twice in `[db]`    | `db.host: duplicate key (first set on line 3)`                    |
| `[db]` after `db = x`         | `db: duplicate key (line 1 already sets it to a value)`           |
| a key that matches no field   | `db.replica_ur: unknown key (did you mean "replica_url"?)`        |
| a value that doesn't fit      | `http.port: invalid (expected an integer 0..65535)`               |
| a required field nobody sets  | `db.url: missing (set "db.url" in a config file)`                 |

For a repeated key, the first value is kept.

## Limits

- No escapes in values, and no comments after a value.
- No `null`: leave the key out.
- No lists of structs.
- Files are at most 1 MiB.

See also: [JSON](json.md) · [.env](dotenv.md) · [Environment](env.md) ·
[Several sources](several_sources.md) · [Overview](README.md)
