# Code Review: libnss_exec-crystal v2.0 → v2.1

Reviewed by: Claude Opus 4.6
Date: 2026-02-16
Scope: Full review of all Crystal source, Makefile, tests, and documentation.

---

## Critical Bugs Fixed

### 1. Memory leak in every parse call

**Severity:** High — leaks memory on every NSS lookup.

The original `PasswdEntry.parse`, `GroupEntry.parse`, and `ShadowEntry.parse` all called `LibC.strdup(output.to_unsafe)` to create a mutable copy for `strtok_r`, but never called `LibC.free` on it. Since NSS lookups happen frequently (every `ls -l`, `id`, `ps`, etc.), this leaked memory continuously.

Additionally, `GroupEntry.parse` allocated `Pointer(UInt8*).malloc(100)` for member tokens — this uses Crystal's GC allocator, but the pointers stored in it reference the `strdup`'d C buffer. If the GC relocates or collects the pointer array while the C struct still references it, you get use-after-free.

**Fix:** Replaced all C-level parsing (`strtok_r`, `strdup`, `strtoul`) with Crystal's `String#split`, `String#to_u32?`, etc. Entry types now hold plain Crystal `String`s. No manual allocation, no leaks, no dangling pointers. Raw C buffers are only touched in `fill_c_struct`.

### 2. Empty group member array allocated on GC heap

**Severity:** High — potential use-after-free.

In the original `GroupEntry#fill_c_struct`, when a group had no members:

```crystal
empty_array = Pointer(UInt8*).malloc(1)
empty_array[0] = Pointer(UInt8).null
result.value.gr_mem = empty_array
```

`Pointer.malloc` allocates from Crystal's GC heap. glibc expects `gr_mem` to point into the caller-provided buffer. If the GC collects or moves this allocation, the C code segfaults.

**Fix:** Empty groups now go through `BufferWriter#write_string_array([] of String)`, which allocates the NULL-terminated pointer array inside the caller-provided buffer.

### 3. buffer_length truncated from size_t to Int32

**Severity:** Medium — correctness issue.

glibc passes `buflen` as `size_t` (64-bit on x86_64). The original code cast it to `Int32` everywhere:

```crystal
NssExec::Passwd.getpwent(result, buffer, buflen.to_i32, errnop).value
```

Buffers larger than 2 GB would silently wrap to a negative number, causing immediate ERANGE returns even with plenty of space. While 2 GB NSS buffers are unlikely in practice, the contract says `size_t` and we should honor it.

**Fix:** All internal methods now use `LibC::SizeT` for buffer sizes.

### 4. ShadowEntry used strtoul for signed fields

**Severity:** Medium — incorrect values for sentinel fields.

Shadow fields like `sp_inact` and `sp_expire` use -1 as a sentinel for "not set." The original code parsed them with `LibC.strtoul` (unsigned), which wraps -1 to `ULONG_MAX` instead of preserving the -1 semantics. The `Spwd` struct uses `Long` (signed) fields.

**Fix:** Parsing now uses Crystal's `to_i64?` which correctly handles missing/empty fields by returning nil, defaulting to -1.

### 5. Spwd struct used Int64/UInt64 instead of LibC::Long/ULong

**Severity:** Medium — ABI mismatch on 32-bit systems.

The original `Spwd` struct defined fields as `Int64`/`UInt64`, but glibc's `struct spwd` uses `long`/`unsigned long`, which is 32-bit on 32-bit systems. On a 32-bit build, every field after `sp_lstchg` would be read at the wrong offset.

**Fix:** Changed to `LibC::Long` / `LibC::ULong`, which matches the platform's `long`.

### 6. setpwent/setgrent/setspent reset index only on SUCCESS

**Severity:** Medium — broken enumeration.

If the script didn't implement `setpwent` (or the script didn't exist yet), the exec call returned UNAVAIL, and the index was never reset. A subsequent `getpwent` enumeration would start from wherever it left off last time instead of from 0.

**Fix:** `set*ent` now always resets the index to 0 and always returns SUCCESS, since the enumeration state belongs to the module, not the script. The script call is fire-and-forget.

### 7. endpwent could return UNAVAIL

**Severity:** Low — confusing for callers.

