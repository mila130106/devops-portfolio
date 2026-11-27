#!/usr/bin/env bash
set -euo pipefail

DEFAULT_KEEP=5
KEEP="$DEFAULT_KEEP"
DRY_RUN=false
SOURCE_DIR=""
DEST_DIR=""
LOG_FILE=""

print_help() {
    cat <<'EOF'
Usage: backup.sh --source <path> --dest <path> [--keep <N>] [--dry-run] [--help]

Creates a compressed .tar.gz archive of the source directory and retains only
the N most recent archives belonging to that source.

Options:
  --source <path>   Source directory to archive (required)
  --dest <path>     Destination directory for archives (required)
  --keep <N>        Number of newest archives to keep (default: 5)
  --dry-run         Print planned actions without creating or deleting files
  --help            Show this help message and exit

Exit codes:
  0  Success
  1  Invalid arguments or missing required options
  2  Source directory does not exist or is not readable
  3  Destination directory cannot be created or is not writable
  4  Archive creation or rotation failed

Example:
  ./backup.sh --source "/path/to/my project" --dest "/path/to/backups" --keep 3
EOF
}

timestamp_human() {
    date "+%Y-%m-%d %H:%M:%S"
}

timestamp_file() {
    date "+%Y-%m-%d-%H%M%S"
}

