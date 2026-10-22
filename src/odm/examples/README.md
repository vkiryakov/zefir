# odm

**A typed ODM for MongoDB, for Zig services with many tenants.** A model is
a plain Zig struct; a filter, an update or a sort is a literal that the
compiler checks against it; one registry keeps the connections and the
tenants of a service, and changes a connection while requests go on.

## Contents

- [What an ODM is](#what-an-odm-is)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Models](#models)
- [Reading](#reading)
- [Changing documents](#changing-documents)
- [Tenants](#tenants)
- [Connections and credentials](#connections-and-credentials)
- [Errors and what is safe to retry](#errors-and-what-is-safe-to-retry)
- [Shutdown, statistics and logs](#shutdown-statistics-and-logs)
- [Security](#security)
- [Tests without MongoDB](#tests-without-mongodb)
- [For authors of drivers](#for-authors-of-drivers)
