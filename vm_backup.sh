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
    echo "Run as root"
    exit 1
fi

log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOGFILE"
}

ntfy() {
    [ -n "$NTFY_URL" ] || return 0
    curl -fsS -H "Title: VM Backup Alert" -d "$1" "$NTFY_URL" >/dev/null || true
}

notify() {
    [ -n "$RESEND_API_KEY" ] || return 0
    [ -n "$DOMAIN" ] || return 0
    curl -fsS -H "Authorization: Bearer $RESEND_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"to\":\"admin@$DOMAIN\",\"subject\":\"VM Backup\",\"text\":\"$1\"}" \
        https://api.resend.com/emails >/dev/null || true
}

exec 200>/var/lock/vm_backup.lock
flock -n 200 || { log "Already running"; exit 1; }
trap 'flock -u 200' EXIT

mkdir -p "$LIBVIRT_TMPDIR" "$LOCAL_BACKUP_PATH"
chown libvirt-qemu:kvm "$LIBVIRT_TMPDIR"
chmod 770 "$LIBVIRT_TMPDIR"

log "Starting (full/inc auto)"

VMLIST=$(virsh list --state-running | awk 'NR>2 && $1 ~ /^[0-9]+$/ {print $2}')
[ -z "$VMLIST" ] && { log "No running VMs"; exit 0; }

IS_SUNDAY=$(date +%u)
vm_count=$(echo "$VMLIST" | wc -w | tr -d ' ')
success=0

log "Running VMs: $VMLIST"

for VM in $VMLIST; do
    VM_DIR="$LOCAL_BACKUP_PATH/$VM"
    SOCKETFILE="$LIBVIRT_TMPDIR/virtnbdbackup.${VM}.$$"
    mkdir -p "$VM_DIR"

    if [ "$IS_SUNDAY" = 7 ] || [ ! -d "$VM_DIR/checkpoints" ]; then
        BACKUP_LVL="full"
    else
        BACKUP_LVL="inc"
    fi

    CMD=(virtnbdbackup -d "$VM" -l "$BACKUP_LVL" -o "$VM_DIR/" -S "$LIBVIRT_TMPDIR" -f "$SOCKETFILE" -z -v)
    log "Backup $VM (-l $BACKUP_LVL)"
    log "CMD: ${CMD[*]}"

    if "${CMD[@]}" >>"$LOGFILE" 2>&1; then
        log "$VM OK"
        if [ -n "$REMOTE_HOST" ]; then
            RSYNC_CMD=(rsync -avz)
            if [ -n "$RSYNC_SSH_KEY" ] && [ -f "$RSYNC_SSH_KEY" ]; then
                RSYNC_CMD+=(-e "ssh -i $RSYNC_SSH_KEY")
            fi

            if "${RSYNC_CMD[@]}" "$VM_DIR/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_PATH/$VM/"; then
                ((success++))
            else
                log "$VM rsync fail"
                ntfy "Rsync fail $VM"
                notify "Rsync fail $VM"
            fi
        else
            ((success++))
        fi
    else
        log "$VM fail"
        ntfy "Backup fail $VM"
        notify "Backup fail $VM"
    fi
done

log "Done: success $success / $vm_count"
notify "Backup complete: $success VMs"
