# Test Plan — libnss_exec-crystal

Version 3.0.0 | February 2026

---

## Overview

This document describes the full test strategy for libnss_exec-crystal v3.0.0.
Testing is organized in three tiers that build on each other.

**Tier 1: Build verification** — builds and checks symbols, no root needed.
**Tier 2: Script-level stress tests** — exercises the nss_exec script with generated data, no NSS integration needed.
**Tier 3: NSS integration tests** — full end-to-end through glibc, requires root and system configuration.

---

## Prerequisites

- Crystal >= 1.0.0
- Linux with glibc (tested on Alma 9, Ubuntu 22.04+, Debian 12+)
- bash >= 4.0 (for `mapfile`, associative arrays)
- Standard tools: shuf, awk, grep, bc, wc, head, date
- Root access (Tier 3 only)
- A throwaway VM or container is strongly recommended for Tier 3

---

## Tier 1: Build Verification

No root needed. Run on every commit.

### 1.1 Build the shared library

    make

Compiles `src/libnss_exec.cr` into `libnss_exec.so.2` with `--release --no-debug`.

**Pass criteria:** exit code 0, file `libnss_exec.so.2` exists and is > 0 bytes.

### 1.2 Symbol verification

    make symbols

Confirms all 14 expected NSS entry points are exported:

- `_nss_exec_setpwent`, `_nss_exec_endpwent`, `_nss_exec_getpwent_r`, `_nss_exec_getpwuid_r`, `_nss_exec_getpwnam_r`
- `_nss_exec_setgrent`, `_nss_exec_endgrent`, `_nss_exec_getgrent_r`, `_nss_exec_getgrgid_r`, `_nss_exec_getgrnam_r`
- `_nss_exec_setspent`, `_nss_exec_endspent`, `_nss_exec_getspent_r`, `_nss_exec_getspnam_r`

**Pass criteria:** 14 symbols present in `nm -D` output.

### 1.3 Formatting check

    make check

Verifies source conforms to Crystal's canonical formatting.

**Pass criteria:** exit code 0.

### 1.4 Library load test

    python3 -c "import ctypes; ctypes.CDLL('./libnss_exec.so.2'); print('OK')"

Verifies the .so can be loaded via `dlopen()` without crashing. This is the fundamental test that v3.0.0's no-GC architecture enables.

**Pass criteria:** prints "OK", no segfault.

---

## Tier 2: Script-Level Stress Tests

Tests the nss_exec script and data pipeline without touching the system NSS configuration. Safe to run anywhere. No root needed.

### 2.0 Generate test data

    cd test/
    ./generate_test_data.sh -u 1000 -g 100 -m 20

Creates `test_data/` containing:
- `passwd.db` — 1000 user entries
- `shadow.db` — 1000 shadow entries
- `group.db` — 100 group entries (1–20 random members each)
- `usernames.txt`, `groupnames.txt` — lookup lists
- `nss_exec` — a self-contained bash script that serves the flat files

Configurable: `-u NUM_USERS`, `-g NUM_GROUPS`, `-m MAX_MEMBERS`, `-o OUTPUT_DIR`.

### 2.1 Run stress tests (script-only mode)

    ./stress_test.sh -d ./test_data -N -n 500 -c 10

The `-N` flag skips NSS integration tests.

#### Preflight checks (automatic)

Before any test phase, the script verifies all data files exist, the script is executable and passes a smoke test, and all required CLI tools are available.

#### Phase 1: Sequential script execution

| Test | What it does | Pass criteria |
|------|-------------|---------------|
| 1a. getpwnam | Look up N random users by name | 0 failures |
| 1b. getpwuid | Look up N random UIDs | 0 failures |
| 1c. getgrnam | Look up N random groups by name | 0 failures |
| 1d. getpwent | Walk all users by index 0..N | Count matches total users |
| 1e. not-found | Look up N nonexistent users | All return exit code 1 |

#### Phase 2: Concurrent script execution

| Test | What it does | Pass criteria |
|------|-------------|---------------|
| 2a. concurrent getpwnam | N lookups across C parallel workers | 0 failures |
| 2b. mixed concurrent | Passwd + group lookups simultaneously | 0 failures |

#### Phase 4: Edge cases

| Test | What it does | Pass criteria |
|------|-------------|---------------|
| 4a. edge-case lookups | Empty string, whitespace, shell metacharacters, path traversal, colons | No crash |
| 4b. set/get/end cycles | 100 rapid setpwent/getpwent/endpwent cycles | No crash |

**Overall pass criteria:** all phases report 0 failures, exit code 0.

### 2.2 Scale testing

    # Medium scale
    ./generate_test_data.sh -u 5000 -g 500 -m 50
    ./stress_test.sh -N -n 2000 -c 20

    # Large scale
    ./generate_test_data.sh -u 10000 -g 1000 -m 100
    ./stress_test.sh -N -n 5000 -c 50

Watch for: increasing response times, OOM, file descriptor exhaustion.

---

## Tier 3: NSS Integration Tests

Full end-to-end testing through glibc's NSS machinery. **Requires root. Use a throwaway VM or container.**

### 3.0 Setup — Step by step

#### Step 1: Prepare a test instance

