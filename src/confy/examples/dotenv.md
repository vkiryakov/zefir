# .env files

A `.env` file holds environment variables, one `NAME=value` per line. It is the
place for secrets and machine-specific values that never go into version
control, and for personal overrides of the shared configuration.

```zig
.env_prefix = "APP_",
.sources = &.{ .env(".env"), .env(".env.local") },
```

## Contents

- [At a glance](#at-a-glance)
- [Variable names](#variable-names)
- [Lines](#lines)
- [Quotes and escapes](#quotes-and-escapes)
- [Comments](#comments)
- [Values](#values)
- [Lists](#lists)
- [Missing and optional files](#missing-and-optional-files)
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

**`.env`**

```sh
APP_NAME=zefir-demo
export APP_DEBUG=true
APP_LOG_LEVEL=debug

APP_HTTP_PORT=8080
APP_HTTP_TIMEOUT_S=2.5 # seconds
APP_HTTP_ALLOWED_ORIGINS=https://app.example.com, https://admin.example.com

APP_DB_URL="postgres://db.internal:5432/app"
APP_DB_PASSWORD='change#me'
APP_DB_POOL_SIZE=8

# Not a field of Config: ignored.
DATABASE_URL=postgres://localhost:5432/migrations
```

| Field                  | Value                                                      | Why                                  |
| ---------------------- | ---------------------------------------------------------- | ------------------------------------ |
| `name`                 | `"zefir-demo"`                                             |                                      |
| `debug`                | `true`                                                     | `export` is accepted                 |
| `log_level`            | `.debug`                                                   |                                      |
| `http.port`            | `8080`                                                     |                                      |
| `http.timeout_s`       | `2.5`                                                      | the comment after a space is dropped |
| `http.allowed_origins` | `"https://app.example.com"`, `"https://admin.example.com"` | comma-separated                      |
| `db.url`               | `"postgres://db.internal:5432/app"`                        | the quotes are removed               |
| `db.password`          | `"change#me"`                                              | single quotes keep `#`               |
| `db.replica_url`       | `null`                                                     | `APP_DB_REPLICA_URL` isn't set       |
| `db.pool.size`         | `8`                                                        |                                      |
| `db.pool.max_idle`     | `2`                                                        | not set: the default                 |

## Variable names

confy doesn't guess which variables belong to which fields: it computes the
name of every field and looks exactly those names up. A name is
`env_prefix`, then the field names upper-cased and joined with `_`:

| Field                  | `.env_prefix = "APP_"`     | `.env_prefix = ""`     |
| ---------------------- | -------------------------- | ---------------------- |
| `name`                 | `APP_NAME`                 | `NAME`                 |
| `http.port`            | `APP_HTTP_PORT`            | `HTTP_PORT`            |
| `http.allowed_origins` | `APP_HTTP_ALLOWED_ORIGINS` | `HTTP_ALLOWED_ORIGINS` |
| `db.pool.max_idle`     | `APP_DB_POOL_MAX_IDLE`     | `DB_POOL_MAX_IDLE`     |

- The prefix is put in front as is: write `"APP_"`, not `"APP"`, or the names
  become `APPHTTP_PORT`.
- Every other variable in the file is ignored. The file can hold settings for
  other tools, such as `DATABASE_URL` for migrations.
- Two fields that would get the same name, like `db_port` and `db.port`, are a
  compile error, so a name always means exactly one field.

> [!WARNING]
> A misspelled variable is ignored too, without a problem:
> `APP_HTTP_PROT=9090` leaves `http.port` at its previous value. Check names
> against your fields when a value doesn't seem to apply.

## Lines

| Line                | Meaning                                             |
| ------------------- | --------------------------------------------------- |
| `NAME=value`        | sets a variable                                     |
| `NAME = value`      | the same: spaces around `=` don't matter            |
| `export NAME=value` | the same: `export` is accepted, as in shell scripts |
| `NAME=`             | an empty value                                      |
| `# comment`         | a comment                                           |
| an empty line       | ignored                                             |

Names are letters, digits and `_`, and don't start with a digit. Lines may end
with `\n` or `\r\n`.

## Quotes and escapes

| You write           | You get (as a Zig string) | Why                                             |
| ------------------- | ------------------------- | ----------------------------------------------- |
| `NAME=zefir demo`   | `"zefir demo"`            | unquoted: up to the end of the line, trimmed    |
| `NAME="zefir demo"` | `"zefir demo"`            |                                                 |
| `NAME='zefir demo'` | `"zefir demo"`            |                                                 |
| `NAME=" padded "`   | `" padded "`              | quotes keep spaces at the edges                 |
| `NAME="a\tb"`       | `"a\tb"`, with a real tab | double quotes unescape `\n` `\t` `\r` `\"` `\\` |
| `NAME='a\tb'`       | `"a\\tb"`                 | single quotes keep the text as is               |
| `NAME=a\tb`         | `"a\\tb"`                 | no escapes without quotes                       |
| `NAME="say \"hi\""` | `"say \"hi\""`            |                                                 |
| `NAME="a\qb"`       | `"a\\qb"`                 | an unknown escape stays as written              |
| `NAME=${HOME}/data` | `"${HOME}/data"`          | variables are not expanded                      |

## Comments

| You write             | You get          | Why                                     |
| --------------------- | ---------------- | --------------------------------------- |
| `# a comment`         | nothing          | a comment line                          |
| `NAME=value # note`   | `"value"`        | `#` after a space starts a comment      |
| `NAME=value#tag`      | `"value#tag"`    | `#` without a space before it is kept   |
| `NAME="value # note"` | `"value # note"` | inside quotes, `#` is part of the value |
| `NAME='change#me'`    | `"change#me"`    |                                         |

> [!TIP]
> Quote passwords and tokens. Then `#`, spaces and quotes inside them can
> never be mistaken for syntax.

## Values

Every value is text, which confy parses into the field's type:

| Field type     | You write                                    | You get                                                      |
| -------------- | -------------------------------------------- | ------------------------------------------------------------ |
| `[]const u8`   | `APP_NAME=zefir`                             | `"zefir"`                                                    |
| `[]const u8`   | `APP_NAME=`                                  | `""`                                                         |
| `u16`          | `APP_HTTP_PORT=8080`                         | `8080`                                                       |
| `u16`          | `APP_HTTP_PORT=80 80`                        | problem: `invalid (expected an integer 0..65535)`            |
| `f32`          | `APP_HTTP_TIMEOUT_S=2.5`                     | `2.5`                                                        |
| `bool`         | `APP_DEBUG=true`, `yes`, `on`, `1`, any case | `true`                                                       |
| `bool`         | `APP_DEBUG=false`, `no`, `off`, `0`          | `false`                                                      |
| `bool`         | `APP_DEBUG=maybe`                            | problem: `invalid (expected true or false)`                  |
| `enum`         | `APP_LOG_LEVEL=warn`                         | `.warn`                                                      |
| `enum`         | `APP_LOG_LEVEL=WARN`                         | problem: `invalid (expected one of: debug, info, warn, err)` |
| `confy.Secret` | `APP_DB_PASSWORD='change-me'`                | a secret                                                     |
| `?T`           | no variable                                  | `null`                                                       |

There is no way to write `null`: an empty value is an empty string. To leave a
field unset, leave the variable out.

## Lists

A `[]const T` field takes comma-separated values; spaces around the items are
trimmed:

| You write                                               | You get                                           |
| ------------------------------------------------------- | ------------------------------------------------- |
| `APP_HTTP_ALLOWED_ORIGINS=https://a.com,https://b.com`  | two strings                                       |
| `APP_HTTP_ALLOWED_ORIGINS=https://a.com, https://b.com` | two strings                                       |
| `APP_HTTP_ALLOWED_ORIGINS=`                             | `{}`: an empty list                               |
| `APP_PORTS=80, http`                                    | problem: `invalid (expected an integer 0..65535)` |

An item can't contain a comma, and a list of structs can't be written as a
variable; put it in a [JSON](json.md#lists-of-objects) file.

## Missing and optional files

Unlike JSON and INI files, a missing `.env` file is skipped without a problem.
That makes optional layers free to list:

```zig
.sources = &.{
    .env(".env"),       // shared by the team, without secrets
    .env(".env.local"), // personal overrides, in .gitignore
},
```

Each file overrides the ones before it, so a variable in `.env.local` wins over
the same variable in `.env`. A variable set twice in the same file is a
problem; in two different files, the later one wins.

A file that exists but can't be read, such as a directory named `.env`, is
still a problem.

## Problems

A line with a syntax error is skipped, and the rest of the file is still read.
This file:

**`.env`**

```sh
APP_NAME=zefir-demo
APP_HTTP_PORT=80 80
APP_DEBUG=maybe
APP_DB_URL="postgres://db.internal:5432/app
APP_NAME=other
not a variable
```

with the struct from [At a glance](#at-a-glance) and `.env_prefix = "APP_"` gives:

```text
error(confy): 7 configuration problems:
  .env:4: APP_DB_URL: syntax error (unterminated quote)
  .env:5: APP_NAME: duplicate key (first set on line 1)
  .env:6: syntax error (expected KEY=value)
  .env:3: APP_DEBUG: invalid (expected true or false)
  .env:2: APP_HTTP_PORT: invalid (expected an integer 0..65535)
  db.url: missing (set APP_DB_URL)
  db.password: missing (set APP_DB_PASSWORD)
```

Problems with a value name the variable, not the field, because that is what
you will look for in the file. `db.url` is missing because its line was
skipped.

### Every kind of problem

| Line or situation              | Problem                                                            |
| ------------------------------ | ------------------------------------------------------------------ |
| `not a variable`               | `syntax error (expected KEY=value)`                                |
| `MY-KEY=1`, `9LIVES=1`, `=1`   | `syntax error (expected a variable name like APP_PORT before '=')` |
| `APP_DB_URL="no closing quote` | `APP_DB_URL: syntax error (unterminated quote)`                    |
| a variable set twice           | `APP_NAME: duplicate key (first set on line 1)`                    |
| a value that doesn't fit       | `APP_DEBUG: invalid (expected true or false)`                      |
| a required field nobody sets   | `db.url: missing (set APP_DB_URL)`                                 |
| the file can't be read         | `.env: cannot read file (...)`                                     |

## Limits

- A value can't span several lines.
- `${VAR}` is not expanded.
- Misspelled variables are ignored, not reported.
- No `null`, and no lists of structs.
- Files are at most 1 MiB.

See also: [JSON](json.md) · [INI](ini.md) · [Environment](env.md) ·
[Several sources](several_sources.md) · [Overview](README.md)
