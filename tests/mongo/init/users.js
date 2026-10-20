// The users of mongo-auth. The image of mongo runs this file at every start
// of the container, whose database starts empty, on a temporary mongod
// without --auth, before the mongod of the tests starts.
const admin = db.getSiblingDB("admin");
admin.createUser({ user: "sha1", pwd: "sha1-pass", roles: ["root"], mechanisms: ["SCRAM-SHA-1"] });
admin.createUser({ user: "sha256", pwd: "sha256-pass", roles: ["root"], mechanisms: ["SCRAM-SHA-256"] });
admin.createUser({ user: "both", pwd: "both-pass", roles: ["root"], mechanisms: ["SCRAM-SHA-1", "SCRAM-SHA-256"] });

// The users of SASLprep in MongoDB's authentication specification. The
// server prepares their passwords for SCRAM-SHA-256; the driver prepares
// printable ASCII only, so IX with the password IX gets in, and Ⅸ
// (U+2168) with Ⅳ (U+2163) is refused before anything is sent.
admin.createUser({ user: "IX", pwd: "IX", roles: ["root"], mechanisms: ["SCRAM-SHA-256"] });
admin.createUser({ user: "Ⅸ", pwd: "Ⅳ", roles: ["root"], mechanisms: ["SCRAM-SHA-256"] });

// A user of its own database, where the connection string's path sends
// authentication: mongodb://app:app-pass@127.0.0.1:27118/app
db.getSiblingDB("app").createUser({ user: "app", pwd: "app-pass", roles: [{ role: "readWrite", db: "app" }] });
