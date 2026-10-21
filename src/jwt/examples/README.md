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
>   not checked.
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
minutes, signed with its Ed25519 key. Its routes, such as `GET
/api/orders`, check that token in the middleware `JwtAuth`. **Billing**, a
service of zefir-rpc, takes the same token when Ann pays: the token names
both services as its audience. Billing checks it in its authenticator,
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

Add Zefir to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#dev
```

zefir-jwt is on the `dev` branch until the next release. The command
fetches the latest commit of `dev`; `--save` pins that commit. The latest
release, v0.9.0, came before zefir-jwt, so `#v0.9.0` does not have it.

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
> imports only validator, and nothing outside Zefir: no network, no tasks,
> no state of its own.

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

## Keys

## Signing in

## Errors

## HTTP

## RPC

## Tests

## Security

## Limits
