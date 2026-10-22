# jwt

**Tokens that say who calls, signed by your own services.** When Ann signs
in to a shop, its orders service checks her once and gives her a *token*: a
short text that says "this is user-7, a buyer, until 12:15", signed with
the key of orders. Ann's app sends the token with every request. Every
route of orders, and every other service of the shop, checks the
signature, the time and whom the token is for, and knows who calls,
without a store of sessions and without asking orders. zefir-jwt signs and
checks such tokens: JSON Web Tokens (RFC 7519) in the compact form of JWS
(RFC 7515), with HS256, HS384, HS512, ES256, ES384 and EdDSA. The keys come
from the settings of a service and change by their id, `kid`; the claims of
your application arrive in a struct of your own, checked by the rules of
zefir-validator; and every reason to refuse a token has an error of its
own. The middleware of zefir-http and the authenticator of zefir-rpc that
check tokens are code of your application, and this guide shows both.

> [!IMPORTANT]
> **Not implemented yet (TODO):**
>
> - **Tokens of other issuers.** Only tokens that zefir services sign
>   themselves: tokens of Keycloak, Auth0, Google and other providers are
>   not checked. Even with the right key, an ES256 or ES384 token that
>   another library signed passes only when its signature has the low s
>   that zefir writes (see [Security](#security)): about half of such
>   tokens are refused, the example of RFC 7515 A.3 among them.
> - **JWKS by URL, OIDC discovery and RSA.** No key set is fetched or
>   refreshed, no HTTPS request goes out, and RS256 or PS256 is never
>   verified: zefir cannot sign with RSA, so only other providers would
>   need it.
> - **CORS, CSRF, passwords, refresh tokens, sessions, permissions, TOTP,
>   WebAuthn, rate limits and TLS of transports.** None of them is a part
>   of zefir-jwt.
> - **OAuth 2.0 and OpenID Connect flows.** No token is fetched from an
>   authorization server, and no sign-in flow runs.
> - **Ready-made middleware.** No middleware of zefir-http, authenticator
>   of zefir-rpc or adapter module ships with zefir-jwt: this guide shows
>   both as code of the application.
> - **JWE and nested tokens.** Tokens are signed, not encrypted, and a
>   token inside a token is refused.
> - **JWK and JWKS.** No key is read as a JWK, a service does not publish
>   its keys at `/.well-known/jwks.json`, and there is no thumbprint (RFC
>   7638): keys come from the settings.
> - **Certificates.** No key from an X.509 certificate (`x5c`, a PEM
>   `CERTIFICATE`), and no check of a chain.
> - **Encrypted PEM and OpenSSH keys.** Decrypt a key with `openssl` first.
> - **Export of private keys.** `SigningKey.generate` makes a key for
>   tests, which cannot be written out as PEM.
> - **ES512 (P-521) and Ed448**, which Zig's std does not have; and the
>   name "Ed25519" of RFC 9864 for EdDSA.
> - **Other forms of JWS.** The JSON serialization, and detached and
>   unencoded payloads (RFC 7797): a token is compact only.
> - **Revocation and replay.** A token lives until it expires: no store of
>   `jti` remembers the tokens revoked or used.
> - **Several issuers in one verifier.** A verifier trusts one issuer; the
>   tokens of several issuers take a verifier each.
> - **Claims of any shape.** No map of arbitrary keys and no field of "any
>   JSON" in a struct of claims.
> - **Transforms of claims.** Claims arrive as they were signed, so `v.trim`
>   and the other transforms of zefir-validator never run on them: only
>   their rules do.

## Contents

- [How a token is checked](#how-a-token-is-checked)
- [Installation](#installation)
- [jwt in a minute](#jwt-in-a-minute)
- [Claims](#claims)
- [Keys](#keys)
- [Signing in](#signing-in)
- [Errors](#errors)
- [HTTP](#http)
- [RPC](#rpc)
- [Tests](#tests)
- [Security](#security)
- [Limits](#limits)

## How a token is checked

This guide follows one shop of two services. **Orders**, a service of
zefir-http, signs Ann in at `POST /api/login` and gives her a token for 15
minutes, signed with its Ed25519 key. Its routes, such as
`GET /api/orders`, check that token in the middleware `JwtAuth`.
**Billing**, a service of zefir-rpc, takes the same token when Ann pays:
the token names both services as its audience. Billing checks it in its authenticator,
`JwtAuthenticator`, with the public key of orders, which it has in its own
settings. Billing can check tokens, but it cannot make one: only orders
has the private key.

```mermaid
flowchart LR
    app["Ann's app"] -->|"POST /api/login"| login
    app -->|"GET /api/orders<br/>Authorization: Bearer eyJ…"| auth
    subgraph orders["orders: zefir-http"]
        login["LoginController<br/>jwt.Signer, the private key"]
        auth["JwtAuth<br/>jwt.Verifier"] --> list["OrdersController"]
    end
    orders -->|"billing.v1.charge<br/>with Ann's token"| check
    subgraph billing["billing: zefir-rpc"]
        check["JwtAuthenticator<br/>jwt.Verifier, the public key"] --> charge["BillingHandler"]
    end
```

A token is three parts of base64url joined by dots: a header, a payload
and a signature. Here is one that orders gave Ann:

```text
eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCIsImtpZCI6IjIwMjYtMTAifQ.eyJpc3MiOiJvcmRlcnMiLCJzdWIiOiJ1c2VyLTciLCJhdWQiOlsib3JkZXJzIiwiYmlsbGluZyJdLCJpYXQiOjE3OTI2NzA0MDAsImV4cCI6MTc5MjY3MTMwMCwicm9sZXMiOlsiYnV5ZXIiXX0.O2qCht2ma0AURVamIEnpQNz-YMc9weaHZYs3l4VaZPttriA3wGcDmVX_17-V96HjT5p4BITZ0TrWVU7pHtYKCg
```

Its header and its payload are JSON:

```json
{"alg":"EdDSA","typ":"JWT","kid":"2026-10"}
{"iss":"orders","sub":"user-7","aud":["orders","billing"],"iat":1792670400,"exp":1792671300,"roles":["buyer"]}
```

- **The header** says how the token is signed: the algorithm `alg`, the
  type of the token `typ`, and `kid`, the id of the key that signed it.
- **The payload** holds the *claims*: who issued the token (`iss`), whom
  it is about (`sub`), the services it is meant for (`aud`), when it was
  issued (`iat`) and when it expires (`exp`), in seconds of Unix time; and
  the claims of the application, here `roles`.
- **The signature** covers the first two parts. Without the key of orders
  nobody can change a claim and sign again, but anybody who has the token
  can read it: base64url is no encryption, so a token never carries a
  secret.

`jwt.Verifier.verify` checks a token step by step, and stops at the first
step that fails, with an error of its own:

```mermaid
flowchart TD
    token["the token, from Authorization: Bearer"] --> parts["parts: at most 8 KiB, three of them,<br/>strict base64url"]
    parts --> header["header: alg, crit, cty, typ"]
    header --> key["key: the verifier's key of this kid,<br/>bound to the algorithm alg names"]
    key --> signature["signature, by that key"]
    signature --> registered["registered claims:<br/>iss, aud, exp, nbf, iat"]
    registered --> claims["your claims, in your struct"]
    claims --> rules["the rules of field_rules"]
    rules --> verified["jwt.Verified(Claims)"]
    parts -.-> e1["TokenTooLarge, Malformed"]
    header -.-> e2["UnsupportedAlgorithm,<br/>UnsupportedHeader, WrongType"]
    key -.-> e3["UnknownKey, AlgorithmMismatch"]
    signature -.-> e4["BadSignature"]
    registered -.-> e5["MissingClaim, WrongIssuer, WrongAudience,<br/>Expired, NotYetValid, InvalidClaims"]
    claims -.-> e6["InvalidClaims"]
    rules -.-> e7["ClaimsRejected"]
```

The payload is read only after the signature has passed: JSON that only
the holder of a key could write. The key comes from the verifier, never
from the token, and the algorithm comes from the key: a token cannot ask
for a weaker check.

## Installation

Add Zefir to your `build.zig.zon`; jwt ships since v0.10.0:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#dev
```

This guide is on the `dev` branch, so the command fetches its latest commit; `--save` pins that commit. For the latest release, v0.10.0, fetch `#v0.10.0` instead.

Then import the modules in `build.zig`. The orders service of this guide
signs and checks tokens with jwt, declares the rules of its claims with
validator, reads its settings with confy, logs with log, and serves with
http; billing takes rpc instead of http:

```zig
// build.zig of the orders service
const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
const exe = b.addExecutable(.{
    .name = "orders",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jwt", .module = zefir.module("zefir-jwt") },
            .{ .name = "validator", .module = zefir.module("zefir-validator") },
            .{ .name = "confy", .module = zefir.module("zefir-confy") },
            .{ .name = "log", .module = zefir.module("zefir-log") },
            .{ .name = "http", .module = zefir.module("zefir-http") },
        },
    }),
});
b.installArtifact(exe);
b.step("run", "Run the service").dependOn(&b.addRunArtifact(exe).step);
```

> [!TIP]
> jwt is also part of the umbrella module: with `zefir.module("zefir")`
> imported as `zefir`, it is `@import("zefir").jwt`. zefir-jwt itself
> imports only validator, and nothing outside Zefir. It has no network
> code, no tasks and no global state, but for the clock of tests in
> `jwt.testing`.

## jwt in a minute

A service needs a key first. Make one with `openssl`, an Ed25519 key in a
PEM file:

```sh
openssl genpkey -algorithm ed25519 -out orders.pem
```

A whole program: it reads the key from its settings, signs a token for
user-7, verifies it as a route of orders would, and shows how billing
refuses it, since the token is not meant for billing.

```zig
const std = @import("std");
const confy = @import("confy");
const jwt = @import("jwt");
const log = @import("log");
const v = @import("validator");

// The settings: the key of the service and its id.
const Config = struct {
    auth: struct {
        // APP_AUTH_SIGNING_KEY: an Ed25519 key in PEM, as openssl writes it.
        signing_key: confy.Secret,
        // APP_AUTH_KEY_ID: its id, the "kid" of every token it signs.
        key_id: []const u8,
    },
};

// The claims of the tokens, besides those that jwt sets and checks itself.
const Claims = struct {
    roles: []const []const u8 = &.{},

    pub const field_rules = .{ .roles = v.maxItems(16) };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();

    // The key signs; its public half, verificationKey(), verifies.
    var key: jwt.SigningKey = try .fromPem(.EdDSA, config.auth.signing_key.expose(), .{ .id = config.auth.key_id });
    defer key.deinit();
    logger.info("Key loaded", .{ .key = key, .algorithm = key.algorithm, .kid = key.id() });
    const signer: jwt.Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const keys = [_]jwt.Key{key.verificationKey()};
    const verifier: jwt.Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"} });

    // The token of user-7, a buyer, as a sign-in gives it: for 15 minutes.
    const token = try signer.sign(Claims, io, gpa, &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
    defer gpa.free(token);

    // A route checks it; what it gives lives in the arena of the request.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const verified = try verifier.verify(Claims, io, arena.allocator(), token, .{});
    logger.info("Token verified", .{
        .subject = verified.registered.subject,
        .roles = verified.claims.roles,
        // jwt.Signer writes "iat" into every token.
        .lifetime_s = verified.registered.expires_at - verified.registered.issued_at.?,
    });

    // The service billing is not among the audiences of the token.
    const billing: jwt.Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"billing"} });
    var details: jwt.Details = .{};
    if (billing.verify(Claims, io, arena.allocator(), token, .{ .details = &details })) |_| {
        logger.err("Token taken by billing", .{});
    } else |err| {
        logger.warn("Token refused", .{ .reason = err, .claim = details.claim, .description = jwt.describe(err) });
    }
}
```

The key goes into the environment as it is, line breaks and all:

```text
$ APP_AUTH_SIGNING_KEY="$(cat orders.pem)" APP_AUTH_KEY_ID=2026-10 zig build run
2026-10-22T09:41:07.415Z INFO  Key loaded key=[REDACTED] algorithm=EdDSA kid=2026-10
2026-10-22T09:41:07.416Z INFO  Token verified subject=user-7 roles=[buyer] lifetime_s=900
2026-10-22T09:41:07.416Z WARN  Token refused reason=WrongAudience claim=aud description="the token is not meant for this service"
```

- **The key is a secret.** confy reads it as `confy.Secret`, and the log
  writes the key itself as `[REDACTED]`: neither ever prints its bytes.
  `deinit` wipes the key from memory.
- **The signer sets the registered claims.** `iss` and `aud` come from its
  options, `iat` is now, and `exp` is now plus its lifetime, 15 minutes
  unless you choose another; `sub` comes with the call. Your claims follow,
  from your struct.
- **The verifier checks all of them.** A token passes only with the
  verifier's issuer, one of its audiences and a time that has not passed;
  then its claims fill your struct, and their rules are checked.
- **A refusal says why.** Every reason has an error of its own, and
  `jwt.Details` names the claim at fault, here `aud`: something to log.
  `jwt.describe` gives a short text that the answer to a client may carry.

## Claims

A token carries two kinds of claims.

**The registered claims** of RFC 7519 are jwt's own. `jwt.Signer` writes
them, `jwt.Verifier` checks them, and `verified.registered`, a
`jwt.Registered`, gives them to you:

| Claim | In `jwt.Registered` | What the verifier holds it to | Error |
| --- | --- | --- | --- |
| `iss` | `issuer` | required; equal to the verifier's `issuer`, byte for byte | `MissingClaim`, `WrongIssuer` |
| `aud` | `audience` | required; a string or a non-empty array of them, one of which is among the verifier's `audiences` | `MissingClaim`, `WrongAudience` |
| `exp` | `expires_at` | required; the token passes while now < `exp` + leeway | `MissingClaim`, `Expired` |
| `nbf` | `not_before` | if present: `nbf` ≤ now + leeway | `NotYetValid` |
| `iat` | `issued_at` | if present: `iat` ≤ now + leeway | `NotYetValid` |
| `sub`, `jti` | `subject`, `id` | if present, a string | — |

They are checked in this order, so a token of another issuer is
`WrongIssuer` even when it has expired too. A claim of the wrong type,
such as `"exp":"tomorrow"`, is `InvalidClaims`. A time is a number of
seconds of Unix time, from 0 to 253402300799, the end of the year 9999; a
fraction is rounded the safe way, `exp` down and `nbf` and `iat` up. The
leeway is 60 seconds unless the verifier says otherwise, for the clocks of
two services that disagree a little.

**Your claims** are a struct of your own, such as the claims of orders in
`auth.zig`:

```zig
/// The claims of the tokens of orders, besides the registered ones that
/// jwt sets and checks itself.
pub const Claims = struct {
    /// What the user may do, such as "buyer".
    roles: []const []const u8 = &.{},

    pub const field_rules = .{ .roles = v.maxItems(16) };
};
```

`verify(Claims, …)` fills it from the payload, and `sign(Claims, …)` writes
it into a token; `void` instead of a struct means that the registered
claims are enough. A field takes one of these types:

| Field | From JSON |
| --- | --- |
| `bool` | `true`, `false` |
| an integer of up to 64 bits | a number without a fraction or an exponent, within the type |
| `f32`, `f64` | a number, finite |
| an enum | a string, the name of a variant |
| `[]const u8` | a string |
| `[]const T` | an array |
| `?T` | `null`, or the claim absent |
| a struct | an object, with its own names and rules |

- **Names.** A field's claim is its Zig name, or the name of `v.rename`, as
  for the fields of a DTO in zefir-http and zefir-rpc. A name that is a URL,
  as RFC 7519 suggests for claims that must not collide with others', goes
  into `pub const claim_names = .{ .is_root = "http://example.com/is_root" };`.
- **Required or not.** A field without a default and not `?T` must be in
  the token, else `InvalidClaims`. A field with a default keeps it, and
  `?T` without one is `null`.
- **Unknown claims are skipped**, so a token of a newer version of a
  service, with claims an older one does not know, still passes.
- **Rules.** Once the struct is filled, its `field_rules` are checked, as
  zefir-validator checks a DTO: `v.maxItems(16)` refuses a token with 17
  roles, with `ClaimsRejected`. The transforms of validator, such as
  `v.trim`, never run: claims arrive as they were signed.
- **The registered names are jwt's.** A field named `exp` or renamed to
  `iss` at the top level of the struct does not compile, and neither does
  a type the table does not have. Every such message starts with `jwt:`,
  and names the field:

```text
error: jwt: auth.Claims.exp: "exp" is a registered claim, which jwt sets and checks itself (jwt.Registered); remove the field or give it another claim name
error: jwt: auth.Claims.since: [3]u8 is not a claim type; a claim is bool, an integer, f32, f64, an enum, []const u8 or a struct, alone, as ?T or as []const T
```

`verify` and `sign` check the struct when they compile; a package that only
declares claims checks them in a test of its own with
`comptime jwt.assertClaims(Claims);`.

A route reads both kinds from the result of `verify`, as `minute.zig` does:

```zig
const verified = try verifier.verify(Claims, io, arena.allocator(), token, .{});
logger.info("Token verified", .{
    .subject = verified.registered.subject,
    .roles = verified.claims.roles,
```

Everything in the result lives in the arena given to `verify`, the arena
of the request, and nothing in it points into the token.

## Keys

A key is bound to one algorithm, and the algorithm decides who can make
tokens:

- **HMAC (HS256, HS384, HS512)** signs and verifies with one secret. It is
  enough when one service makes its tokens and checks them alone. Every
  service that checks such tokens must hold the secret, and with it can
  make tokens too.
- **EdDSA (Ed25519), ES256 (P-256) and ES384 (P-384)** sign with a private
  key and verify with its public key. The services that only check tokens
  hold the public key, and cannot make a token with it. That is the case of
  orders and billing, so this guide signs with EdDSA: its keys are small,
  and it is fast.

Make the keys with `openssl`:

```sh
openssl genpkey -algorithm ed25519 -out orders.pem               # EdDSA: the private key of orders
openssl pkey -in orders.pem -pubout -out orders.pub.pem          # its public key, for billing
openssl ecparam -name prime256v1 -genkey -noout -out es256.pem   # ES256; secp384r1 for ES384
openssl rand -base64 48                                          # an HMAC secret of 64 characters
```

The files are PEM: a block of base64 between two marker lines. The runs
of this guide use a sample key of orders, whose public key is:

```text
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA1rQM3tcZwaeBG73FtMkSgozKMFHlEkT24K1KGN0rUAY=
-----END PUBLIC KEY-----
```

> [!WARNING]
> This sample key is for reading the guide alone. Its private half is
> published in this repository, in `cases.zig`, so anybody can sign tokens
> with it: never let a service trust it. Make the keys of your services
> with the commands above.

Each kind of key loads with a function of its own, with the algorithm you
name; a key of another curve than that algorithm's fails at once, when the
service starts, instead of turning into tokens of another algorithm:

| What | `jwt.SigningKey`, which signs | `jwt.Key`, which verifies |
| --- | --- | --- |
| an HMAC secret: 32, 48 or 64 bytes at least, for HS256, HS384 and HS512 | `.hmac(.HS256, secret, .{})` | `.hmac(.HS256, secret, .{})` |
| a private key in PEM: `PRIVATE KEY` (PKCS#8) or `EC PRIVATE KEY` (SEC1) | `.fromPem(.EdDSA, pem, .{})` | — |
| a public key in PEM: `PUBLIC KEY` (SPKI) | — | `.fromPem(.EdDSA, pem, .{})` |
| the same in DER | `.fromDer(…)` | `.fromDer(…)` |

The public half of a signing key is `signing_key.verificationKey()`; of an
HMAC key, the same secret. A key that does not load says why, with an error
of `jwt.KeyError`: `InvalidKey` (not a key of the expected form),
`UnsupportedKey` (RSA, P-521, Ed448, an encrypted PEM, a certificate, a key
of OpenSSH), `WeakKey` (a secret too short), `KeyAlgorithmMismatch` (a key
of another algorithm) and `InvalidKeyId`.

**A PEM in the settings.** The environment takes it as the file has it:
`APP_AUTH_SIGNING_KEY="$(cat orders.pem)"`. A `.env` file of confy holds
it on one line, with `\n` inside double quotes, which confy turns into
line breaks:

```sh
APP_AUTH_ORDERS_KEY="-----BEGIN PUBLIC KEY-----\n<the base64 line of orders.pub.pem>\n-----END PUBLIC KEY-----"
```

The programs of this guide read the environment alone, `.osEnv()`: a
service that keeps its keys in a `.env` file lists that file among its
sources too, `.sources = &.{ .env(".env"), .osEnv() }`, and the
environment still wins over it. jwt reads a PEM with CRLF, indented, or
on one line with spaces between its parts as well. A literal backslash
and `n` between the lines, which an environment variable gets when the
`\n` was never turned into line breaks, is `InvalidKey`. Where a key
should live, and where not, is told in [Security](#security).

**A key is a secret value.** `jwt.Key` and `jwt.SigningKey` are plain
values of a fixed size, without heap memory, so a verifier takes its keys
as an array. A copy of a private key or of an HMAC secret is a secret too:
keep a key in one place, pass a pointer to it, and call `deinit`, which
wipes it, when it is no longer used:

```zig
var signing_key: jwt.SigningKey = try .fromPem(.EdDSA, config.auth.signing_key.expose(), .{ .id = config.auth.key_id });
defer signing_key.deinit();
```

zefir-log writes a key as `[REDACTED]`, and `{f}` prints only its algorithm
and id, `jwt.SigningKey(EdDSA, kid "2026-10")`.

**`kid` and rotation.** A key has an id, which you choose, such as the
month it was made: "2026-10". The signer writes it into every token as
`kid`, and a verifier picks the key of that id among its keys; a verifier
with one key may take tokens without `kid`.

While the key of orders changes, every service that checks its tokens,
orders itself among them, takes one more public key from its settings:
the *other key*, `APP_AUTH_OTHER_KEY` and `APP_AUTH_OTHER_KEY_ID`. It holds
the next key before orders switches to it, and the previous one after. To
change the key of orders, which may run as several replicas:

1. Make the new key pair, and give its public key as the other key to
   every service that checks the tokens of orders: billing, and orders
   itself. Restart them: their verifiers take the tokens of both keys,
   while orders still signs with the old one.
2. Switch orders to the new private key, `APP_AUTH_SIGNING_KEY` and
   `APP_AUTH_KEY_ID`, with the old public key as its other key now. New
   tokens carry the new `kid`, and the tokens that orders gave before
   still pass its routes. Its replicas restart one by one, and one that
   has not switched yet takes the new tokens already, by step 1.
3. Once the last token of the old key has expired, the lifetime of a token
   and the leeway after step 2, remove the other key from the settings of
   orders. Billing takes the new key as the key of orders,
   `APP_AUTH_ORDERS_KEY` and `APP_AUTH_ORDERS_KEY_ID`, without an other
   key.

Done the other way round, step 2 before step 1, the new tokens fail with
`UnknownKey` at once, at billing and at the replicas of orders not yet
switched, so the mistake shows. A verifier never changes: to take new keys
without a restart, build a new one. The tests of orders go through step 2,
on a replica that has switched and on one that has not yet (see
[HTTP](#http)), and those of billing through steps 1 and 3, with a verifier
made anew for each, as after a restart:

```zig
// Step 1: billing restarts with the old key and the new one, and
// takes the tokens of both, each by its kid.
const keys = [_]jwt.Key{ b.orders_key.verificationKey(), new_key.verificationKey() };
try b.useKeys(&keys);
for ([_][]const u8{ old_token, new_token }) |token| {
    var result = try b.charge(.{ .bearer = token });
    defer result.deinit();
    try testing.expectEqualStrings("user-7", result.outcome.ok.customer);
}

// Step 3: the old key is gone, and a token it signed is refused.
try b.useKeys(keys[1..]);
var result = try b.charge(.{ .bearer = old_token });
defer result.deinit();
try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
```

## Signing in

The sign-in of orders, `POST /api/login`, is a controller of zefir-http
that checks a user's name and secret and signs a token for them:

```zig
//! Signing in: POST /api/login. A user sends a name and a secret, and the
//! answer is a token of orders, in the form that OAuth clients read (RFC
//! 6749 §5.1). zefir has no passwords: here the users and their secrets
//! come from the settings. A real service checks a password against its
//! hash in a store of users, or lets another system sign users in; the
//! token it gives then is made the same way.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");
const jwt = @import("jwt");
const v = @import("validator");
const auth = @import("auth.zig");

const LoginController = @This();

/// Signs the tokens; borrowed.
signer: *const jwt.Signer,
/// The users who may sign in; borrowed.
users: []const User,

pub const User = struct {
    /// The name a user signs in with.
    name: []const u8,
    /// From the settings, such as `APP_USERS_ANN`; never logged.
    secret: confy.Secret,
    /// The id of the user: "sub" of their tokens.
    id: []const u8,
    roles: []const []const u8,
};

pub const http_routes = http.routes(.{
    .methods = .{
        // A name and a secret: a small limit for the body.
        .login = http.post("/login", .{ .max_body_bytes = 1024 }),
    },
});

pub const LoginRequest = struct {
    user: []const u8,
    secret: []const u8,

    pub const field_rules = .{
        .user = .{ v.notBlank, v.maxLength(64) },
        .secret = .{ v.notEmpty, v.maxLength(256) },
    };
};

pub const LoginResponse = struct {
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    /// How long the token lives, in seconds.
    expires_in: i64,
};

pub fn login(self: *LoginController, ctx: *http.Context) !http.Json(LoginResponse) {
    const body = try ctx.json(LoginRequest);
    // A wrong name or secret: a 401 of the sign-in's own (errors.zig),
    // whatever token the app still sends.
    const user = self.userOf(body.user, body.secret) orelse return error.InvalidCredentials;
    const token = try self.signer.sign(auth.Claims, ctx.io(), ctx.allocator(), &.{ .roles = user.roles }, .{ .subject = user.id });
    return .{ .value = .{ .access_token = token, .expires_in = self.signer.options.lifetime.toSeconds() } };
}

/// The user of `name` whose secret is `secret`; null for anybody else.
fn userOf(self: *const LoginController, name: []const u8, secret: []const u8) ?User {
    for (self.users) |user| {
        const same_secret = sameSecret(secret, user.secret.expose());
        if (same_secret and std.mem.eql(u8, user.name, name)) return user;
    }
    return null;
}

/// Compares the secrets in a time that does not depend on where they
/// differ, so that a caller cannot guess a secret byte by byte.
fn sameSecret(given: []const u8, expected: []const u8) bool {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var a: [Sha256.digest_length]u8 = undefined;
    var b: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(given, &a, .{});
    Sha256.hash(expected, &b, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, a, b);
}
```

> [!WARNING]
> zefir has no passwords: no hashing, no store of users, no reset. The
> secrets of this example come from the settings, as the tokens of the
> zefir-http guide do, and stand in for a real check of a user. Whatever
> checks the user, the token is made the same way.

The signer of orders is made once, in `main`, with the key and the names
of the services; tokens of orders are meant for orders and for billing:

```zig
const signer: jwt.Signer = try .init(&signing_key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
```

- **`.issuer`** is `iss` of every token, **`.audiences`** its `aud`: one
  audience is written as a string, several as an array.
- **`.lifetime`**, 15 minutes unless given, makes `exp`: now plus the
  lifetime. A call may give a token another one with
  `.{ .lifetime = .fromSeconds(60) }`. A short lifetime is what keeps a
  stolen token from being useful for long, since a token cannot be taken
  back.
- **`sign(Claims, io, allocator, &claims, options)`** writes the
  registered claims, then yours. The options give `sub` (`.subject`), `jti`
  (`.id`) and `nbf` (`.not_before`). The token comes from `allocator`, the
  arena of the request here.
- **`.token_type`**, "JWT" unless given, is `typ` of the header, and a
  verifier takes only the types of its `.token_types`. A service that signs
  tokens of several kinds gives each kind a type, such as "at+jwt" for
  access tokens (RFC 9068), and its verifiers take only the kind they
  expect: a token meant to invite a user is no access token.

The header of a token of orders is `{"alg":"EdDSA","typ":"JWT","kid":"2026-10"}`:
the algorithm of the key, the type and the id of the key. `sign` refuses
what it cannot write as a token that `verify` would take, with
`jwt.SignError`: `InvalidClaims` for a string that is not UTF-8, a float
that is not finite or a time past the year 9999, `TokenTooLarge` for a
token over 8 KiB, `BadSignature` for a key that `deinit` wiped while the
signer still used it, and `OutOfMemory`. They are mistakes of the program,
so the error handler of orders answers them with 500.

## Errors

`verify` refuses a token with one error per reason, in the order of the
checks of [How a token is checked](#how-a-token-is-checked).
`jwt.describe(err)` gives each a short English text for the answer to a
client:

| Error | When | `jwt.describe` |
| --- | --- | --- |
| `TokenTooLarge` | the token is over 8 KiB | the token is too large |
| `Malformed` | not three parts; bad base64url or JSON; a claim or a member of the header that jwt reads, given twice; nesting deeper than 32; a member of the header of the wrong type | the token is malformed |
| `UnsupportedAlgorithm` | `alg` is none of the six, `none` among them | the token's algorithm is not supported |
| `UnsupportedHeader` | the header has `crit`, or `cty` says the payload is a nested token | the token's header asks for what is not supported |
| `WrongType` | `typ` is absent or none of the verifier's `token_types` | the token is of another type |
| `UnknownKey` | no key of the verifier has this `kid`; or the token has no `kid` and the verifier more than one key | the token's key is unknown |
| `AlgorithmMismatch` | the key of this `kid` is of another algorithm | the token's algorithm does not fit its key |
| `BadSignature` | the signature does not verify | the token's signature is invalid |
| `MissingClaim` | `exp`, `iss` or `aud` is absent | the token lacks a required claim |
| `InvalidClaims` | a registered claim of the wrong type or out of range; a payload that does not fit your struct | the token's claims are invalid |
| `WrongIssuer` | `iss` is not the verifier's issuer | the token is from another issuer |
| `WrongAudience` | `aud` names none of the verifier's audiences | the token is not meant for this service |
| `Expired` | now ≥ `exp` + leeway | the token has expired |
| `NotYetValid` | `nbf` or `iat` lies in the future, past the leeway | the token is not valid yet |
| `ClaimsRejected` | a rule of `field_rules` is broken | the token's claims are not accepted |
| `OutOfMemory` | the arena of the request has no more memory | the server ran out of memory |

The middleware of orders answers every one of them with 401, but
`OutOfMemory` with 500; the authenticator of billing turns them into
`error.InvalidCredentials` of zefir-rpc, but passes `OutOfMemory` as it is.

The texts say what kind of problem it was, never which claim had which
value. For your log there is more: give `verify` a `jwt.Details`, and on a
refusal it names the claim at fault, such as `exp` for `Expired` or `aud`
for `WrongAudience`, and for `ClaimsRejected`, or `InvalidClaims` of your
struct, the broken rule with its path, such as `roles`. `Details` holds
only constant names and paths of your types: never a byte of the token,
which a client sent and which a log must not take. `verify` clears it
first, so one `Details` serves any number of calls, one at a time: a
request keeps its own, as `JwtAuth` does.

## HTTP

The middleware `JwtAuth` checks the token of every request of orders:

```zig
// Application code (src/auth.zig of the orders service): zefir-jwt ships none of these.
//! The authentication of the orders service, made of ordinary middleware.
//! `JwtAuth` sits in the server's middleware and checks the token of
//! `Authorization: Bearer` on every request: a token of orders puts its
//! user into `ctx.locals`, and a request without a token goes on as
//! anonymous. So does one with a token that does not pass, but with the
//! reason kept for the answer. `requireUser` sits in the middleware of the
//! controllers that need a user, and answers 401 with that reason.
//!
//! ```zig
//! // main: the server's middleware, for every request
//! .middleware = .{&jwt_auth},
//! // a protected controller
//! .middleware = .{auth.requireUser},
//! // a handler
//! const user = try ctx.local(auth.CurrentUser);
//! ```

const std = @import("std");
const http = @import("http");
const jwt = @import("jwt");
const log = @import("log");
const v = @import("validator");

/// The claims of the tokens of orders, besides the registered ones that
/// jwt sets and checks itself.
pub const Claims = struct {
    /// What the user may do, such as "buyer".
    roles: []const []const u8 = &.{},

    pub const field_rules = .{ .roles = v.maxItems(16) };
};

/// The signed-in user of a request, as `JwtAuth` puts it into
/// `ctx.locals`.
pub const CurrentUser = struct {
    /// "sub" of the token.
    id: []const u8,
    roles: []const []const u8,
};

/// Why `JwtAuth` refused the token of a request, for the 401 of
/// `requireUser`.
pub const Refusal = struct { reason: jwt.VerifyError };

/// Checks the bearer token of every request with the verifier of orders.
pub const JwtAuth = struct {
    /// Borrowed: it lives as long as the server.
    verifier: *const jwt.Verifier,
    logger: log.Logger,

    pub fn run(self: *JwtAuth, ctx: *http.Context) !http.MiddlewareResult {
        const token = bearer(ctx.request.header("authorization")) orelse return .next;
        var details: jwt.Details = .{};
        const verified = self.verifier.verify(Claims, ctx.io(), ctx.allocator(), token, .{ .details = &details }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.refuse(ctx, err, &details);
        };
        // orders signs the token of every user with "sub".
        const id = verified.registered.subject orelse return self.refuse(ctx, error.MissingClaim, &.{ .claim = "sub" });
        try ctx.locals.put(CurrentUser, .{ .id = id, .roles = verified.claims.roles });
        return .next;
    }

    /// Logs why the token is refused and keeps the reason for the answer.
    /// The request goes on without a user: a route that needs none, such
    /// as the sign-in, still serves an app that holds an expired token, and
    /// `requireUser` answers the others with 401.
    fn refuse(self: *JwtAuth, ctx: *http.Context, reason: jwt.VerifyError, details: *const jwt.Details) !http.MiddlewareResult {
        // What the refusal was about, never the token: it is a credential.
        self.logger.warn("Token refused", .{ .reason = reason, .claim = details.claim, .violation = details.violation });
        try ctx.locals.put(Refusal, .{ .reason = reason });
        return .next;
    }
};

/// The token of `Authorization: Bearer <token>`.
fn bearer(value: ?[]const u8) ?[]const u8 {
    const header = value orelse return null;
    const scheme = "bearer ";
    if (header.len <= scheme.len or !std.ascii.startsWithIgnoreCase(header, scheme)) return null;
    return header[scheme.len..];
}

/// 401 without a signed-in user: `error.Unauthenticated`, which the
/// framework answers with 401, and `challenge` with the reason when
/// `JwtAuth` refused a token. A wrong token never passes as a user.
pub fn requireUser(ctx: *http.Context) !http.MiddlewareResult {
    _ = ctx.locals.get(CurrentUser) orelse return error.Unauthenticated;
    return .next;
}

/// The value of `WWW-Authenticate` for the 401 of `requireUser`, as RFC
/// 6750 §3 has it: `Bearer` when the request brought no token, and with
/// `error="invalid_token"` and the reason when `JwtAuth` refused one. The
/// texts of `jwt.describe` stand between quotes as they are.
pub fn challenge(ctx: *http.Context) ![]const u8 {
    const refusal = ctx.locals.get(Refusal) orelse return "Bearer";
    return std.fmt.allocPrint(ctx.allocator(), "Bearer error=\"invalid_token\", error_description=\"{s}\"", .{jwt.describe(refusal.reason)});
}
```

- **`JwtAuth`** stands in the server's middleware, for every request. A
  request without `Authorization: Bearer` goes on as anonymous: the
  sign-in needs no user. A token that passes puts its user, `sub` and the
  roles, into `ctx.locals`.
- **A token that does not pass** puts no user there either. The log says
  why, with `jwt.Details`, and never the token; the reason goes into
  `ctx.locals` as a `Refusal`, and the request goes on. So a route that
  needs no user still works: Ann signs in again even while her app sends
  the token that has just expired.
- **`requireUser`** stands where a user is needed: without one,
  `error.Unauthenticated`, 401. A wrong token never passes as a user.
- **`challenge`** writes `WWW-Authenticate` for the 401 of `requireUser`:
  `Bearer` when no token came, and with `error="invalid_token"` and the
  text of `jwt.describe` when one was refused, as RFC 6750 asks.

The error handler of orders adds that header to the 401 of `requireUser`.
The sign-in refuses a wrong name or secret with an error of its own,
`InvalidCredentials`, and its 401 says `Bearer` alone: the reason a token
was refused is no answer to a mistyped secret, even while Ann's app still
sends her expired token. The handler also maps the errors of `sign`:

```zig
//! The error handler of the orders service: the one place where errors
//! become responses. Every 401 carries `WWW-Authenticate`, as RFC 9110
//! asks: that of `requireUser` with the reason when a token was refused
//! (RFC 6750 §3), that of the sign-in without one.

const http = @import("http");
const auth = @import("auth.zig");

/// The body of every error response, as `application/json`.
pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
};

pub const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            // The sign-in's own refusal of a wrong name or secret.
            error.InvalidCredentials => .{ .status = 401, .body = .{ .code = "invalid_credentials", .message = "Wrong user or secret" } },
            // jwt.Signer refuses only what no token can hold, such as a
            // string that is not UTF-8, and a key that deinit wiped too
            // early: mistakes of the program.
            error.InvalidClaims, error.TokenTooLarge, error.BadSignature => .{ .status = 500, .body = .{ .code = "internal", .message = "Internal Server Error" } },
            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        };
    }

    pub fn handle(_: *AppErrors, ctx: *http.Context, err: anyerror, _: *http.ErrorResponse(ApiError)) !http.ErrorAction {
        switch (err) {
            // requireUser found no user: the reason, if JwtAuth refused a token.
            error.Unauthenticated => try ctx.response.setHeader("www-authenticate", try auth.challenge(ctx)),
            // The sign-in refused the name or the secret: no reason of a
            // token here, even when the app still sends one.
            error.InvalidCredentials => try ctx.response.setHeader("www-authenticate", "Bearer"),
            else => {},
        }
        return .respond;
    }
};
```

The orders of a user stand behind `requireUser`, and read the user from
`ctx.locals`:

```zig
//! The orders of the signed-in user: GET /api/orders. Its routes stand
//! behind `requireUser`, so a request without a user never reaches them.

const http = @import("http");
const auth = @import("auth.zig");

const OrdersController = @This();

pub const http_routes = http.routes(.{
    .prefix = "/orders",
    .middleware = .{auth.requireUser},
    .methods = .{ .list = http.get("", .{}) },
});

pub const Order = struct { id: u64, item: []const u8 };

/// Who the user is, by the claims of their token, and their orders.
pub const OrdersResponse = struct {
    user: []const u8,
    roles: []const []const u8,
    orders: []const Order,
};

pub fn list(_: *OrdersController, ctx: *http.Context) !http.Json(OrdersResponse) {
    // JwtAuth put the user there, from the token.
    const user = try ctx.local(auth.CurrentUser);
    // A real service reads the orders of user.id from its store.
    return .{ .value = .{ .user = user.id, .roles = user.roles, .orders = &.{} } };
}
```

The whole service, on the backend in memory, with Ann's app as its client:

```zig
//! The orders service of the guide on the backend in memory, with Ann's
//! app as its client: she signs in, and the app calls with her token,
//! without it, and with a forged one.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");
const jwt = @import("jwt");
const log = @import("log");
const auth = @import("auth.zig");
const errors = @import("errors.zig");
const LoginController = @import("LoginController.zig");
const OrdersController = @import("OrdersController.zig");

const Config = struct {
    auth: struct {
        // APP_AUTH_SIGNING_KEY: the private key of orders, Ed25519 in PEM.
        signing_key: confy.Secret,
        // APP_AUTH_KEY_ID: its id, the "kid" of its tokens.
        key_id: []const u8,
        // While the key changes: the other public key and its id,
        // APP_AUTH_OTHER_KEY and APP_AUTH_OTHER_KEY_ID; the next key before
        // orders switches to it, the previous one after.
        other: ?struct {
            key: []const u8,
            key_id: []const u8,
        },
    },
    users: struct {
        // APP_USERS_ANN: the secret Ann signs in with.
        ann: confy.Secret,
    },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();

    var signing_key: jwt.SigningKey = try .fromPem(.EdDSA, config.auth.signing_key.expose(), .{ .id = config.auth.key_id });
    defer signing_key.deinit();
    // Its tokens are meant for orders and for billing.
    const signer: jwt.Signer = try .init(&signing_key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
    // Orders checks the tokens of its key and, while the key changes, those
    // of the other one: of the next key, which the replicas that switched
    // already sign with, then of the previous one, until its last token
    // expires.
    var keys: [2]jwt.Key = undefined;
    keys[0] = signing_key.verificationKey();
    var key_count: usize = 1;
    if (config.auth.other) |other| {
        keys[1] = try .fromPem(.EdDSA, other.key, .{ .id = other.key_id });
        key_count = 2;
    }
    const verifier: jwt.Verifier = try .init(.{ .keys = keys[0..key_count], .issuer = "orders", .audiences = &.{"orders"} });

    // The objects of the service: main owns them, the server borrows them.
    const users = [_]LoginController.User{
        .{ .name = "ann", .secret = config.users.ann, .id = "user-7", .roles = &.{"buyer"} },
    };
    var login: LoginController = .{ .signer = &signer, .users = &users };
    var orders: OrdersController = .{};
    var jwt_auth: auth.JwtAuth = .{ .verifier = &verifier, .logger = logger.scoped("auth") };
    var app_errors: errors.AppErrors = .{};
    var backend: http.testing.Backend = .init(gpa);
    defer backend.deinit();
    var server = try http.Server.init(gpa, .{
        .controllers = .{ &login, &orders },
        .middleware = .{&jwt_auth},
        .error_handler = &app_errors,
    }, .{
        .listen = .{ .backend = backend.backend() },
        .prefix = "/api",
    });
    defer server.deinit(io);
    try server.start(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    var app: App = .{ .backend = &backend, .io = io, .arena = arena.allocator(), .out = &stdout.interface };

    _ = try app.signIn("guess", "with a wrong secret");
    const token = (try app.signIn(config.users.ann.expose(), "with her secret")) orelse return error.SignInRefused;
    try app.getOrders(null, "without a token");
    try app.getOrders(token, "with Ann's token");
    // A forged token: one character of the signature is another.
    const forged = try app.arena.dupe(u8, token);
    const at = std.mem.findScalarLast(u8, forged, '.').? + 1;
    forged[at] = if (forged[at] == 'A') 'B' else 'A';
    try app.getOrders(forged, "with Ann's token, its signature changed");
}

/// Ann's app: it says what it sends and what comes back, but never the
/// token, a credential.
const App = struct {
    backend: *http.testing.Backend,
    io: std.Io,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,

    /// POST /api/login as Ann: her token, or null when refused.
    fn signIn(app: *App, secret: []const u8, how: []const u8) !?[]const u8 {
        try app.out.print("POST /api/login as ann, {s}\n", .{how});
        try app.out.flush();
        const body = try std.json.Stringify.valueAlloc(app.arena, LoginController.LoginRequest{ .user = "ann", .secret = secret }, .{});
        var res = try app.backend.request(app.io, .{
            .method = .POST,
            .target = "/api/login",
            .headers = &.{.{ "content-type", "application/json" }},
            .body = body,
        });
        defer res.deinit();
        if (res.status != 200) {
            try app.show(&res);
            return null;
        }
        const answer = try std.json.parseFromSliceLeaky(LoginController.LoginResponse, app.arena, res.body, .{ .allocate = .alloc_always });
        try app.out.print("→ 200 token_type={s} expires_in={d}\n", .{ answer.token_type, answer.expires_in });
        try app.out.flush();
        return answer.access_token;
    }

    /// GET /api/orders, with `token` in `Authorization: Bearer` if any.
    fn getOrders(app: *App, token: ?[]const u8, how: []const u8) !void {
        try app.out.print("GET /api/orders {s}\n", .{how});
        try app.out.flush();
        const authorization: [1][2][]const u8 = .{.{ "authorization", if (token) |t| try std.fmt.allocPrint(app.arena, "Bearer {s}", .{t}) else "" }};
        var res = try app.backend.request(app.io, .{
            .method = .GET,
            .target = "/api/orders",
            .headers = if (token == null) &.{} else &authorization,
        });
        defer res.deinit();
        try app.show(&res);
    }

    /// The status, then `WWW-Authenticate` of a 401 or else the body.
    fn show(app: *App, res: *const http.testing.Response) !void {
        if (res.status == 401) {
            try app.out.print("→ 401 WWW-Authenticate: {s}\n", .{res.header("www-authenticate") orelse ""});
        } else {
            try app.out.print("→ {d} {s}\n", .{ res.status, res.body });
        }
        try app.out.flush();
    }
};
```

Its settings are the key of orders, its id, and Ann's secret; while the
key of orders changes, the other public key too (see
[Keys](#keys)). The line of `WARN` comes from the log of `JwtAuth`, in
the middle of the request it refused:

```text
$ APP_AUTH_SIGNING_KEY="$(cat orders.pem)" APP_AUTH_KEY_ID=2026-10 APP_USERS_ANN=ann-secret zig build run
POST /api/login as ann, with a wrong secret
→ 401 WWW-Authenticate: Bearer
POST /api/login as ann, with her secret
→ 200 token_type=Bearer expires_in=900
GET /api/orders without a token
→ 401 WWW-Authenticate: Bearer
GET /api/orders with Ann's token
→ 200 {"user":"user-7","roles":["buyer"],"orders":[]}
GET /api/orders with Ann's token, its signature changed
2026-10-22T09:52:31.208Z WARN  [auth] Token refused reason=BadSignature claim=null violation=null
→ 401 WWW-Authenticate: Bearer error="invalid_token", error_description="the token's signature is invalid"
```

The tests of orders run the same server on `http.testing.Backend`, with a
key made for them and the time set by `jwt.testing.FixedClock`, so a token
expires without a wait of 15 minutes ([Tests](#tests) tells more):

```zig
//! Tests of the orders service without a network: `http.testing.Backend`
//! serves the same server, controllers and middleware from memory. The
//! key is made for the tests, and `jwt.testing.FixedClock` sets the time
//! that the server, the signer and the verifier read, so a test can let a
//! token expire without waiting.

const std = @import("std");
const http = @import("http");
const jwt = @import("jwt");
const log = @import("log");
const auth = @import("auth.zig");
const errors = @import("errors.zig");
const LoginController = @import("LoginController.zig");
const OrdersController = @import("OrdersController.zig");

const testing = std.testing;

/// The time of the tests: 2026-10-22, 12:00 UTC, in seconds of Unix time.
const noon = 1_792_670_400;

/// What a test sets of the service, as `main` reads it from the settings.
const Options = struct {
    /// The id of the key of orders, which the test makes on the spot.
    key_id: []const u8 = "2026-10",
    /// While the key changes, the public key of the other key: the next one
    /// before the switch, the previous one after it.
    other: ?jwt.Key = null,
};

/// The service as `main` builds it, on the backend in memory, with a key
/// of its own and the clock at noon.
const Service = struct {
    clock: jwt.testing.FixedClock,
    key: jwt.SigningKey,
    keys: [2]jwt.Key,
    signer: jwt.Signer,
    verifier: jwt.Verifier,
    /// What the log of `JwtAuth` wrote, a record per line.
    records: std.Io.Writer.Allocating,
    logger: log.Logger,
    users: [1]LoginController.User,
    login: LoginController,
    orders: OrdersController,
    jwt_auth: auth.JwtAuth,
    app_errors: errors.AppErrors,
    backend: http.testing.Backend,
    server: http.Server,

    /// Starts the service; `s` stays where it is until `stop`.
    fn start(s: *Service, options: Options) !void {
        s.clock = try .init(testing.io, noon);
        errdefer s.clock.deinit();
        const io = s.clock.io();
        // A key of the tests alone, made on the spot.
        s.key = try .generate(io, .EdDSA, .{ .id = options.key_id });
        errdefer s.key.deinit();
        s.signer = try .init(&s.key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
        // As in main: the key of orders, and the other one, if any.
        s.keys[0] = s.key.verificationKey();
        var key_count: usize = 1;
        if (options.other) |other| {
            s.keys[1] = other;
            key_count = 2;
        }
        s.verifier = try .init(.{ .keys = s.keys[0..key_count], .issuer = "orders", .audiences = &.{"orders"} });
        s.records = .init(testing.allocator);
        errdefer s.records.deinit();
        s.logger = try .init(testing.allocator, io, .{ .format = .text, .output = .{ .writer = &s.records.writer } });
        errdefer s.logger.deinit();
        s.users = .{.{ .name = "ann", .secret = .init("ann-secret"), .id = "user-7", .roles = &.{"buyer"} }};
        s.login = .{ .signer = &s.signer, .users = &s.users };
        s.orders = .{};
        s.jwt_auth = .{ .verifier = &s.verifier, .logger = s.logger.scoped("auth") };
        s.app_errors = .{};
        s.backend = .init(testing.allocator);
        s.server = try .init(testing.allocator, .{
            .controllers = .{ &s.login, &s.orders },
            .middleware = .{&s.jwt_auth},
            .error_handler = &s.app_errors,
        }, .{
            .listen = .{ .backend = s.backend.backend() },
            .prefix = "/api",
        });
        errdefer s.server.deinit(io);
        try s.server.start(io);
    }

    fn stop(s: *Service) void {
        s.server.deinit(s.clock.io());
        s.backend.deinit();
        s.logger.deinit();
        s.records.deinit();
        s.keys[0].deinit();
        s.key.deinit();
        s.clock.deinit();
    }

    /// POST /api/login as Ann with `secret`, and with `token` in
    /// `Authorization: Bearer` when her app still holds one.
    fn signIn(s: *Service, secret: []const u8, token: ?[]const u8) !http.testing.Response {
        const body = try std.json.Stringify.valueAlloc(testing.allocator, LoginController.LoginRequest{ .user = "ann", .secret = secret }, .{});
        defer testing.allocator.free(body);
        const authorization = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token orelse ""});
        defer testing.allocator.free(authorization);
        const headers: [2][2][]const u8 = .{ .{ "content-type", "application/json" }, .{ "authorization", authorization } };
        return s.backend.request(s.clock.io(), .{
            .method = .POST,
            .target = "/api/login",
            .headers = headers[0..if (token == null) 1 else 2],
            .body = body,
        });
    }

    /// Ann's token, which the caller frees.
    fn tokenOfAnn(s: *Service) ![]u8 {
        var res = try s.signIn("ann-secret", null);
        defer res.deinit();
        try testing.expectEqual(200, res.status);
        const answer = try std.json.parseFromSliceLeaky(LoginController.LoginResponse, res.arena.allocator(), res.body, .{});
        return testing.allocator.dupe(u8, answer.access_token);
    }

    /// GET /api/orders with `token` in `Authorization: Bearer`.
    fn getOrders(s: *Service, token: []const u8) !http.testing.Response {
        const authorization = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
        defer testing.allocator.free(authorization);
        return s.backend.request(s.clock.io(), .{
            .method = .GET,
            .target = "/api/orders",
            .headers = &.{.{ "authorization", authorization }},
        });
    }
};

test "POST /api/login gives a token for 15 minutes" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();

    var res = try s.signIn("ann-secret", null);
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    const answer = try std.json.parseFromSliceLeaky(LoginController.LoginResponse, res.arena.allocator(), res.body, .{});
    try testing.expectEqualStrings("Bearer", answer.token_type);
    try testing.expectEqual(15 * 60, answer.expires_in);

    // The token verifies, with the claims of Ann, from noon to 12:15.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const verified = try s.verifier.verify(auth.Claims, s.clock.io(), arena.allocator(), answer.access_token, .{});
    try testing.expectEqualStrings("user-7", verified.registered.subject.?);
    try testing.expectEqual(noon, verified.registered.issued_at.?);
    try testing.expectEqual(15 * 60, verified.registered.expires_at - verified.registered.issued_at.?);
    try testing.expectEqual(1, verified.claims.roles.len);
    try testing.expectEqualStrings("buyer", verified.claims.roles[0]);

    // A wrong secret gets no token.
    var refused = try s.signIn("guess", null);
    defer refused.deinit();
    try testing.expectEqual(401, refused.status);
    try testing.expectEqualStrings("Bearer", refused.header("www-authenticate").?);
}

test "GET /api/orders with the token sees the user" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();
    const token = try s.tokenOfAnn();
    defer testing.allocator.free(token);

    var res = try s.getOrders(token);
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    const mine = try std.json.parseFromSliceLeaky(OrdersController.OrdersResponse, res.arena.allocator(), res.body, .{});
    try testing.expectEqualStrings("user-7", mine.user);
    try testing.expectEqualStrings("buyer", mine.roles[0]);
}

test "without a token the request is anonymous, and a protected route says 401" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();

    var res = try s.backend.request(s.clock.io(), .{ .method = .GET, .target = "/api/orders" });
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer", res.header("www-authenticate").?);
    // Nothing was refused: no token came.
    try testing.expectEqualStrings("", s.records.written());
}

test "an expired token is 401 invalid_token with its description" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();
    const token = try s.tokenOfAnn();
    defer testing.allocator.free(token);

    // 15 minutes of its life and the 60 seconds of leeway have passed.
    s.clock.set(noon + 16 * 60);
    var res = try s.getOrders(token);
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer error=\"invalid_token\", error_description=\"the token has expired\"", res.header("www-authenticate").?);
    // The log says why, and nothing of the token.
    try testing.expect(std.mem.find(u8, s.records.written(), "Token refused reason=Expired claim=exp") != null);
    try testing.expect(std.mem.find(u8, s.records.written(), token) == null);
}

test "an expired token does not stop POST /api/login" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();
    const token = try s.tokenOfAnn();
    defer testing.allocator.free(token);

    // Ann's app still sends her old token when she signs in again.
    s.clock.set(noon + 16 * 60);
    var res = try s.signIn("ann-secret", token);
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expect(std.mem.find(u8, s.records.written(), "Token refused reason=Expired claim=exp") != null);
}

test "with an expired token and a wrong secret, POST /api/login refuses the secret" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();
    const token = try s.tokenOfAnn();
    defer testing.allocator.free(token);

    // Ann's app still sends her old token, and she mistypes her secret: the
    // answer is the sign-in's own, with nothing of the old token.
    s.clock.set(noon + 16 * 60);
    var res = try s.signIn("guess", token);
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer", res.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"code\":\"invalid_credentials\",\"message\":\"Wrong user or secret\"}", res.body);
}

test "a token for billing alone is 401 at orders" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();

    const for_billing: jwt.Signer = try .init(&s.key, .{ .issuer = "orders", .audiences = &.{"billing"} });
    const token = try for_billing.sign(auth.Claims, s.clock.io(), testing.allocator, &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
    defer testing.allocator.free(token);
    var res = try s.getOrders(token);
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer error=\"invalid_token\", error_description=\"the token is not meant for this service\"", res.header("www-authenticate").?);
}

test "a token of orders without sub is 401 where a user is needed" {
    var s: Service = undefined;
    try s.start(.{});
    defer s.stop();

    // Signed by orders, but for nobody.
    const token = try s.signer.sign(auth.Claims, s.clock.io(), testing.allocator, &.{}, .{});
    defer testing.allocator.free(token);
    var res = try s.getOrders(token);
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try testing.expectEqualStrings("Bearer error=\"invalid_token\", error_description=\"the token lacks a required claim\"", res.header("www-authenticate").?);
    try testing.expect(std.mem.find(u8, s.records.written(), "Token refused reason=MissingClaim claim=sub") != null);
}

test "while orders changes its key, a replica not yet switched takes the tokens of one that has" {
    // Step 2 of the change goes from replica to replica. One that has
    // switched signs with the next key already.
    var next_key: jwt.Key = undefined;
    const new_token = new: {
        var switched: Service = undefined;
        try switched.start(.{ .key_id = "2026-11" });
        defer switched.stop();
        next_key = switched.key.verificationKey();
        break :new try switched.tokenOfAnn();
    };
    defer testing.allocator.free(new_token);

    // A replica not yet switched signs with the first key, and since step 1
    // it has the public key of the next one as its other key: Ann's new
    // token passes there too.
    var s: Service = undefined;
    try s.start(.{ .other = next_key });
    defer s.stop();
    var res = try s.getOrders(new_token);
    defer res.deinit();
    try testing.expectEqual(200, res.status);
}

test "after orders changes its key, a token of the old one still passes" {
    // Before the change: Ann signs in with orders on its first key.
    var old_key: jwt.Key = undefined;
    const old_token = old: {
        var before: Service = undefined;
        try before.start(.{});
        defer before.stop();
        old_key = before.key.verificationKey();
        break :old try before.tokenOfAnn();
    };
    defer testing.allocator.free(old_token);

    // Step 2 of the change: orders restarts with a new key, and with the
    // public key of the old one as its other key.
    var s: Service = undefined;
    try s.start(.{ .key_id = "2026-11", .other = old_key });
    defer s.stop();
    const new_token = try s.tokenOfAnn();
    defer testing.allocator.free(new_token);
    for ([_][]const u8{ old_token, new_token }) |token| {
        var res = try s.getOrders(token);
        defer res.deinit();
        try testing.expectEqual(200, res.status);
    }
}
```

## RPC

Billing is a service of zefir-rpc. Its authenticator checks the token of
every call, with the public key of orders from its settings:

```zig
//! The authenticator of the billing service: who calls, by the token that
//! orders signed for its user. Billing has only public keys of orders,
//! from its settings: it checks tokens, and cannot make one.
//!
//! ```zig
//! // main of billing: the key of orders, APP_AUTH_ORDERS_KEY and
//! // APP_AUTH_ORDERS_KEY_ID, and while it changes the other one,
//! // APP_AUTH_OTHER_KEY and APP_AUTH_OTHER_KEY_ID, as in orders
//! var keys: [2]jwt.Key = undefined;
//! keys[0] = try .fromPem(.EdDSA, config.auth.orders_key, .{ .id = config.auth.orders_key_id });
//! var key_count: usize = 1;
//! if (config.auth.other) |other| {
//!     keys[1] = try .fromPem(.EdDSA, other.key, .{ .id = other.key_id });
//!     key_count = 2;
//! }
//! const verifier: jwt.Verifier = try .init(.{ .keys = keys[0..key_count], .issuer = "orders", .audiences = &.{"billing"} });
//! var authenticator: JwtAuthenticator = .{ .verifier = &verifier };
//! // .authenticator = &authenticator in the options of rpc.Server
//! ```

const jwt = @import("jwt");
const rpc = @import("rpc");
const v = @import("validator");

const JwtAuthenticator = @This();

/// Borrowed: it lives as long as the server.
verifier: *const jwt.Verifier,

/// The claims billing reads from a token of orders. The claims it does
/// not name are skipped.
pub const Claims = struct {
    roles: []const []const u8 = &.{},

    pub const field_rules = .{ .roles = v.maxItems(16) };
};

pub fn authenticate(self: *JwtAuthenticator, ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView {
    return switch (ctx.credentials) {
        // No token: an anonymous call, which a method with
        // `.auth = .required` refuses.
        .none => null,
        .bearer => |token| {
            // The claims live in the arena of the call, as the identity must.
            const verified = self.verifier.verify(Claims, ctx.io(), ctx.allocator(), token, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Expired, forged, or meant for another service: a wrong
                // token never passes as no token.
                else => return error.InvalidCredentials,
            };
            const subject = verified.registered.subject orelse return error.InvalidCredentials;
            return .{ .subject = subject, .roles = verified.claims.roles };
        },
        // Basic credentials or a scheme of another kind: billing takes none.
        else => error.InvalidCredentials,
    };
}
```

- **No token** is an anonymous call: a method with `.auth = .required`
  refuses it with `unauthenticated`, "Authentication required".
- **A token that passes** gives the caller an identity: its `sub` and its
  roles, in the arena of the call, which the identity of zefir-rpc needs.
- **A token that does not pass**, whatever the reason, is
  `error.InvalidCredentials`: `unauthenticated`, "Invalid credentials",
  even on a method where a caller is optional. `OutOfMemory` passes as it
  is. `verify` waits for nothing, so the deadline and the cancelation of a
  call never stop it halfway.
- **Billing names only the claims it reads.** Its `Claims` has the roles
  alone; a claim that orders adds later is skipped, and billing goes on
  working.

The contract of billing, a package that billing and its clients share,
and its handler, which charges an order to the caller:

```zig
//! The package billing-api: the contract of the billing service.

const rpc = @import("rpc");
const v = @import("validator");

pub const ChargeRequest = struct {
    order_id: u64,
    amount_cents: u64,

    pub const field_rules = .{
        .order_id = v.positive,
        .amount_cents = v.range(1, 100_000_000),
    };
};

/// An order, charged to the user who placed it.
pub const Charge = struct {
    order_id: u64,
    /// The user of the token: its "sub".
    customer: []const u8,
    amount_cents: u64,
};

pub const BillingApi = rpc.Contract(.{
    .name = "billing",
    .version = 1,
    .methods = .{
        .charge = rpc.method(ChargeRequest, Charge),
    },
});

test "the rules of the requests are valid" {
    comptime v.assertRules(ChargeRequest);
}
```

```zig
//! The handler of billing.v1: it charges an order to the caller, whom the
//! authenticator found by the token. Every method needs a caller.

const rpc = @import("rpc");
const api = @import("billing-api");

const BillingHandler = @This();

pub const rpc_handler = rpc.implement(api.BillingApi, .{
    .defaults = .{ .auth = .required },
});

pub fn charge(_: *BillingHandler, ctx: *rpc.Context, req: api.ChargeRequest) error{Unauthenticated}!api.Charge {
    // `.auth = .required`: an anonymous call never gets here.
    const caller = ctx.identity() orelse return error.Unauthenticated;
    // A real service charges the user here, by caller.subject.
    return .{ .order_id = req.order_id, .customer = caller.subject, .amount_cents = req.amount_cents };
}
```

The token reaches billing as the credentials of a call. Orders calls
billing for the user it serves with the token that came with the request:
`.{ .credentials = .{ .bearer = token } }` among the options of
`client.call`, as the tests below do. The tests run billing on
`rpc.testing.Server`, and sign their tokens as orders would, with a key of
orders made for them; billing gets only its public half:

```zig
//! Tests of the billing service without a network: `rpc.testing.Server`
//! runs its handler with the whole chain of `rpc.Server`, the
//! authenticator first, on a memory transport. The client of a test calls
//! as orders would, with the token of a user. The tokens come from a
//! signer with a key of orders made for the tests, and
//! `jwt.testing.FixedClock` sets the time.

const std = @import("std");
const jwt = @import("jwt");
const rpc = @import("rpc");
const api = @import("billing-api");
const BillingHandler = @import("BillingHandler.zig");
const JwtAuthenticator = @import("JwtAuthenticator.zig");

const testing = std.testing;

/// The time of the tests: 2026-10-22, 12:00 UTC, in seconds of Unix time.
const noon = 1_792_670_400;

/// Billing as its `main` builds it: the public key of orders, a verifier
/// of the audience billing, and the server with the authenticator.
const Billing = struct {
    clock: jwt.testing.FixedClock,
    /// The private key of orders, which billing never has: the tests sign
    /// with it, as orders would.
    orders_key: jwt.SigningKey,
    /// The public key of orders, as billing reads it from its settings.
    keys: [1]jwt.Key,
    verifier: jwt.Verifier,
    authenticator: JwtAuthenticator,
    handler: BillingHandler,
    server: rpc.testing.Server,
    client: rpc.Client,

    /// Starts billing; `b` stays where it is until `stop`.
    fn start(b: *Billing) !void {
        b.clock = try .init(testing.io, noon);
        errdefer b.clock.deinit();
        const io = b.clock.io();
        b.orders_key = try .generate(io, .EdDSA, .{ .id = "2026-10" });
        errdefer b.orders_key.deinit();
        b.keys = .{b.orders_key.verificationKey()};
        try b.useKeys(&b.keys);
        b.authenticator = .{ .verifier = &b.verifier };
        b.handler = .{};
        b.server = try .init(testing.allocator, io, .{ .handlers = .{&b.handler}, .authenticator = &b.authenticator }, .{});
        errdefer b.server.deinit();
        b.client = try b.server.client(.{}, .{});
    }

    fn stop(b: *Billing) void {
        b.client.deinit();
        b.server.deinit();
        b.keys[0].deinit();
        b.orders_key.deinit();
        b.clock.deinit();
    }

    /// The public keys of orders that billing takes, as its settings list
    /// them after a restart.
    fn useKeys(b: *Billing, keys: []const jwt.Key) !void {
        b.verifier = try .init(.{ .keys = keys, .issuer = "orders", .audiences = &.{"billing"} });
    }

    /// A token of orders for user-7, signed with `key` for `audiences`;
    /// the caller frees it.
    fn tokenOf(b: *Billing, key: *const jwt.SigningKey, audiences: []const []const u8) ![]u8 {
        const signer: jwt.Signer = try .init(key, .{ .issuer = "orders", .audiences = audiences });
        return signer.sign(JwtAuthenticator.Claims, b.clock.io(), testing.allocator, &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
    }

    /// billing.v1.charge of order 42, with `credentials`.
    fn charge(b: *Billing, credentials: rpc.Credentials) !rpc.Client.Result(api.Charge) {
        return b.client.call(b.clock.io(), .root, api.BillingApi.charge, .{ .order_id = 42, .amount_cents = 1250 }, .{ .credentials = credentials });
    }
};

test "billing takes the token of orders" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();
    const token = try b.tokenOf(&b.orders_key, &.{ "orders", "billing" });
    defer testing.allocator.free(token);

    var result = try b.charge(.{ .bearer = token });
    defer result.deinit();
    // The handler charged the user of the token.
    try testing.expectEqualStrings("user-7", result.outcome.ok.customer);
    try testing.expectEqual(42, result.outcome.ok.order_id);
}

test "a token without billing among its audiences is unauthenticated" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();
    const token = try b.tokenOf(&b.orders_key, &.{"orders"});
    defer testing.allocator.free(token);

    var result = try b.charge(.{ .bearer = token });
    defer result.deinit();
    try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
    try testing.expectEqualStrings("Invalid credentials", result.outcome.failure.message);
}

test "no token is anonymous, and a method that needs a user refuses it" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();

    var result = try b.charge(.none);
    defer result.deinit();
    try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
    try testing.expectEqualStrings("Authentication required", result.outcome.failure.message);
}

test "an expired token is unauthenticated" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();
    const token = try b.tokenOf(&b.orders_key, &.{ "orders", "billing" });
    defer testing.allocator.free(token);

    // 15 minutes of its life and the 60 seconds of leeway have passed.
    b.clock.set(noon + 16 * 60);
    var result = try b.charge(.{ .bearer = token });
    defer result.deinit();
    try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
}

test "Basic credentials and a token without sub are unauthenticated" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();

    // Billing takes tokens alone.
    var basic = try b.charge(.{ .basic = .{ .user = "ann", .password = "ann-secret" } });
    defer basic.deinit();
    try testing.expectEqual(.unauthenticated, basic.outcome.failure.code);
    try testing.expectEqualStrings("Invalid credentials", basic.outcome.failure.message);

    // A token that orders signed for nobody: no caller to charge.
    const signer: jwt.Signer = try .init(&b.orders_key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
    const token = try signer.sign(JwtAuthenticator.Claims, b.clock.io(), testing.allocator, &.{}, .{});
    defer testing.allocator.free(token);
    var nobody = try b.charge(.{ .bearer = token });
    defer nobody.deinit();
    try testing.expectEqual(.unauthenticated, nobody.outcome.failure.code);
    try testing.expectEqualStrings("Invalid credentials", nobody.outcome.failure.message);
}

test "while the key of orders changes, billing takes the tokens of both keys" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();
    var new_key: jwt.SigningKey = try .generate(b.clock.io(), .EdDSA, .{ .id = "2026-11" });
    defer new_key.deinit();
    const old_token = try b.tokenOf(&b.orders_key, &.{ "orders", "billing" });
    defer testing.allocator.free(old_token);
    const new_token = try b.tokenOf(&new_key, &.{ "orders", "billing" });
    defer testing.allocator.free(new_token);

    // Step 1: billing restarts with the old key and the new one, and
    // takes the tokens of both, each by its kid.
    const keys = [_]jwt.Key{ b.orders_key.verificationKey(), new_key.verificationKey() };
    try b.useKeys(&keys);
    for ([_][]const u8{ old_token, new_token }) |token| {
        var result = try b.charge(.{ .bearer = token });
        defer result.deinit();
        try testing.expectEqualStrings("user-7", result.outcome.ok.customer);
    }

    // Step 3: the old key is gone, and a token it signed is refused.
    try b.useKeys(keys[1..]);
    var result = try b.charge(.{ .bearer = old_token });
    defer result.deinit();
    try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
}
```

## Tests

The tests of a service that signs and checks tokens need two things that
production takes from outside: a key and the time.

**A key made on the spot.** `jwt.SigningKey.generate` makes a new random
key of any of the six algorithms, with the id you give it:

```zig
// A key of the tests alone, made on the spot.
s.key = try .generate(io, .EdDSA, .{ .id = options.key_id });
```

The tests need no key file and no secret in their settings. The public
half of the key is `verificationKey()`, as for a key from the settings. A
key made this way cannot be written out: it lives as long as the test.

**The time a test sets.** `verify` and `sign` read the time from the clock
`.real` of their `std.Io`. `jwt.testing.FixedClock` wraps the `Io` of the
test, and the `Io` it gives, `clock.io()`, says the time the test set;
everything else goes to the wrapped `Io` as it is:

```zig
s.clock = try .init(testing.io, noon);
errdefer s.clock.deinit();
const io = s.clock.io();
```

The tests give that `Io` to the server and the backend of zefir-http, or
to `rpc.testing.Server`, and the middleware sees the time of the test
through `ctx.io()`, without a line of the service changed. Then a test
moves the time:

```zig
// 15 minutes of its life and the 60 seconds of leeway have passed.
s.clock.set(noon + 16 * 60);
```

`FixedClock` is unusual, and it has limits, which follow from how it works:
it replaces the entry of the clock in the table of functions of `std.Io`,
and that entry gets no pointer to the clock.

- **One clock per process.** The time lives in a variable of
  `jwt.testing`, so while one `FixedClock` lives, a second `init` is
  `error.ClockInUse`. The test runner of Zig runs the tests of a binary one
  after another, and every test binary is a process of its own, so a test
  that takes the clock in its start and gives it back with `deinit` never
  meets another.
- **Only `.real` is fixed.** The clock `.awake` is left alone, so the
  timeouts and the sleeps of the `Io`, and the deadlines of the requests of
  zefir-http and of the calls of zefir-rpc, go as they always do.
- **Everyone who uses `clock.io()` sees the fixed time**, such as the
  `Date` header of zefir-http and the timestamps of zefir-log. In a test
  that does no harm.
- **There is no option "now" in `verify` or `sign`**, on purpose: the code
  of the service reads the time where it always does, and production code
  has no handle meant for tests.

The tests of this guide, [`auth_test.zig`](#http) and
[`rpc_auth_test.zig`](#rpc), run with `zig build test-jwt` in this
repository; a service runs its own with a test step of its `build.zig`.

## Security

What jwt refuses, and why:

- **The algorithm comes from the key, never from the token.** A key is
  bound to one algorithm when it loads, and a token whose `alg` is another
  is `AlgorithmMismatch`. A public key never turns into an HMAC secret: a
  token of `HS256` "signed" with the public key of orders, under its `kid`,
  is refused, which is the attack of the confusion of algorithms.
- **`none` never passes**, nor `None` nor `NONE`: `UnsupportedAlgorithm`.
- **The key comes only from the verifier.** `jku`, `x5u`, `jwk`, `x5c`,
  `x5t` and `x5t#S256` of a header are never read, and jwt has no network
  code at all: a token cannot send a service to fetch a key, or bring a
  key of its own (RFC 8725 §3.10).
- **A key is chosen by `kid`, never tried in turn.** A verifier with several
  keys takes only tokens with a `kid`, and an unknown one is `UnknownKey`.
  `Verifier.init` refuses no keys, two keys with one id and a key without an
  id next to others: a mistake of the settings shows when the service
  starts, not on a request.
- **One issuer per verifier.** With one list of keys for several issuers,
  the key of one service could make tokens in the name of another. The
  tokens of two issuers take two verifiers.
- **`crit` in any form is `UnsupportedHeader`**: a token that asks for an
  extension that jwt does not know is refused, as RFC 7515 says. So is a
  token inside a token, `cty: "JWT"`.
- **`typ` is required** and must be one of the verifier's types, so a token
  of another kind, from the same issuer and the same key, does not pass
  (RFC 8725 §3.11).
- **`exp`, `iss` and `aud` are required.** A token without an end, or that
  does not say for whom it is, never passes.
- **Signatures are checked strictly.** An ECDSA signature of zeros (CVE-2022-21449)
  and one in DER instead of r‖s are `BadSignature`. ECDSA takes two
  signatures for each one it makes, (r, s) and (r, n − s): jwt signs with
  the low s and takes only that one, so a token of ES256 or ES384 is one
  string, and nobody can turn it into a second one that passes, past a
  service that remembers tokens by their text. Ed25519 is verified
  without its cofactor, which leaves no room for signatures made up to
  pass; HMAC is compared in a time that does not depend on the bytes.
- **Hostile input fails with an error.** A token over 8 KiB is refused
  before anything else; JSON deeper than 32 levels, a claim or a member of
  the header that jwt reads given twice, and bad UTF-8 are `Malformed`;
  a key that jwt does not read may come twice, and is skipped. A key file
  is read by a reader of DER and PEM that checks every length first. No
  input crashes the service: the tests of jwt give it broken tokens, keys
  and files, and a fuzzer gives it more.
- **The payload is read only after the signature passed**, so JSON that
  nobody signed is never parsed.

**Secrets.** Keys and secrets come from the settings as `confy.Secret`. A
key keeps a copy of what it needs, so the settings may be freed; its
`deinit` wipes it, and jwt wipes the buffers in which it reads a key.
zefir-log writes a key as `[REDACTED]`, `{f}` prints only its algorithm
and `kid`, and `{any}` none of its bytes. jwt itself logs nothing.

**Where a key lives.** A private key or an HMAC secret is the power to make
tokens: whoever reads it can be any user of the service. So:

- an environment variable is seen by more than the service: every child
  process of the service inherits it, anybody allowed to read
  `/proc/<pid>/environ` on Linux sees it, and so does `docker inspect` of
  its container. Where you can, hand the key over as a file that only the
  user of the service may read, such as a secret that the orchestrator
  mounts: a `.env` file of confy, with the PEM on one line as in
  [Keys](#keys), listed among the sources of the service,
  `.sources = &.{ .env("/run/secrets/orders.env"), .osEnv() }`. confy
  reads it when the service starts. A `.env` file that is not there is
  skipped, so a mount that failed shows as a missing key: the service
  stops at once and says so;
- never commit `orders.pem`, or a `.env` file that holds a key: list both
  in `.gitignore`. A public key such as `orders.pub.pem` may go anywhere.

**A token is a credential to its bearer**: whoever has it is the user until
it expires, and nothing takes it back early. So:

- never log `Authorization` or a token, as `JwtAuth` logs only why it
  refused one;
- send tokens only over TLS: a service of zefir-http ends TLS at a proxy
  in front of it, and the calls of zefir-rpc over NATS travel unencrypted,
  so run them only in a network you trust;
- keep the lifetime short, 15 minutes unless you have a reason;
- put no secret into a claim: anybody who has the token can read it.

## Limits

| What | Value | Where |
| --- | --- | --- |
| a token | 8 KiB | `jwt.max_token_bytes` |
| nesting of the JSON of the header and of the payload | 32 levels | `jwt.max_json_depth` |
| `kid` | 1 to 128 bytes of visible ASCII | `jwt.max_key_id_bytes` |
| leeway of the clocks | 60 s, from 0 to 300 | `Verifier.Options.leeway` |
| lifetime of a token | 15 minutes | `Signer.Options.lifetime` |
| a PEM or a DER file | 16 KiB | — |
| an HMAC secret | at least 32, 48 or 64 bytes, for HS256, HS384 and HS512 | — |
| a time (NumericDate) | 0 to 253402300799 seconds, the end of the year 9999 | — |
| the path of a violation | 256 bytes | `Details.path_buf` |

- **Memory.** `verify` takes its memory from the arena it is given, about
  twice the size of the token and the slices of your claims, and frees
  nothing: the arena of the request frees it all. `sign` takes the token
  from its allocator, which the caller frees, and frees its own buffers
  before it returns.
- **Many tasks at once.** A `Verifier` and a `Signer` never change after
  `init`, and own nothing: one of each serves every task of a service. The
  keys they borrow must live, unchanged, as long as they do: `deinit` a key
  only after the last call that uses it.
