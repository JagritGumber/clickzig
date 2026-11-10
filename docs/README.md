# clickzig documentation

This directory contains user-facing documentation for clickzig on Zig 0.17.
The README at the repository root is the quick overview; these pages are the
working reference.

## Guides

- [Getting started](getting-started.md): install, connect, query, insert, and run smoke tests.
- [API guide](api.md): public types, common call patterns, async usage, and cancellation.
- [Type mapping](types.md): ClickHouse type names and the corresponding `clickzig.Column` shapes.
- [Operations](operations.md): ClickHouse service setup, smoke scenarios, CI gates, pooling, TLS, and branch policy.
- [Security](security.md): defensive limits, timeout behavior, hostile-input probes, and supported wire assumptions.

## Version line

`main` targets Zig 0.17; the `0.16.0` branch keeps the Zig 0.16 line. The package version is intentionally
aligned with the Zig compiler line rather than a separate semver release train.
No tag or release should be created unless the maintainer explicitly decides to
publish one.
