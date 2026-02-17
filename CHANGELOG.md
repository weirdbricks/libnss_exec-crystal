# Changelog

All notable changes to libnss_exec-crystal are documented here.

## [3.0.0] — 2026-02-17

**Complete rewrite: no-GC, single-file, dlopen-safe.**

Crystal's runtime (GC, fiber scheduler, signal handlers) cannot be safely
initialized when glibc loads an NSS module via `dlopen()`. v2.x attempted
workarounds (`GC.init` on first call) but these were insufficient — the
runtime has many lazy initialization paths that all crash.

v3.0.0 eliminates the problem entirely by using only raw C library calls.

### Changed
- Single source file: `src/libnss_exec.cr` (was 5 files)
- All parsing uses `strtoul`/`strtol` + manual field splitting (no Crystal `String`)
- All output written into glibc's caller-provided buffer (zero heap allocations)
- Wrapping arithmetic (`&+`, `&-`) throughout to prevent `OverflowError`
- `fork`/`execve` with close-on-exec pipe FDs
- `waitpid` retries on `EINTR`
- Configurable script path via `NSS_EXEC_SCRIPT` environment variable
  (defaults to `/sbin/nss_exec`)

### Removed
- Crystal specs (replaced by stress test data integrity checks)
- Multi-file module structure
- CI workflow (to be re-added)
- `GC.init` hack from v2.x

### Testing
- `test/stress_test.sh`: 15 tests covering script execution, NSS integration,
  concurrency, edge cases, and data integrity
- Verified: 1000 lookups × 20 workers, 0 failures (Alma 9, Crystal 1.19.1)

## [2.2.0] — 2026-02-17

### Added
- Thread safety: Mutex protection for enumeration state
- `fork`/`execve` replacing `popen` (no shell, direct argv, minimal environment)
- Test infrastructure: `generate_test_data.sh`, `stress_test.sh`
- Shellcheck-clean test scripts

### Fixed
- 7 critical bugs: memory leaks, GC issues, ABI mismatches
- Proper POSIX file operations in test scripts

## [2.1.0] — 2026-02-17

### Added
- Ameba linter integration
- Crystal spec suite (28 specs)
- CI workflow

### Fixed
- Memory safety: all strings copied into caller's buffer
- GC safety: no Crystal objects exposed to C

## [2.0.0] — 2026-02-17

Initial Crystal port of [libnss_exec](https://github.com/tests-always-included/libnss_exec).

### Added
- Full NSS module: passwd, group, shadow (14 entry points)
- `BufferWriter` for safe buffer management
- Parsed entry types with `fill_c_struct` methods
- Example script, Makefile, documentation
