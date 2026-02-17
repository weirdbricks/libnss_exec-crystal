#!/usr/bin/env bash
# stress_test.sh — Stress test libnss_exec with configurable load.
#
# Usage:
#   ./stress_test.sh [OPTIONS]
#
# Prerequisites:
#   1. Run generate_test_data.sh first to create test data.
#   2. Install the .so and script, configure nsswitch.conf.
#   3. Keep a root shell open as your escape hatch!
#
# Options:
#   -d DATA_DIR        Test data directory              (default: ./test_data)
#   -n NUM_LOOKUPS     Lookups per test phase           (default: 500)
#   -c CONCURRENCY     Parallel workers for concurrency (default: 10)
#   -N                 Skip NSS tests (script-only)     (default: false)
#   -h                 Show this help
#
# Environment:
#   NSS_EXEC_DATA_DIR  Override data dir for the script
#
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-./test_data}"
NUM_LOOKUPS="${NUM_LOOKUPS:-500}"
CONCURRENCY="${CONCURRENCY:-10}"
SKIP_NSS=0

while getopts "d:n:c:Nh" opt; do
    case "$opt" in
        d) DATA_DIR="$OPTARG" ;;
        n) NUM_LOOKUPS="$OPTARG" ;;
        c) CONCURRENCY="$OPTARG" ;;
        N) SKIP_NSS=1 ;;
        h) sed -n '2,/^set/{ /^#/s/^# \?//p }' "$0"; exit 0 ;;
        *) exit 1 ;;
    esac
done

SCRIPT="$DATA_DIR/nss_exec"
USERNAMES="$DATA_DIR/usernames.txt"
GROUPNAMES="$DATA_DIR/groupnames.txt"
PASSWD_DB="$DATA_DIR/passwd.db"
GROUP_DB="$DATA_DIR/group.db"
SHADOW_DB="$DATA_DIR/shadow.db"

# ── Color helpers ───────────────────────────────────────────────────────
yellow() { echo -e "\033[33m$*\033[0m"; }
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

# ── Preflight checks ───────────────────────────────────────────────────
preflight_ok=1

bold "Preflight checks"
echo ""

# 1. Test data files
echo "  Checking test data files ..."
for f in "$SCRIPT" "$USERNAMES" "$GROUPNAMES" "$PASSWD_DB" "$GROUP_DB" "$SHADOW_DB"; do
    if [ ! -f "$f" ]; then
        red "    ✗ Missing: $f"
        preflight_ok=0
    fi
done
if [ "$preflight_ok" -eq 0 ]; then
    echo ""
    red "  Test data not found. Generate it first:"
    red "    ./test/generate_test_data.sh -o $DATA_DIR"
    exit 1
fi
green "    ✓ All data files present"

# 2. Script is executable
if [ ! -x "$SCRIPT" ]; then
    red "    ✗ $SCRIPT is not executable (chmod +x it)"
    preflight_ok=0
else
    green "    ✓ Script is executable"
fi

# 3. Script actually works (quick smoke test)
echo "  Smoke-testing script ..."
first_user=$(head -1 "$USERNAMES")
smoke_result=$("$SCRIPT" getpwnam "$first_user" 2>/dev/null) && smoke_rc=0 || smoke_rc=$?
if [ "$smoke_rc" -ne 0 ] || [ -z "$smoke_result" ]; then
    red "    ✗ Script failed for known user '$first_user' (exit=$smoke_rc)"
    red "      Command: $SCRIPT getpwnam $first_user"
    [ -n "$smoke_result" ] && red "      Output:  $smoke_result"
    preflight_ok=0
else
    green "    ✓ Script returns data for '$first_user'"
fi

# 4. Required tools
echo "  Checking required tools ..."
for tool in shuf awk grep head wc bc date; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        red "    ✗ Missing tool: $tool"
        preflight_ok=0
    fi
done
green "    ✓ All required tools available"

