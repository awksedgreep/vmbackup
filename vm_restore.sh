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

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
export TMPDIR="$LIBVIRT_TMPDIR"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$RESTORE_LOGFILE"
}

VM_NAME=${1:-""}
NEW_VM_NAME=${2:-$VM_NAME}

if [ -z "$VM_NAME" ]; then
    echo "Usage: $0 <VM_NAME> [NEW_VM_NAME]"
    exit 1
fi

mkdir -p "$LIBVIRT_TMPDIR"
chown libvirt-qemu:kvm "$LIBVIRT_TMPDIR"
chmod 770 "$LIBVIRT_TMPDIR"

VM_DIR="$LOCAL_BACKUP_PATH/$VM_NAME"
if [ ! -d "$VM_DIR" ]; then
    log "ERROR: No backups found for $VM_NAME at $VM_DIR"
    exit 1
fi

LATEST_BACKUP=$(find "$VM_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
if [ -z "$LATEST_BACKUP" ]; then
    log "No backup directories found in $VM_DIR"
    exit 1
fi

log "Restoring from $LATEST_BACKUP to VM $NEW_VM_NAME"

if virsh -c "$LIBVIRT_DEFAULT_URI" dominfo "$NEW_VM_NAME" >/dev/null 2>&1; then
    read -r -p "VM $NEW_VM_NAME exists. Undefine it? (y/N): " REPLY
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if virsh -c "$LIBVIRT_DEFAULT_URI" domstate "$NEW_VM_NAME" 2>/dev/null | grep -qi running; then
            virsh -c "$LIBVIRT_DEFAULT_URI" destroy "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1 || {
                log "Failed to stop existing VM $NEW_VM_NAME"
                exit 1
            }
        fi

        virsh -c "$LIBVIRT_DEFAULT_URI" undefine "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1 || {
            log "Failed to undefine existing VM $NEW_VM_NAME"
            exit 1
        }
    else
        log "Aborted restore"
        exit 1
    fi
fi

if virtnbdbackup --restore --vm "$NEW_VM_NAME" --backup-dir "$LATEST_BACKUP" >>"$RESTORE_LOGFILE" 2>&1; then
    log "Restore successful for $NEW_VM_NAME from $VM_NAME backups"
    if virsh -c "$LIBVIRT_DEFAULT_URI" start "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1; then
        log "Started VM $NEW_VM_NAME"
    else
        log "Restore completed but failed to start $NEW_VM_NAME"
        exit 1
    fi
else
    log "Restore failed for $NEW_VM_NAME"
    exit 1
fi
