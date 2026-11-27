#!/usr/bin/env bash
set -euo pipefail

DEFAULT_KEEP=5
KEEP="$DEFAULT_KEEP"
DRY_RUN=false
SOURCE_DIR=""
DEST_DIR=""
LOG_FILE=""

print_help() {
    cat <<'HELP_EOF'
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
HELP_EOF
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

list_sorted_archives() {
    local dir="$1"
    local prefix="$2"
    local -a raw_files=()
    local item a b tmp n i j

    [[ -d "$dir" ]] || return 0

    shopt -s nullglob
    for item in "${dir}/${prefix}"-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz; do
        [[ -f "$item" ]] && raw_files+=("$item")
    done
    shopt -u nullglob

    n="${#raw_files[@]}"
    [[ "$n" -eq 0 ]] && return 0

    if [[ "$n" -gt 1 ]]; then
        for (( i=0; i<n; i++ )); do
            for (( j=i+1; j<n; j++ )); do
                a="${raw_files[$i]}"
                b="${raw_files[$j]}"
                if [[ "$a" > "$b" ]]; then
                    tmp="${raw_files[$i]}"
                    raw_files[$i]="${raw_files[$j]}"
                    raw_files[$j]="$tmp"
                fi
            done
        done
    fi

    printf '%s\n' "${raw_files[@]}"
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

[[ -z "$SOURCE_DIR" ]] && fail_with_code 1 "Required option --source is missing. Run with --help for usage."
[[ -z "$DEST_DIR" ]] && fail_with_code 1 "Required option --dest is missing. Run with --help for usage."

[[ ! -e "$SOURCE_DIR" ]] && fail_with_code 2 "Source directory does not exist: '$SOURCE_DIR'"
[[ ! -d "$SOURCE_DIR" ]] && fail_with_code 2 "Source path is not a directory: '$SOURCE_DIR'"
[[ ! -r "$SOURCE_DIR" ]] && fail_with_code 2 "Source directory is not readable: '$SOURCE_DIR'"

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
        mkdir -p "$CLEAN_DEST" 2>/dev/null || fail_with_code 3 "Failed to create destination directory: '$CLEAN_DEST'"
    fi
fi

if [[ "$DRY_RUN" == false && ! -w "$CLEAN_DEST" ]]; then
    fail_with_code 3 "Destination directory is not writable: '$CLEAN_DEST'"
fi

ARCHIVE_NAME="${SOURCE_NAME}-$(timestamp_file).tar.gz"
ARCHIVE_PATH="${CLEAN_DEST}/${ARCHIVE_NAME}"
SOURCE_PARENT="$(dirname "$CLEAN_SOURCE")"

EXISTING_ARCHIVES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && EXISTING_ARCHIVES+=("$line")
done < <(list_sorted_archives "$CLEAN_DEST" "$SOURCE_NAME")

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

tar -czf "$ARCHIVE_PATH" -C "$SOURCE_PARENT" "$SOURCE_NAME" 2>/dev/null || fail_with_code 4 "Failed to create archive '$ARCHIVE_PATH'"

if [[ -f "$ARCHIVE_PATH" ]]; then
    ARCHIVE_SIZE="$(wc -c < "$ARCHIVE_PATH" | tr -d '[:space:]')B"
fi

ALL_ARCHIVES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && ALL_ARCHIVES+=("$line")
done < <(list_sorted_archives "$CLEAN_DEST" "$SOURCE_NAME")

TOTAL_ARCHIVES="${#ALL_ARCHIVES[@]}"
if [[ "$TOTAL_ARCHIVES" -gt "$KEEP" ]]; then
    REMOVE_COUNT=$(( TOTAL_ARCHIVES - KEEP ))
    for (( i=0; i<REMOVE_COUNT; i++ )); do
        TARGET_FILE="${ALL_ARCHIVES[$i]}"
        rm -f -- "$TARGET_FILE" || fail_with_code 4 "Failed to remove old archive '$TARGET_FILE'"
        DELETED_COUNT=$(( DELETED_COUNT + 1 ))
    done
fi

log_entry "backup" "archived=${NEW_ARCHIVE_COUNT}, deleted=${DELETED_COUNT}, archive_size=${ARCHIVE_SIZE}, file=${ARCHIVE_NAME}"
exit 0