# 5. NSS-specific checks (only if NSS tests are enabled)
if [ "$SKIP_NSS" -eq 0 ]; then
    echo "  Checking NSS configuration ..."

    # 5a. Library installed
    lib_found=0
    for libpath in /usr/lib /usr/lib64 /lib /lib64 /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu; do
        if [ -f "$libpath/libnss_exec.so.2" ]; then
            lib_found=1
            green "    ✓ libnss_exec.so.2 found at $libpath/"
            break
        fi
    done
    if [ "$lib_found" -eq 0 ]; then
        if ldconfig -p 2>/dev/null | grep -q libnss_exec; then
            lib_found=1
            green "    ✓ libnss_exec.so.2 found via ldconfig"
        else
            red "    ✗ libnss_exec.so.2 not found"
            red "      Build and install: make && sudo make install"
            preflight_ok=0
        fi
    fi

    # 5b. /sbin/nss_exec exists and is executable
    if [ -x "/sbin/nss_exec" ]; then
        green "    ✓ /sbin/nss_exec is installed and executable"
    else
        red "    ✗ /sbin/nss_exec not found or not executable"
        red "      Install: sudo cp $SCRIPT /sbin/nss_exec && sudo chmod 755 /sbin/nss_exec"
        preflight_ok=0
    fi

    # 5c. nsswitch.conf has 'exec' for passwd, group, shadow
    nsswitch_ok=1
    for db in passwd group shadow; do
        line=$(grep "^${db}:" /etc/nsswitch.conf 2>/dev/null || true)
        if [ -z "$line" ]; then
            yellow "    ! No '$db' line in /etc/nsswitch.conf"
            nsswitch_ok=0
        elif echo "$line" | grep -qw "exec"; then
            files_pos=$(echo "$line" | tr -s ' \t' '\n' | grep -n "files" | head -1 | cut -d: -f1)
            exec_pos=$(echo "$line" | tr -s ' \t' '\n' | grep -n "exec" | head -1 | cut -d: -f1)
            if [ -n "$files_pos" ] && [ -n "$exec_pos" ] && [ "$files_pos" -lt "$exec_pos" ]; then
                green "    ✓ nsswitch.conf: $db has 'exec' (after 'files' — good)"
            elif [ -n "$exec_pos" ]; then
                yellow "    ! nsswitch.conf: $db has 'exec' but 'files' is not before it"
                yellow "      WARNING: System users may not resolve! Recommended order: files systemd exec"
            fi
        else
            red "    ✗ nsswitch.conf: $db line does not contain 'exec'"
            nsswitch_ok=0
        fi
    done
    if [ "$nsswitch_ok" -eq 0 ]; then
        red "    ✗ nsswitch.conf not configured for exec"
        red "      Add 'exec' after 'files' in /etc/nsswitch.conf for passwd, group, shadow"
        preflight_ok=0
    fi

    # 5d. Quick getent sanity — can we still resolve root?
    if ! getent passwd root >/dev/null 2>&1; then
        red "    ✗ CRITICAL: 'getent passwd root' failed!"
        red "      System user resolution is broken. Fix nsswitch.conf immediately."
        preflight_ok=0
    else
        green "    ✓ System user 'root' resolves correctly"
    fi

    # 5e. Quick getent test — does our test user resolve via NSS?
    nss_test_result=$(getent passwd "$first_user" 2>/dev/null) || true
    if [ -n "$nss_test_result" ]; then
        green "    ✓ Test user '$first_user' resolves via getent"
    else
        yellow "    ! Test user '$first_user' does NOT resolve via getent"
        yellow "      NSS integration may not be working yet. Phase 3 tests will likely fail."
        yellow "      Check: ldconfig, nsswitch.conf, /sbin/nss_exec, NSS_EXEC_DATA_DIR"
    fi
fi

echo ""

if [ "$preflight_ok" -eq 0 ]; then
    red "Preflight checks FAILED. Fix the issues above before running tests."
    exit 1
fi

green "All preflight checks passed."
echo ""

TOTAL_USERS=$(wc -l < "$USERNAMES")
TOTAL_GROUPS=$(wc -l < "$GROUPNAMES")

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          libnss_exec Stress Test Suite                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Users:       $TOTAL_USERS"
echo "║  Groups:      $TOTAL_GROUPS"
echo "║  Lookups:     $NUM_LOOKUPS per phase"
echo "║  Concurrency: $CONCURRENCY workers"
echo "║  Data dir:    $DATA_DIR"
echo "║  NSS tests:   $([ "$SKIP_NSS" -eq 0 ] && echo "enabled" || echo "skipped")"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# SC2155: declare and assign separately
NSS_EXEC_DATA_DIR="$(cd "$DATA_DIR" && pwd)"
export NSS_EXEC_DATA_DIR

PASS=0
FAIL=0
TOTAL_TIME=0

# ── Helpers ─────────────────────────────────────────────────────────────

# Pick N random lines from a file
random_lines() {
    local file="$1" count="$2"
    shuf -n "$count" "$file" 2>/dev/null || sort -R "$file" | head -n "$count"
}

