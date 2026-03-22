#!/bin/bash
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Missing config: $CONFIG_FILE"
    echo "Run $SCRIPT_DIR/setup.sh first."
    exit 1
fi

# shellcheck disable=SC1091
. "$CONFIG_FILE"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$RETENTION_LOGFILE"
}

delete_matching_backups() {
    local pattern="$1"
    local days="$2"
    local backup_dir

    DELETE_COUNT=0

    while IFS= read -r backup_dir; do
        [ -n "$backup_dir" ] || continue
        rm -rf -- "$backup_dir"
        log "Deleted $backup_dir"
        DELETE_COUNT=$((DELETE_COUNT + 1))
    done < <(find "$LOCAL_BACKUP_PATH" -mindepth 2 -maxdepth 2 -type d -name "$pattern" -mtime +"$days" -print)
}

delete_matching_backups "full-*" "${FULL_RETENTION_DAYS:-14}"
full_deleted="$DELETE_COUNT"

log "Retention cleanup complete (full=$full_deleted)"
