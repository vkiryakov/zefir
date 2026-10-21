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

## Installation

## jwt in a minute

## Claims

## Keys

## Signing in

## Errors

## HTTP

## RPC

## Tests

## Security

## Limits