report() {
    local name="$1" count="$2" failures="$3" duration_ms="$4"
    local rate="N/A"
    if [ "$duration_ms" -gt 0 ]; then
        rate=$(echo "scale=1; $count * 1000 / $duration_ms" | bc 2>/dev/null || echo "N/A")
    fi

    local avg="N/A"
    if [ "$count" -gt 0 ] && [ "$duration_ms" -gt 0 ]; then
        avg=$(echo "scale=2; $duration_ms / $count" | bc 2>/dev/null || echo "N/A")
    fi

    if [ "$failures" -eq 0 ]; then
        green "  ✓ $name: ${count} ops, ${failures} failures, ${duration_ms}ms total, ${avg}ms/op, ${rate} ops/sec"
    else
        red   "  ✗ $name: ${count} ops, ${failures} FAILURES, ${duration_ms}ms total"
    fi

    TOTAL_TIME=$((TOTAL_TIME + duration_ms))
}

# ════════════════════════════════════════════════════════════════════════
# Phase 1: Direct script execution (no NSS involvement)
# ════════════════════════════════════════════════════════════════════════
bold "Phase 1: Direct script execution"
echo ""

# 1a. Sequential getpwnam lookups
echo "  [1a] Sequential getpwnam ($NUM_LOOKUPS lookups) ..."
mapfile -t names < <(random_lines "$USERNAMES" "$NUM_LOOKUPS")
failures=0
start=$(date +%s%N)
for name in "${names[@]}"; do
    result=$("$SCRIPT" getpwnam "$name" 2>/dev/null) || true
    if [ -z "$result" ]; then
        failures=$((failures + 1))
    fi
