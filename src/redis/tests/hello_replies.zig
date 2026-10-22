//! What real servers answer in the handshake, byte for byte, as recorded
//! from their images in Docker on 2026-10-22 (`redis:5.0.14`,
//! `redis:6.2.24`, `redis:7.2.16`, `redis:8.10.2`, `valkey/valkey:9.1.2`),
//! for the tests of the handshake against a `Peer`.

/// Redis 8.10.2 from its image, which loads its modules.
pub const redis_8_10_2 =
    "%7\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$6\r\n8.10.2\r\n$5\r\nproto\r\n" ++
    ":3\r\n$2\r\nid\r\n:11\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n" ++
    "$7\r\nmodules\r\n*5\r\n%4\r\n$4\r\nname\r\n$6\r\nsearch\r\n$3\r\nver\r\n:81001\r\n$4\r\n" ++
    "path\r\n$43\r\n/usr/local/lib/redis/modules//redisearch.so\r\n$4\r\nargs\r\n*0\r\n%4\r\n" ++
    "$4\r\nname\r\n$2\r\nbf\r\n$3\r\nver\r\n:81001\r\n$4\r\npath\r\n$43\r\n" ++
    "/usr/local/lib/redis/modules//redisbloom.so\r\n$4\r\nargs\r\n*0\r\n%4\r\n$4\r\nname\r\n" ++
    "$9\r\nvectorset\r\n$3\r\nver\r\n:1\r\n$4\r\npath\r\n$0\r\n\r\n$4\r\nargs\r\n*0\r\n%4\r\n" ++
    "$4\r\nname\r\n$10\r\ntimeseries\r\n$3\r\nver\r\n:81001\r\n$4\r\npath\r\n$48\r\n" ++
    "/usr/local/lib/redis/modules//redistimeseries.so\r\n$4\r\nargs\r\n*0\r\n%4\r\n$4\r\n" ++
    "name\r\n$6\r\nReJSON\r\n$3\r\nver\r\n:81000\r\n$4\r\npath\r\n$39\r\n" ++
    "/usr/local/lib/redis/modules//rejson.so\r\n$4\r\nargs\r\n*0\r\n";

/// Redis 7.2.16.
pub const redis_7_2_16 =
    "%7\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$6\r\n7.2.16\r\n$5\r\nproto\r\n" ++
    ":3\r\n$2\r\nid\r\n:3\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n" ++
    "$7\r\nmodules\r\n*0\r\n";

/// Redis 6.2.24: HELLO, and a version below 7.2.
pub const redis_6_2_24 =
    "%7\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$6\r\n6.2.24\r\n$5\r\nproto\r\n" ++
    ":3\r\n$2\r\nid\r\n:3\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n" ++
    "$7\r\nmodules\r\n*0\r\n";

/// Valkey 9.1.2 with availability-zone set: a map of 8.
pub const valkey_9_1_2 =
    "%8\r\n$6\r\nserver\r\n$6\r\nvalkey\r\n$7\r\nversion\r\n$5\r\n9.1.2\r\n$5\r\nproto\r\n" ++
    ":3\r\n$2\r\nid\r\n:3\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n" ++
    "$7\r\nmodules\r\n*1\r\n%4\r\n$4\r\nname\r\n$3\r\nlua\r\n$3\r\nver\r\n:1\r\n$4\r\npath\r\n" ++
    "$3\r\nlua\r\n$4\r\nargs\r\n*0\r\n$17\r\navailability_zone\r\n$10\r\nus-east-1a\r\n";

/// Valkey 9.1.2 with extended-redis-compatibility yes.
pub const valkey_compatible =
    "%7\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$5\r\n7.2.4\r\n$5\r\nproto\r\n:3\r\n" ++
    "$2\r\nid\r\n:3\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n$7\r\n" ++
    "modules\r\n*1\r\n%4\r\n$4\r\nname\r\n$3\r\nlua\r\n$3\r\nver\r\n:1\r\n$4\r\npath\r\n$3\r\n" ++
    "lua\r\n$4\r\nargs\r\n*0\r\n";

