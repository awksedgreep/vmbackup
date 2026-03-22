#!/bin/bash
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1091
    . "$CONFIG_FILE"
fi

echo "Cleaning up vmbackup setup from $SCRIPT_DIR"

if [ "${FORCE:-0}" != "1" ]; then
    read -r -p "Remove cron, logs, and local backups? (y/N): " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

rm -f /etc/cron.d/vmbackup /etc/cron.d/vm-backup /etc/cron.d/vm_backup
rm -f /var/lock/vm_backup.lock

if [ -n "$LOCAL_BACKUP_PATH" ]; then
    rm -rf -- "$LOCAL_BACKUP_PATH"
fi

rm -f -- "${LOGFILE:-/var/log/vm_backup.log}" "${RESTORE_LOGFILE:-/var/log/vm_restore.log}" "${RETENTION_LOGFILE:-/var/log/vm_retention.log}"
rm -rf -- "${LEGACY_TEMP_DIR:-/var/lib/libvirt/backup}" "${LEGACY_QEMU_TEMP_DIR:-/var/lib/libvirt/qemu/backup}"

echo "Cleanup complete. Repo checkout at $SCRIPT_DIR was left in place."