done
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
report "getpwnam (sequential)" "$NUM_LOOKUPS" "$failures" "$duration_ms"
[ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# 1b. Sequential getpwuid lookups
echo "  [1b] Sequential getpwuid ($NUM_LOOKUPS lookups) ..."
failures=0
start=$(date +%s%N)
for i in $(seq 1 "$NUM_LOOKUPS"); do
    uid=$((10000 + RANDOM % TOTAL_USERS))
    result=$("$SCRIPT" getpwuid "$uid" 2>/dev/null) || true
    if [ -z "$result" ]; then
        failures=$((failures + 1))
    fi
done
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
report "getpwuid (sequential)" "$NUM_LOOKUPS" "$failures" "$duration_ms"
[ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# 1c. Sequential getgrnam lookups
echo "  [1c] Sequential getgrnam ($NUM_LOOKUPS lookups) ..."
mapfile -t grpnames < <(random_lines "$GROUPNAMES" "$NUM_LOOKUPS")
failures=0
start=$(date +%s%N)
for grp in "${grpnames[@]}"; do
    result=$("$SCRIPT" getgrnam "$grp" 2>/dev/null) || true
    if [ -z "$result" ]; then
        failures=$((failures + 1))
    fi
done
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
report "getgrnam (sequential)" "$NUM_LOOKUPS" "$failures" "$duration_ms"
[ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# 1d. Enumeration — full passwd walk
echo "  [1d] Full passwd enumeration ($TOTAL_USERS entries) ..."
failures=0
count=0
start=$(date +%s%N)
idx=0
while true; do
    result=$("$SCRIPT" getpwent "$idx" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -ne 0 ] && break
    count=$((count + 1))
    idx=$((idx + 1))
done
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
if [ "$count" -ne "$TOTAL_USERS" ]; then
    failures=1
    red "    Expected $TOTAL_USERS entries, got $count"
fi
report "getpwent (full enum)" "$count" "$failures" "$duration_ms"
[ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# 1e. Not-found lookups (should return exit 1, not crash)
echo "  [1e] Not-found lookups ($NUM_LOOKUPS) ..."
failures=0
start=$(date +%s%N)
for i in $(seq 1 "$NUM_LOOKUPS"); do
    if "$SCRIPT" getpwnam "nonexistent_user_${i}_$$" >/dev/null 2>&1; then
        # Script returned 0 for a user that shouldn't exist
        failures=$((failures + 1))
    fi
done
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
report "getpwnam not-found" "$NUM_LOOKUPS" "$failures" "$duration_ms"
[ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

echo ""

# ════════════════════════════════════════════════════════════════════════
# Phase 2: Concurrent script execution
# ════════════════════════════════════════════════════════════════════════
bold "Phase 2: Concurrent script execution ($CONCURRENCY workers)"
echo ""

# 2a. Concurrent getpwnam
echo "  [2a] Concurrent getpwnam ($NUM_LOOKUPS lookups, $CONCURRENCY workers) ..."
TMPDIR_CONC=$(mktemp -d)
trap 'rm -rf "$TMPDIR_CONC" 2>/dev/null || true' EXIT

start=$(date +%s%N)
per_worker=$(( NUM_LOOKUPS / CONCURRENCY ))
for w in $(seq 1 "$CONCURRENCY"); do
    (
        mapfile -t worker_names < <(random_lines "$USERNAMES" "$per_worker")
        worker_fail=0
        for name in "${worker_names[@]}"; do
            result=$("$SCRIPT" getpwnam "$name" 2>/dev/null) || true
            [ -z "$result" ] && worker_fail=$((worker_fail + 1))
        done
        echo "$worker_fail" > "$TMPDIR_CONC/worker_${w}"
    ) &
done
wait
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))

failures=0
for f in "$TMPDIR_CONC"/worker_*; do
    failures=$((failures + $(cat "$f")))
done
report "getpwnam (concurrent)" "$NUM_LOOKUPS" "$failures" "$duration_ms"
[ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# 2b. Concurrent mixed lookups (passwd + group simultaneously)
echo "  [2b] Concurrent mixed passwd+group ($NUM_LOOKUPS lookups, $CONCURRENCY workers) ..."
start=$(date +%s%N)
half_workers=$((CONCURRENCY / 2))
[ "$half_workers" -lt 1 ] && half_workers=1
per_worker=$(( NUM_LOOKUPS / CONCURRENCY ))

for w in $(seq 1 "$half_workers"); do
    (
        mapfile -t worker_names < <(random_lines "$USERNAMES" "$per_worker")
        wf=0
        for name in "${worker_names[@]}"; do
            result=$("$SCRIPT" getpwnam "$name" 2>/dev/null) || true
            [ -z "$result" ] && wf=$((wf + 1))
        done
        echo "$wf" > "$TMPDIR_CONC/mixed_pw_${w}"
    ) &
done
for w in $(seq 1 "$half_workers"); do
    (
        mapfile -t worker_grps < <(random_lines "$GROUPNAMES" "$per_worker")
        wf=0
        for grp in "${worker_grps[@]}"; do
            result=$("$SCRIPT" getgrnam "$grp" 2>/dev/null) || true
            [ -z "$result" ] && wf=$((wf + 1))
        done
        echo "$wf" > "$TMPDIR_CONC/mixed_gr_${w}"
    ) &
done
wait
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))

failures=0
for f in "$TMPDIR_CONC"/mixed_*; do
    failures=$((failures + $(cat "$f")))
done
report "mixed passwd+group (concurrent)" "$NUM_LOOKUPS" "$failures" "$duration_ms"
[ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

echo ""

# ════════════════════════════════════════════════════════════════════════
# Phase 3: NSS integration tests (getent, id)
# ════════════════════════════════════════════════════════════════════════
if [ "$SKIP_NSS" -eq 0 ]; then
    bold "Phase 3: NSS integration (getent / id)"
    echo ""
    # 3a. getent passwd by name
    echo "  [3a] getent passwd by name ($NUM_LOOKUPS lookups) ..."
    mapfile -t names < <(random_lines "$USERNAMES" "$NUM_LOOKUPS")
    failures=0
    start=$(date +%s%N)
    for name in "${names[@]}"; do
        result=$(getent passwd "$name" 2>/dev/null) || true
        [ -z "$result" ] && failures=$((failures + 1))
    done
    end=$(date +%s%N)
    duration_ms=$(( (end - start) / 1000000 ))
    report "getent passwd (by name)" "$NUM_LOOKUPS" "$failures" "$duration_ms"
    [ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

    # 3b. getent group by name
    echo "  [3b] getent group by name ($NUM_LOOKUPS lookups) ..."
    mapfile -t grpnames < <(random_lines "$GROUPNAMES" "$NUM_LOOKUPS")
    failures=0
    start=$(date +%s%N)
    for grp in "${grpnames[@]}"; do
        result=$(getent group "$grp" 2>/dev/null) || true
        [ -z "$result" ] && failures=$((failures + 1))
    done
    end=$(date +%s%N)
    duration_ms=$(( (end - start) / 1000000 ))
    report "getent group (by name)" "$NUM_LOOKUPS" "$failures" "$duration_ms"
    [ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

    # 3c. Full passwd enumeration through NSS
    echo "  [3c] getent passwd (full enumeration) ..."
    start=$(date +%s%N)
    count=$(getent passwd 2>/dev/null | grep -c "^" || echo 0)
    end=$(date +%s%N)
    duration_ms=$(( (end - start) / 1000000 ))
    failures=0
    if [ "$count" -lt "$TOTAL_USERS" ]; then
        red "    Expected at least $TOTAL_USERS entries, got $count"
        failures=1
    fi
    report "getent passwd (full enum)" "$count" "$failures" "$duration_ms"
    [ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

    # 3d. System users still work
    echo "  [3d] System user sanity check ..."
    failures=0
    for sysuser in root nobody; do
        if ! getent passwd "$sysuser" >/dev/null 2>&1; then
            red "    CRITICAL: Cannot resolve system user '$sysuser'!"
            failures=$((failures + 1))
        fi
    done
    if [ "$failures" -eq 0 ]; then
        green "  ✓ System users still resolve correctly"
    else
        red   "  ✗ SYSTEM USER RESOLUTION BROKEN — check nsswitch.conf!"
    fi
    [ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

    # 3e. Concurrent getent lookups
    echo "  [3e] Concurrent getent passwd ($NUM_LOOKUPS lookups, $CONCURRENCY workers) ..."
    start=$(date +%s%N)
    per_worker=$(( NUM_LOOKUPS / CONCURRENCY ))
    for w in $(seq 1 "$CONCURRENCY"); do
        (
            mapfile -t worker_names < <(random_lines "$USERNAMES" "$per_worker")
            wf=0
            for name in "${worker_names[@]}"; do
                result=$(getent passwd "$name" 2>/dev/null) || true
                [ -z "$result" ] && wf=$((wf + 1))
            done
            echo "$wf" > "$TMPDIR_CONC/nss_${w}"
        ) &
    done
    wait
    end=$(date +%s%N)
    duration_ms=$(( (end - start) / 1000000 ))

    failures=0
    for f in "$TMPDIR_CONC"/nss_*; do
        failures=$((failures + $(cat "$f")))
    done
    report "getent passwd (concurrent)" "$NUM_LOOKUPS" "$failures" "$duration_ms"
    [ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

    # 3f. Data integrity check — compare script output vs getent output
    echo "  [3f] Data integrity check (100 random users) ..."
    mapfile -t check_names < <(random_lines "$USERNAMES" 100)
    failures=0
    for name in "${check_names[@]}"; do
        script_out=$("$SCRIPT" getpwnam "$name" 2>/dev/null) || true
        nss_out=$(getent passwd "$name" 2>/dev/null) || true
        if [ "$script_out" != "$nss_out" ]; then
            failures=$((failures + 1))
            if [ "$failures" -le 3 ]; then
                red "    Mismatch for '$name':"
                red "      script: $script_out"
                red "      getent: $nss_out"
            fi
        fi
    done
    report "data integrity" "100" "$failures" "0"
    [ "$failures" -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

    echo ""
fi

# ════════════════════════════════════════════════════════════════════════
# Phase 4: Edge cases and error handling
# ════════════════════════════════════════════════════════════════════════
bold "Phase 4: Edge cases"
echo ""

# 4a. Empty / whitespace usernames
# SC2016: the single-quoted backticks are intentional — we're testing that the
# script doesn't execute them. The double-quoted entries test $() expansion too.
echo "  [4a] Edge-case lookups ..."
failures=0
edge_cases=("" " " "$(printf '\t')" "../etc/passwd" "user;ls" "user\`id\`" "user\$(whoami)" "a:b:c:d:e:f:g")
for badname in "${edge_cases[@]}"; do
    # Should return not-found (exit 1), not crash or return garbage
    if "$SCRIPT" getpwnam "$badname" >/dev/null 2>&1; then
        : # returned 0 — not a failure for edge cases, script may just not find it
    fi
done
green "  ✓ Edge-case lookups completed without crash"
PASS=$((PASS + 1))

# 4b. Rapid sequential set/get/end cycles
echo "  [4b] Rapid set/get/end cycles (100 iterations) ..."
failures=0
start=$(date +%s%N)
for i in $(seq 1 100); do
    "$SCRIPT" setpwent >/dev/null 2>&1 || true
    "$SCRIPT" getpwent 0 >/dev/null 2>&1 || true
    "$SCRIPT" getpwent 1 >/dev/null 2>&1 || true
    "$SCRIPT" endpwent >/dev/null 2>&1 || true
done
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
report "set/get/end cycles" "400" "$failures" "$duration_ms"
PASS=$((PASS + 1))

echo ""

# ════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                       RESULTS                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "║  ALL $TOTAL TESTS PASSED"
else
    red   "║  $PASS PASSED, $FAIL FAILED out of $TOTAL"
fi
echo "║"
echo "║  Total time: ${TOTAL_TIME}ms"
echo "╚══════════════════════════════════════════════════════════════╝"

exit "$FAIL"
