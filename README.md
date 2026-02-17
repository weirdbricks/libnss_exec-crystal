# libnss_exec — Crystal Implementation

A Name Service Switch (NSS) module that delegates user, group, and shadow lookups to an external script. Crystal port of [tests-always-included/libnss_exec](https://github.com/tests-always-included/libnss_exec) with memory-safety improvements and idiomatic Crystal code.

[![CI](https://github.com/weirdbricks/libnss_exec-crystal/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR_USERNAME/libnss_exec-crystal/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

## What does it do?

When you add `exec` to `/etc/nsswitch.conf`, glibc calls this shared library for user/group lookups. The library executes `/sbin/nss_exec` with a command and argument, parses the colon-delimited output, and returns the result to glibc.

Use cases: mapping all users to a single UID, querying a remote API, integrating with a custom database, logging authentication attempts, testing.

## Prerequisites

- Crystal >= 1.0.0 (`curl -fsSL https://crystal-lang.org/install.sh | sudo bash`)
- Linux with glibc
- Root access for installation

## Quick start

```bash
# Build
make

# Run unit tests (no root needed)
make spec

# Install (as root)
sudo make install

# Create and enable your script
sudo install -m 755 examples/nss_exec.sh /sbin/nss_exec

# Edit /etc/nsswitch.conf — add 'exec' AFTER existing sources:
#   passwd: files systemd exec
#   group:  files systemd exec
#   shadow: files exec

# Test
getent passwd testuser
```

## Project structure

```
├── src/
│   ├── nss_types.cr      # Entry types, BufferWriter, LibC struct bindings
│   ├── nss_exec.cr        # Script execution, shell escaping, status mapping
│   ├── nss_passwd.cr      # passwd NSS functions + C exports
│   ├── nss_group.cr       # group NSS functions + C exports
│   └── nss_shadow.cr      # shadow NSS functions + C exports
├── spec/
│   └── nss_types_spec.cr  # Unit tests for parsing and buffer management
├── examples/
│   └── nss_exec.sh        # Example /sbin/nss_exec script
├── .github/workflows/
│   └── ci.yml             # GitHub Actions: build + spec + lint
├── .ameba.yml             # Ameba linter configuration
├── shard.yml              # Crystal dependency manifest
├── Makefile               # Build, test, lint, install
└── LICENSE
```

## Building

| Command | Description |
|---------|-------------|
| `make` | Build `libnss_exec.so.2` |
| `make spec` | Run Crystal spec suite |
| `make lint` | Run Ameba static analysis |
| `make check` | Verify formatting (non-destructive) |
| `make format` | Auto-format source |
| `make install` | Install to system (needs root) |
| `make uninstall` | Remove from system |
| `make help` | Show all targets |

## Writing your script

The script at `/sbin/nss_exec` receives two arguments: a command name and an optional parameter. It prints one line to stdout and exits with a status code.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Entry found (print it to stdout) |
| 1 | Not found |
| 2 | Temporary failure, retry |
| 3+ | Service unavailable |

**Output formats:**

```
# passwd — name:passwd:uid:gid:gecos:dir:shell
alice:x:1001:1001:Alice Smith:/home/alice:/bin/zsh

# group — name:passwd:gid:member1,member2
developers:x:2000:alice,bob

# shadow — name:passwd:lastchg:min:max:warn:inact:expire:flag
alice:$6$...:18500:0:99999:7:::
```

See `examples/nss_exec.sh` for a complete working example.

## Security notes

- User input is shell-escaped before being passed to the script (prevents injection).
- The script runs with the privileges of the calling process.
- Shadow lookups require root.
- Consider caching with `nscd` or `unscd` — NSS lookups happen frequently.

## License

MIT — see [LICENSE](./LICENSE). Original C implementation by Tyler Akins.
