# libnss_exec-crystal

A glibc NSS module written in Crystal that delegates passwd, group, and shadow
lookups to an external script (`/sbin/nss_exec`). Crystal port of
[tests-always-included/libnss_exec](https://github.com/tests-always-included/libnss_exec).

## v3.0.0 — No-GC rewrite

This version is a complete rewrite using only raw C library calls. No Crystal
GC, no runtime, no hidden allocations. This makes the shared library safe for
`dlopen()` loading by glibc, which is how NSS modules are loaded.

### Architecture

The entire module is a single file (`src/libnss_exec.cr`) that:

- Parses colon-delimited NSS entries using `strtoul`/`strtol` and manual field splitting
- Writes all output into glibc's caller-provided buffer (zero heap allocations)
- Executes `/sbin/nss_exec` via `fork`/`execve` (no shell, no injection risk)
- Uses wrapping arithmetic (`&+`, `&-`) throughout to prevent overflow exceptions
- Exports 14 standard NSS entry points (`_nss_exec_getpwnam_r`, etc.)

### Why not use Crystal's standard library?

Crystal's stdlib assumes it owns the process — it initializes a GC, fiber
scheduler, signal handlers, and more. When glibc loads an NSS module via
`dlopen()`, none of that initialization happens, causing segfaults on the
first string allocation. v3.0.0 eliminates this entire class of bugs by
not depending on the Crystal runtime at all.

## Building

Requires Crystal >= 1.0.0 and Linux with glibc.

    make                # Build libnss_exec.so.2
    make symbols        # Verify exported NSS entry points
    make format         # Auto-format source

## Installation

    # Build and install the library
    sudo make install

    # Install your lookup script
    sudo cp examples/nss_exec.sh /sbin/nss_exec
    sudo chmod 755 /sbin/nss_exec

    # Configure NSS (add 'exec' AFTER 'files')
    # passwd: files systemd exec
    # group:  files systemd exec
    # shadow: files exec
    sudo vi /etc/nsswitch.conf

    # Test
    getent passwd testuser

See [TEST_PLAN.md](TEST_PLAN.md) for detailed installation and testing
instructions, including a step-by-step guide for setting up a test VM.

## Script interface

The module calls `/sbin/nss_exec` (or the path in `$NSS_EXEC_SCRIPT`) with
a command and optional argument:

    /sbin/nss_exec getpwnam <username>    # Lookup user by name
    /sbin/nss_exec getpwuid <uid>         # Lookup user by UID
    /sbin/nss_exec getgrnam <groupname>   # Lookup group by name
    /sbin/nss_exec getgrgid <gid>         # Lookup group by GID
    /sbin/nss_exec getspnam <username>    # Lookup shadow by name
    /sbin/nss_exec getpwent <index>       # Enumerate passwd entry N
    /sbin/nss_exec getgrent <index>       # Enumerate group entry N
    /sbin/nss_exec getspent <index>       # Enumerate shadow entry N
    /sbin/nss_exec setpwent               # Begin passwd enumeration
    /sbin/nss_exec endpwent               # End passwd enumeration
    (same for setgrent/endgrent, setspent/endspent)

Exit codes: 0 = found, 1 = not found, 2 = try again, other = unavailable.

Output format (one line to stdout):

    passwd: name:passwd:uid:gid:gecos:dir:shell
    group:  name:passwd:gid:member1,member2,...
    shadow: name:passwd:lastchg:min:max:warn:inact:expire:flag

## Configuration

The script path defaults to `/sbin/nss_exec`. Override it by setting the
`NSS_EXEC_SCRIPT` environment variable:

    NSS_EXEC_SCRIPT=/usr/local/bin/my_nss_script

This is mainly useful for testing without root. In production, the default
path is recommended.

## Testing

    # Generate test data (1000 users, 100 groups)
    cd test
    ./generate_test_data.sh -u 1000 -g 100

    # Script-only stress test (no root needed)
    ./stress_test.sh -d ./test_data -N

    # Full NSS integration test (requires root, installed library)
    ./stress_test.sh -d ./test_data -n 1000 -c 20

See [TEST_PLAN.md](TEST_PLAN.md) for the complete test plan.

## Project structure

    src/libnss_exec.cr         Single-file NSS module (no GC, no runtime)
    test/generate_test_data.sh Generates randomized test data + lookup script
    test/stress_test.sh        Comprehensive stress test suite
    examples/nss_exec.sh       Example lookup script
    TEST_PLAN.md               Full test plan with installation guide
    CHANGELOG.md               Version history
    Makefile                   Build, install, format, lint

## License

MIT — see [LICENSE](LICENSE).
