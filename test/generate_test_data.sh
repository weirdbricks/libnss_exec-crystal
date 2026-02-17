#!/usr/bin/env bash
# generate_test_data.sh — Generate random passwd/group/shadow data and
# a /sbin/nss_exec script that serves it.
#
# Usage:
#   ./generate_test_data.sh [OPTIONS]
#
# Options:
#   -u NUM_USERS    Number of users to generate       (default: 1000)
#   -g NUM_GROUPS   Number of groups to generate       (default: 100)
#   -m MAX_MEMBERS  Max members per group              (default: 20)
#   -o OUTPUT_DIR   Where to write generated files     (default: ./test_data)
#   -s SCRIPT_PATH  Where to install nss_exec script   (default: /sbin/nss_exec)
#   -i              Install the script (requires root)
#   -h              Show this help
#
# The generated nss_exec script uses flat files + grep/awk for lookups,
# which is realistic for testing (I/O bound, like a real backend).
set -euo pipefail

# ── Defaults (override with flags or env vars) ──────────────────────────
NUM_USERS="${NUM_USERS:-1000}"
NUM_GROUPS="${NUM_GROUPS:-100}"
MAX_MEMBERS="${MAX_MEMBERS:-20}"
OUTPUT_DIR="${OUTPUT_DIR:-./test_data}"
SCRIPT_PATH="${SCRIPT_PATH:-/sbin/nss_exec}"
DO_INSTALL=0

# ── Parse flags ─────────────────────────────────────────────────────────
while getopts "u:g:m:o:s:ih" opt; do
    case "$opt" in
        u) NUM_USERS="$OPTARG" ;;
        g) NUM_GROUPS="$OPTARG" ;;
        m) MAX_MEMBERS="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        s) SCRIPT_PATH="$OPTARG" ;;
        i) DO_INSTALL=1 ;;
        h)
            sed -n '2,/^set/{ /^#/s/^# \?//p }' "$0"
            exit 0
            ;;
        *) exit 1 ;;
    esac
done

echo "==> Generating test data:"
echo "    Users:       $NUM_USERS"
echo "    Groups:      $NUM_GROUPS"
echo "    Max members: $MAX_MEMBERS"
echo "    Output dir:  $OUTPUT_DIR"
echo ""

mkdir -p "$OUTPUT_DIR"

# ── UID/GID range ───────────────────────────────────────────────────────
# Start at 10000 to avoid conflicts with real system users.
BASE_UID=10000
BASE_GID=20000

# ── Random word list for realistic usernames ────────────────────────────
FIRST_PARTS=(alpha bravo charlie delta echo foxtrot golf hotel india juliet
             kilo lima mike november oscar papa quebec romeo sierra tango
             uniform victor whiskey xray yankee zulu amber blaze cedar dusk
             ember flame grove hawk iris jade knight lunar moss nova onyx
             pearl quartz ridge spark terra ultra vivid wren xylo yew zen)

LAST_PARTS=(smith jones brown wilson taylor clark hall lee walker green
            baker harris martin king wright thompson evans white roberts
            johnson lewis robinson scott allen young hill moore jackson
            thomas gray cole ward foster mason brooks hunt ross fisher
            reed hart wood rice cruz shaw butler kim fox price)

random_word() {
    local arr=("${FIRST_PARTS[@]}")
    echo "${arr[$((RANDOM % ${#arr[@]}))]}"
}

random_last() {
    local arr=("${LAST_PARTS[@]}")
    echo "${arr[$((RANDOM % ${#arr[@]}))]}"
}

# ── Generate passwd file ────────────────────────────────────────────────
echo "==> Generating $NUM_USERS users ..."
PASSWD_FILE="$OUTPUT_DIR/passwd.db"
SHADOW_FILE="$OUTPUT_DIR/shadow.db"
USERNAMES_FILE="$OUTPUT_DIR/usernames.txt"

: > "$PASSWD_FILE"
: > "$SHADOW_FILE"
: > "$USERNAMES_FILE"

declare -A SEEN_NAMES  # Deduplicate usernames

generated=0
attempts=0
while [ "$generated" -lt "$NUM_USERS" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt $((NUM_USERS * 5)) ]; then
        echo "WARNING: Could only generate $generated unique users (wanted $NUM_USERS)"
        break
    fi

    first=$(random_word)
    last=$(random_last)
    # Add a numeric suffix for uniqueness at scale
    suffix=$((RANDOM % 100))
    username="${first}_${last}${suffix}"

    # Skip duplicates
    [ -n "${SEEN_NAMES[$username]:-}" ] && continue
    SEEN_NAMES["$username"]=1

    uid=$((BASE_UID + generated))
    gid=$((BASE_UID + generated))  # Primary group = same as UID
    gecos="${first^} ${last^}"     # Capitalize
    home="/home/$username"
    shell="/bin/bash"

    echo "${username}:x:${uid}:${gid}:${gecos}:${home}:${shell}" >> "$PASSWD_FILE"
    echo "${username}:!:18000:0:99999:7:::" >> "$SHADOW_FILE"
    echo "$username" >> "$USERNAMES_FILE"

    generated=$((generated + 1))
done

ACTUAL_USERS=$generated
echo "    Generated $ACTUAL_USERS users."

# ── Generate group file ─────────────────────────────────────────────────
echo "==> Generating $NUM_GROUPS groups ..."
GROUP_FILE="$OUTPUT_DIR/group.db"
GROUPNAMES_FILE="$OUTPUT_DIR/groupnames.txt"

: > "$GROUP_FILE"
: > "$GROUPNAMES_FILE"

# Read usernames into array for member assignment
mapfile -t ALL_USERS < "$USERNAMES_FILE"

