# Quant

Quant is a monorepo containing the iOS application and its private analysis
server. Each application remains independently buildable and keeps its own
documentation and development commands.

## Repository layout

```text
apps/
  ios/       Quant for iPhone, its widget, and its test targets
  server/    Quant Server, container configuration, and deployment scripts
```

The iOS architecture is documented in
[`apps/ios/ARCHITECTURE.md`](apps/ios/ARCHITECTURE.md). Server setup and API
details live in [`apps/server/README.md`](apps/server/README.md).

## Development commands

Run `make help` at the repository root for the shared entry points. Root
commands are namespaced by application and delegate to the unchanged Makefile
inside that application:

```sh
make ios-build
make ios-test TEST_TARGET=QuantTests
make server-test
make server-docker-build
make server-config
```

The original commands also continue to work from the application directories:

```sh
make -C apps/ios help
make -C apps/server help
```