/// Redis 8.10.2 with cluster-enabled yes.
pub const redis_cluster =
    "%7\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$6\r\n8.10.2\r\n$5\r\nproto\r\n" ++
    ":3\r\n$2\r\nid\r\n:11\r\n$4\r\nmode\r\n$7\r\ncluster\r\n$4\r\nrole\r\n$6\r\nmaster\r\n" ++
    "$7\r\nmodules\r\n*5\r\n%4\r\n$4\r\nname\r\n$2\r\nbf\r\n$3\r\nver\r\n:81001\r\n$4\r\n" ++
    "path\r\n$43\r\n/usr/local/lib/redis/modules//redisbloom.so\r\n$4\r\nargs\r\n*0\r\n%4\r\n" ++
    "$4\r\nname\r\n$9\r\nvectorset\r\n$3\r\nver\r\n:1\r\n$4\r\npath\r\n$0\r\n\r\n$4\r\nargs\r\n" ++
    "*0\r\n%4\r\n$4\r\nname\r\n$10\r\ntimeseries\r\n$3\r\nver\r\n:81001\r\n$4\r\npath\r\n" ++
    "$48\r\n/usr/local/lib/redis/modules//redistimeseries.so\r\n$4\r\nargs\r\n*0\r\n%4\r\n" ++
    "$4\r\nname\r\n$6\r\nsearch\r\n$3\r\nver\r\n:81001\r\n$4\r\npath\r\n$43\r\n" ++
    "/usr/local/lib/redis/modules//redisearch.so\r\n$4\r\nargs\r\n*0\r\n%4\r\n$4\r\nname\r\n" ++
    "$6\r\nReJSON\r\n$3\r\nver\r\n:81000\r\n$4\r\npath\r\n$39\r\n" ++
    "/usr/local/lib/redis/modules//rejson.so\r\n$4\r\nargs\r\n*0\r\n";

/// Redis 8.10.2 as a replica (replicaof).
pub const redis_replica =
    "%7\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$6\r\n8.10.2\r\n$5\r\nproto\r\n" ++
    ":3\r\n$2\r\nid\r\n:11\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$7\r\n" ++
    "replica\r\n$7\r\nmodules\r\n*5\r\n%4\r\n$4\r\nname\r\n$10\r\ntimeseries\r\n$3\r\nver\r\n" ++
    ":81001\r\n$4\r\npath\r\n$48\r\n/usr/local/lib/redis/modules//redistimeseries.so\r\n$4\r\n" ++
    "args\r\n*0\r\n%4\r\n$4\r\nname\r\n$6\r\nsearch\r\n$3\r\nver\r\n:81001\r\n$4\r\npath\r\n" ++
    "$43\r\n/usr/local/lib/redis/modules//redisearch.so\r\n$4\r\nargs\r\n*0\r\n%4\r\n$4\r\n" ++
    "name\r\n$2\r\nbf\r\n$3\r\nver\r\n:81001\r\n$4\r\npath\r\n$43\r\n" ++
    "/usr/local/lib/redis/modules//redisbloom.so\r\n$4\r\nargs\r\n*0\r\n%4\r\n$4\r\nname\r\n" ++
    "$9\r\nvectorset\r\n$3\r\nver\r\n:1\r\n$4\r\npath\r\n$0\r\n\r\n$4\r\nargs\r\n*0\r\n%4\r\n" ++
    "$4\r\nname\r\n$6\r\nReJSON\r\n$3\r\nver\r\n:81000\r\n$4\r\npath\r\n$39\r\n" ++
    "/usr/local/lib/redis/modules//rejson.so\r\n$4\r\nargs\r\n*0\r\n";

/// Redis 8.10.2 as a Sentinel: no role.
pub const sentinel =
    "%6\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$6\r\n8.10.2\r\n$5\r\nproto\r\n" ++
    ":3\r\n$2\r\nid\r\n:3\r\n$4\r\nmode\r\n$8\r\nsentinel\r\n$7\r\nmodules\r\n*0\r\n";

/// Redis 5.0.14 to HELLO 3.
pub const redis_5_unknown =
    "-ERR unknown command `HELLO`, with args beginning with: `3`, \r\n";

/// Redis 5.0.14 to HELLO 3 AUTH default secret: it quotes the password.
pub const redis_5_unknown_auth =
    "-ERR unknown command `HELLO`, with args beginning with: `3`, `AUTH`, `default`, `secret`, \r\n";

/// Redis 8.10.2 with requirepass, to HELLO 3 without AUTH.
pub const noauth =
    "-NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO <proto> AUTH <user> <pass> option can be used to authenticate the client and select the RESP protocol version at the same time\r\n";

/// Redis 8.10.2 with requirepass, to HELLO 3 AUTH default wrong.
pub const wrongpass =
    "-WRONGPASS invalid username-password pair or user is disabled.\r\n";

/// Redis 8.10.2 and Valkey 9.1.2 to SELECT 20.
pub const select_out_of_range =
    "-ERR DB index is out of range\r\n";

/// Redis 6.2.24 to CLIENT SETINFO.
pub const setinfo_unknown =
    "-ERR Unknown subcommand or wrong number of arguments for 'SETINFO'. Try CLIENT HELP.\r\n";