log_entry() {
    local action="$1"
    local result="$2"
    local line
    line="[$(timestamp_human)] action=${action} result=${result}"
    echo "$line"
    if [[ -n "$LOG_FILE" && "$DRY_RUN" == false ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE"
    fi
}

fail_with_code() {
    local code="$1"
    local message="$2"
    local ts
    ts="$(timestamp_human)"
    echo "[$ts] ERROR: $message" >&2
    if [[ -n "$LOG_FILE" && "$DRY_RUN" == false && -d "$(dirname "$LOG_FILE")" ]]; then
        printf '[%s] action=error result="code=%s message=%s"\n' "$ts" "$code" "$message" >> "$LOG_FILE" || true
    fi
    exit "$code"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            print_help
            exit 0
            ;;
        --source)
            [[ $# -lt 2 || -z "$2" ]] && fail_with_code 1 "Missing value for --source"
            SOURCE_DIR="$2"
            shift 2
            ;;
        --dest)
            [[ $# -lt 2 || -z "$2" ]] && fail_with_code 1 "Missing value for --dest"
            DEST_DIR="$2"
            shift 2
            ;;
        --keep)
            [[ $# -lt 2 || -z "$2" ]] && fail_with_code 1 "Missing value for --keep"
            if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]]; then
                fail_with_code 1 "--keep must be a positive integer (got '$2')"
            fi
            KEEP="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            fail_with_code 1 "Unknown option: '$1'. Run with --help for usage."
            ;;
    esac
done

if [[ -z "$SOURCE_DIR" ]]; then
    fail_with_code 1 "Required option --source is missing. Run with --help for usage."
fi

if [[ -z "$DEST_DIR" ]]; then
    fail_with_code 1 "Required option --dest is missing. Run with --help for usage."
fi

if [[ ! -e "$SOURCE_DIR" ]]; then
    fail_with_code 2 "Source directory does not exist: '$SOURCE_DIR'"
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    fail_with_code 2 "Source path is not a directory: '$SOURCE_DIR'"
fi

if [[ ! -r "$SOURCE_DIR" ]]; then
    fail_with_code 2 "Source directory is not readable: '$SOURCE_DIR'"
fi

CLEAN_SOURCE="${SOURCE_DIR%/}"
[[ -z "$CLEAN_SOURCE" ]] && CLEAN_SOURCE="/"

CLEAN_DEST="${DEST_DIR%/}"
[[ -z "$CLEAN_DEST" ]] && CLEAN_DEST="/"

SOURCE_NAME="$(basename "$CLEAN_SOURCE")"
LOG_FILE="${CLEAN_DEST}/backup.log"

if [[ ! -d "$CLEAN_DEST" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        echo "[$(timestamp_human)] [DRY-RUN] Would create destination directory: '$CLEAN_DEST'"
    else
        if ! mkdir -p "$CLEAN_DEST" 2>/dev/null; then
            fail_with_code 3 "Failed to create destination directory: '$CLEAN_DEST'"
        fi
    fi
fi

if [[ "$DRY_RUN" == false && ! -w "$CLEAN_DEST" ]]; then
    fail_with_code 3 "Destination directory is not writable: '$CLEAN_DEST'"
fi

ARCHIVE_NAME="${SOURCE_NAME}-$(timestamp_file).tar.gz"
ARCHIVE_PATH="${CLEAN_DEST}/${ARCHIVE_NAME}"
SOURCE_PARENT="$(dirname "$CLEAN_SOURCE")"

mapfile -d '' -t EXISTING_ARCHIVES < <(
    if [[ -d "$CLEAN_DEST" ]]; then
        find "$CLEAN_DEST" -maxdepth 1 -type f -name "${SOURCE_NAME}-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9].tar.gz" -print0 | LC_ALL=C sort -z
    fi
)

NEW_ARCHIVE_COUNT=1
DELETED_COUNT=0
ARCHIVE_SIZE="0B"

if [[ "$DRY_RUN" == true ]]; then
    echo "[$(timestamp_human)] [DRY-RUN] Would create archive '$ARCHIVE_PATH' from '$CLEAN_SOURCE'"
    TOTAL_AFTER=$(( ${#EXISTING_ARCHIVES[@]} + 1 ))
    if [[ "$TOTAL_AFTER" -gt "$KEEP" ]]; then
        TO_REMOVE_COUNT=$(( TOTAL_AFTER - KEEP ))
        for (( i=0; i<TO_REMOVE_COUNT; i++ )); do
            echo "[$(timestamp_human)] [DRY-RUN] Would delete old archive: '${EXISTING_ARCHIVES[$i]}'"
            DELETED_COUNT=$(( DELETED_COUNT + 1 ))
        done
    else
        echo "[$(timestamp_human)] [DRY-RUN] No old archives to delete (total=${TOTAL_AFTER}, keep=${KEEP})"
    fi
    log_entry "dry-run" "archived_planned=${NEW_ARCHIVE_COUNT}, deleted_planned=${DELETED_COUNT}, archive_size=N/A"
    exit 0
fi

if ! tar -czf "$ARCHIVE_PATH" -C "$SOURCE_PARENT" "$SOURCE_NAME" 2>/dev/null; then
    fail_with_code 4 "Failed to create archive '$ARCHIVE_PATH'"
fi

if [[ -f "$ARCHIVE_PATH" ]]; then
    ARCHIVE_SIZE="$(wc -c < "$ARCHIVE_PATH" | tr -d '[:space:]')B"
fi

mapfile -d '' -t ALL_ARCHIVES < <(
    find "$CLEAN_DEST" -maxdepth 1 -type f -name "${SOURCE_NAME}-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9].tar.gz" -print0 | LC_ALL=C sort -z
)

TOTAL_ARCHIVES="${#ALL_ARCHIVES[@]}"
if [[ "$TOTAL_ARCHIVES" -gt "$KEEP" ]]; then
    REMOVE_COUNT=$(( TOTAL_ARCHIVES - KEEP ))
    for (( i=0; i<REMOVE_COUNT; i++ )); do
        TARGET_FILE="${ALL_ARCHIVES[$i]}"
        if ! rm -f -- "$TARGET_FILE"; then
            fail_with_code 4 "Failed to remove old archive '$TARGET_FILE'"
        fi
        DELETED_COUNT=$(( DELETED_COUNT + 1 ))
    done
fi

log_entry "backup" "archived=${NEW_ARCHIVE_COUNT}, deleted=${DELETED_COUNT}, archive_size=${ARCHIVE_SIZE}, file=${ARCHIVE_NAME}"
exit 0