Use a disposable environment:

    # Option A: local VM
    multipass launch --name nss-test 22.04
    multipass shell nss-test

    # Option B: Docker (build testing; NSS integration is limited in containers)
    docker run -it --privileged ubuntu:22.04 bash

    # Option C: cloud instance (EC2, GCE, etc.)

#### Step 2: Install Crystal on the test instance

    # Ubuntu / Debian
    curl -fsSL https://crystal-lang.org/install.sh | sudo bash

    # Alma / RHEL / Fedora
    sudo dnf install crystal

    crystal --version

#### Step 3: Clone the repo and build

    git clone <repo_url>
    cd libnss_exec-crystal

    make
    make symbols
    file libnss_exec.so.2     # Should show: ELF 64-bit LSB shared object

#### Step 4: Install the shared library

    sudo make install

    # Verify
    ldconfig -p | grep nss_exec
    # If not shown, force: sudo ldconfig

#### Step 5: Generate test data

    cd test/
    ./generate_test_data.sh -u 1000 -g 100

    # Sanity check
    ./test_data/nss_exec getpwnam "$(head -1 test_data/usernames.txt)"

#### Step 6: Install the nss_exec script

    sudo cp test_data/nss_exec /sbin/nss_exec
    sudo chmod 755 /sbin/nss_exec

    # The generated script has the absolute data directory path baked in at
    # generation time. No environment variable needed.

    # Verify
    sudo /sbin/nss_exec getpwnam "$(head -1 test_data/usernames.txt)"

#### Step 7: Open an escape hatch

**Before touching nsswitch.conf, open a separate root shell and leave it open.**
If you break name resolution, you won't be able to `sudo` or `su` in other terminals.

    # In a SEPARATE terminal / tmux pane:
    sudo -i
    # Leave this shell open until testing is complete.

#### Step 8: Configure nsswitch.conf

    sudo cp /etc/nsswitch.conf /etc/nsswitch.conf.backup
    sudo vi /etc/nsswitch.conf

The relevant lines should look like this:

    passwd: files systemd exec
    group:  files systemd exec
    shadow: files exec

**Critical:** `files` must come before `exec`.

#### Step 9: Verify nothing is broken

    getent passwd root
    getent passwd "$(whoami)"
    id root
    getent passwd "$(head -1 test_data/usernames.txt)"

    # If anything went wrong, in your escape-hatch shell:
    #   cp /etc/nsswitch.conf.backup /etc/nsswitch.conf

### 3.1 Preflight checks (automatic)

When running stress_test.sh without `-N`, it automatically verifies:
- `libnss_exec.so.2` is installed (checks common lib paths + ldconfig)
- `/sbin/nss_exec` exists and is executable
- `nsswitch.conf` has `exec` in passwd, group, shadow lines
- `files` appears before `exec` in each line
- `getent passwd root` still works
- A test user resolves via `getent`

### 3.2 Run full stress test

    ./stress_test.sh -d ./test_data -n 500 -c 10

This runs all of Tier 2 plus:

#### Phase 3: NSS integration

| Test | What it does | Pass criteria |
|------|-------------|---------------|
| 3a. getent passwd by name | N random lookups via getent | 0 failures |
| 3b. getent group by name | N random lookups via getent | 0 failures |
| 3c. full enumeration | `getent passwd` (all entries) | Count >= total test users |
| 3d. system user sanity | Resolve root and nobody | Both resolve |
| 3e. concurrent getent | N lookups across C workers via getent | 0 failures |
| 3f. data integrity | Compare script output vs getent for 100 users | Exact match |

**Pass criteria:** all 15 tests pass, exit code 0.

### 3.3 Heavy load test

    ./stress_test.sh -d ./test_data -n 1000 -c 20

Verified passing on Alma 9 with Crystal 1.19.1:
- 1000 lookups per phase, 20 concurrent workers
- 15/15 tests passed, 0 failures
- ~200 ops/sec passwd, ~1300 ops/sec group
- Total time: ~52 seconds

### 3.4 Cleanup / rollback

    sudo cp /etc/nsswitch.conf.backup /etc/nsswitch.conf
    sudo make uninstall
    sudo rm /sbin/nss_exec
    getent passwd root  # Verify system is back to normal

---

## What Is NOT Tested (and Why)

- **Crystal unit specs:** v3.0.0 uses raw C calls only. The parsing logic is tested indirectly through the stress tests, which verify data integrity (script output vs getent output) for hundreds of entries.
- **SELinux/AppArmor:** environment-specific; document as a manual step for production.
- **32-bit architectures:** Crystal's 32-bit support is limited.
- **musl libc:** NSS is a glibc concept; musl does not support NSS modules.
- **nscd caching:** add `sudo apt install nscd && sudo systemctl start nscd` to test cached lookups manually.
- **Actual authentication (su/sudo/sshd):** limit to `getent` and `id` which are read-only.

---

## Quick Reference

    # Tier 1 (every commit)
    make && make symbols && make check

    # Tier 2 (script-only, no root)
    cd test && ./generate_test_data.sh && ./stress_test.sh -N

    # Tier 3 (throwaway VM, root required)
    cd test && ./stress_test.sh -n 1000 -c 20