for i in $(seq 0 $((NUM_GROUPS - 1))); do
    grpname="grp_$(random_word)_${i}"
    gid=$((BASE_GID + i))

    # Random number of members (1 to MAX_MEMBERS)
    num_members=$(( (RANDOM % MAX_MEMBERS) + 1 ))
    if [ "$num_members" -gt "$ACTUAL_USERS" ]; then
        num_members=$ACTUAL_USERS
    fi

    # Pick random unique members
    members=""
    declare -A picked=()
    added=0
    while [ "$added" -lt "$num_members" ]; do
        idx=$((RANDOM % ACTUAL_USERS))
        member="${ALL_USERS[$idx]}"
        if [ -z "${picked[$member]:-}" ]; then
            picked["$member"]=1
            [ -n "$members" ] && members="${members},"
            members="${members}${member}"
            added=$((added + 1))
        fi
    done
    unset picked

    echo "${grpname}:x:${gid}:${members}" >> "$GROUP_FILE"
    echo "$grpname" >> "$GROUPNAMES_FILE"
done

echo "    Generated $NUM_GROUPS groups."

# ── Generate the nss_exec script ────────────────────────────────────────
echo "==> Generating nss_exec script ..."
SCRIPT_FILE="$OUTPUT_DIR/nss_exec"

cat > "$SCRIPT_FILE" << 'SCRIPT_HEADER'
#!/bin/bash
# Auto-generated nss_exec script for stress testing.
# Uses flat-file lookup with grep/awk — realistic I/O patterns.
set -u

COMMAND="${1:-}"
ARGUMENT="${2:-}"

# Data directory — same directory as this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASSWD_DB="${NSS_EXEC_DATA_DIR:-PLACEHOLDER_DIR}/passwd.db"
GROUP_DB="${NSS_EXEC_DATA_DIR:-PLACEHOLDER_DIR}/group.db"
SHADOW_DB="${NSS_EXEC_DATA_DIR:-PLACEHOLDER_DIR}/shadow.db"

case "$COMMAND" in
    # ── Password database ───────────────────────────────────────────
    setpwent|endpwent)
        exit 0
        ;;
    getpwent)
        # $ARGUMENT is the 0-based index
        line=$(awk "NR == $(($ARGUMENT + 1))" "$PASSWD_DB" 2>/dev/null)
        if [ -n "$line" ]; then
            echo "$line"
            exit 0
        fi
        exit 1
        ;;
    getpwnam)
        line=$(grep "^${ARGUMENT}:" "$PASSWD_DB" 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            echo "$line"
            exit 0
        fi
        exit 1
        ;;
    getpwuid)
        line=$(awk -F: -v uid="$ARGUMENT" '$3 == uid' "$PASSWD_DB" 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            echo "$line"
            exit 0
        fi
        exit 1
        ;;

    # ── Group database ──────────────────────────────────────────────
    setgrent|endgrent)
        exit 0
        ;;
    getgrent)
        line=$(awk "NR == $(($ARGUMENT + 1))" "$GROUP_DB" 2>/dev/null)
        if [ -n "$line" ]; then
            echo "$line"
            exit 0
        fi
        exit 1
        ;;
    getgrnam)
        line=$(grep "^${ARGUMENT}:" "$GROUP_DB" 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            echo "$line"
            exit 0
        fi
        exit 1
        ;;
    getgrgid)
        line=$(awk -F: -v gid="$ARGUMENT" '$3 == gid' "$GROUP_DB" 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            echo "$line"
            exit 0
        fi
        exit 1
        ;;

    # ── Shadow database ─────────────────────────────────────────────
    setspent|endspent)
        exit 0
        ;;
    getspent)
        line=$(awk "NR == $(($ARGUMENT + 1))" "$SHADOW_DB" 2>/dev/null)
        if [ -n "$line" ]; then
            echo "$line"
            exit 0
        fi
        exit 1
        ;;
    getspnam)
        line=$(grep "^${ARGUMENT}:" "$SHADOW_DB" 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            echo "$line"
            exit 0
        fi
        exit 1
        ;;

    *)
        exit 3
        ;;
esac
SCRIPT_HEADER

# Patch in the actual data directory path
REAL_DIR="$(cd "$OUTPUT_DIR" && pwd)"
sed -i "s|PLACEHOLDER_DIR|${REAL_DIR}|g" "$SCRIPT_FILE"
chmod +x "$SCRIPT_FILE"

echo "    Script written to $SCRIPT_FILE"

# ── Optionally install ──────────────────────────────────────────────────
if [ "$DO_INSTALL" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo ""
        echo "ERROR: -i (install) requires root. Run with sudo."
        exit 1
    fi
    echo "==> Installing script to $SCRIPT_PATH ..."
    cp "$SCRIPT_FILE" "$SCRIPT_PATH"
    chmod 755 "$SCRIPT_PATH"
    echo "    Installed."
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "==> Generated files:"
echo "    $PASSWD_FILE   ($ACTUAL_USERS entries)"
echo "    $SHADOW_FILE   ($ACTUAL_USERS entries)"
echo "    $GROUP_FILE    ($NUM_GROUPS entries)"
echo "    $USERNAMES_FILE"
echo "    $GROUPNAMES_FILE"
echo "    $SCRIPT_FILE"
echo ""
echo "==> Quick test:"
echo "    $SCRIPT_FILE getpwnam $(head -1 "$USERNAMES_FILE")"
echo ""
echo "==> To install for real NSS testing:"
echo "    sudo cp $SCRIPT_FILE $SCRIPT_PATH"
echo "    # or re-run with: sudo $0 -o $OUTPUT_DIR -i"