If the script didn't handle `endpwent`, the module returned UNAVAIL. glibc doesn't really check this return value, but it's semantically wrong — ending enumeration should always succeed.

**Fix:** `end*ent` now always returns SUCCESS.

### 8. rescue blocks in FFI exports didn't set errno

**Severity:** Low — could confuse callers that check errno.

The original `rescue` blocks in the C-exported functions returned UNAVAIL but left `errnop` untouched (potentially containing stale data).

**Fix:** All `rescue` blocks now set `errnop.value = LibC::ENOENT` before returning UNAVAIL.

---

## Design Improvements

### Entry types changed from class to record/struct

The original used `class` with mutable `property` for entries. Since entries are parsed once and never modified, `record` (which generates a struct) is more appropriate — no heap allocation, no GC pressure, value semantics.

### BufferWriter changed from class to struct

Same rationale. The writer is created on the stack, used once, and discarded. No reason for it to be heap-allocated.

### Pointer alignment in BufferWriter

Added `align_to` before writing pointer arrays. On architectures with strict alignment (ARM, SPARC), writing a `UInt8**` array at an unaligned address causes SIGBUS. x86 tolerates misalignment but with a performance penalty.

### Wrapping arithmetic in BufferWriter

Changed arithmetic operations in BufferWriter to use `&+`, `&-`, `&*` (wrapping operators) to avoid unnecessary overflow checks in a hot path where we've already validated bounds.

### Removed unnecessary LibC bindings

The original imported `strtok_r`, `strdup`, `strlen`, `strcpy`, `snprintf` — none of which are needed now that parsing uses Crystal strings.

### Consistent error errno: ENOENT vs ERANGE

The original set `errnop = ERANGE` for parse failures, which tells glibc "try again with a bigger buffer." But a parse failure (malformed output) won't be fixed by a bigger buffer — it should be `ENOENT`. Reserved `ERANGE` for the actual "buffer too small" case only.

---

## Tooling & Infrastructure Added

### Ameba linter integration

Added `.ameba.yml` config and `make lint` target. Ameba catches common Crystal issues: shadowed variables, unreachable code, unused assignments, etc. Configured to allow the intentional patterns in this codebase (class variables for state, bare rescue in FFI boundaries).

### Crystal spec test suite

Replaced the ad-hoc `test_nss_exec.cr` with proper specs in `spec/nss_types_spec.cr` using Crystal's built-in spec framework. Tests cover:

- Parsing valid/invalid/edge-case inputs for all three entry types
- fill_c_struct success and ERANGE paths
- BufferWriter string and array writing
- Empty member arrays

Run with `make spec` (no root needed).

### shard.yml

Added proper Crystal shard manifest so `shards install` can pull Ameba and any future dependencies.

### GitHub Actions CI

`.github/workflows/ci.yml` runs on push/PR:

1. Format check
2. Ameba lint
3. Crystal spec
4. Shared library build
5. Symbol verification (ensures all _nss_exec_* symbols are exported)

Tests against Crystal latest and 1.14.

### .gitignore

Covers Crystal build artifacts, shard deps, editor files, and OS detritus.

### Project restructured to src/ + spec/

Moved source files into `src/` and tests into `spec/`, following Crystal community conventions.

---

## What's left to do

These are beyond the scope of this review but worth tracking:

1. **Integration tests**: The spec suite tests parsing and buffer management but not actual script execution. A test that creates a temp script, calls exec_script, and validates the round-trip would be valuable.

2. **Thread safety**: The `@@ent_index` class variables are not mutex-protected. The original code had a comment saying "NSS handles thread safety" — this is partially true (glibc serializes `set/get/end` calls per database), but if a program calls the _r functions directly without the wrappers, concurrent access to `@@ent_index` is a data race. Consider adding `Mutex` back.

3. **Configurable script path**: Currently hardcoded to `/sbin/nss_exec`. Reading from `/etc/nss_exec.conf` or an environment variable at init time would make deployment more flexible.

4. **Logging**: A debug log (controlled by env var) would greatly help production troubleshooting. Could write to syslog.

5. **Replace popen with fork/exec**: `popen` invokes `/bin/sh -c`, which is an extra process and a potential attack surface. Direct `fork`/`execve` would be faster and safer.
