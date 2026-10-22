# redis

> [!WARNING]
> **No TLS yet: use it only in a network you trust.** zefir-redis speaks
> plain TCP. The password goes to the server as it is, in the HELLO of
> every new connection, and so does every command and every value: whoever
> can read the traffic reads them all. Until the client has TLS, keep
> Redis and its services in a closed network, give each service a user of
> its own with a long random password, and across a network you do not
> trust, use a tunnel: WireGuard, SSH or a service mesh.

**A Redis client for Zig services.**
