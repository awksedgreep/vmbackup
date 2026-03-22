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

report_failure() {
    local message="$1"
    log "$message"
    ntfy "$message"
    notify "$message"
}

copy_disk() {
    local source_path="$1"
    local dest_path="$2"

    mkdir -p "$(dirname "$dest_path")"
    rsync -a --sparse "$source_path" "$dest_path"
}

cleanup_snapshots() {
    local vm="$1"
    local manifest="$2"
    local cleanup_failed=0

    while IFS='|' read -r target source_path overlay_path backup_name; do
        [ -n "$target" ] || continue

        if ! virsh -c "$LIBVIRT_DEFAULT_URI" blockcommit "$vm" "$target" --active --pivot --verbose >>"$LOGFILE" 2>&1; then
            log "Cleanup failed for $vm disk $target"
            cleanup_failed=1
            continue
        fi

        rm -f -- "$overlay_path"
    done <"$manifest"

    return "$cleanup_failed"
}

backup_vm() {
    local vm="$1"
    local vm_dir="$LOCAL_BACKUP_PATH/$vm"
    local timestamp backup_dir metadata_dir disks_dir manifest xml_file
    local snapshot_name snapshot_attempted copy_failed=0 backup_failed=0
    local -a diskspec_args snapshot_cmd rsync_cmd

    timestamp=$(date +"%Y%m%d-%H%M%S")
    backup_dir="$vm_dir/full-$timestamp"
    metadata_dir="$backup_dir/metadata"
    disks_dir="$backup_dir/disks"
    manifest="$metadata_dir/disks.manifest"
    xml_file="$metadata_dir/domain.xml"
    snapshot_name="vmbackup-$timestamp"

    mkdir -p "$metadata_dir" "$disks_dir"

    if ! virsh -c "$LIBVIRT_DEFAULT_URI" dumpxml "$vm" >"$xml_file"; then
        report_failure "Backup fail $vm: unable to dump domain XML"
        rm -rf -- "$backup_dir"
        return 1
    fi

    : >"$manifest"
    while read -r type device target source_path; do
        local overlay_path backup_name

        [ "$type" = "file" ] || continue
        [ "$device" = "disk" ] || continue
        [ -n "$target" ] || continue
        [ -n "$source_path" ] || continue

        overlay_path="${source_path}.vmbackup-${timestamp}.${target}.overlay.qcow2"
        backup_name="${target}__$(basename "$source_path")"
        printf '%s|%s|%s|%s\n' "$target" "$source_path" "$overlay_path" "$backup_name" >>"$manifest"
        diskspec_args+=(--diskspec "$target,snapshot=external,file=$overlay_path")
    done < <(virsh -c "$LIBVIRT_DEFAULT_URI" domblklist --details "$vm" | awk 'NR>2 && NF >= 4 {print $1, $2, $3, $4}')

    if [ ! -s "$manifest" ]; then
        report_failure "Backup fail $vm: no file-backed disks found"
        rm -rf -- "$backup_dir"
        return 1
    fi

    snapshot_cmd=(virsh -c "$LIBVIRT_DEFAULT_URI" snapshot-create-as "$vm" "$snapshot_name" --disk-only --atomic --no-metadata)
    snapshot_cmd+=("${diskspec_args[@]}")

    log "Backup $vm (snapshot copy)"
    log "Snapshot CMD: ${snapshot_cmd[*]} --quiesce"

    if [ "${QUIESCE_WITH_GUEST_AGENT:-yes}" = "yes" ]; then
        if "${snapshot_cmd[@]}" --quiesce >>"$LOGFILE" 2>&1; then
            snapshot_attempted=1
        else
            log "Quiesced snapshot failed for $vm, retrying without --quiesce"
        fi
    fi

    if [ -z "$snapshot_attempted" ]; then
        if ! "${snapshot_cmd[@]}" >>"$LOGFILE" 2>&1; then
            report_failure "Backup fail $vm: snapshot creation failed"
            rm -rf -- "$backup_dir"
            return 1
        fi
    fi

    while IFS='|' read -r target source_path overlay_path backup_name; do
        [ -n "$target" ] || continue

        log "Copying $vm disk $target from $source_path"
        if ! copy_disk "$source_path" "$disks_dir/$backup_name" >>"$LOGFILE" 2>&1; then
            log "Disk copy failed for $vm disk $target"
            copy_failed=1
            backup_failed=1
            break
        fi
    done <"$manifest"

    if ! cleanup_snapshots "$vm" "$manifest"; then
        backup_failed=1
    fi

    if [ "$copy_failed" -eq 1 ]; then
        report_failure "Backup fail $vm: disk copy failed"
        return 1
    fi

    if [ "$backup_failed" -eq 1 ]; then
        report_failure "Backup fail $vm: snapshot cleanup failed"
        return 1
    fi

    if [ -n "$REMOTE_HOST" ]; then
        rsync_cmd=(rsync -avz)
        if [ -n "$RSYNC_SSH_KEY" ] && [ -f "$RSYNC_SSH_KEY" ]; then
            rsync_cmd+=(-e "ssh -i $RSYNC_SSH_KEY")
        fi

        if ! "${rsync_cmd[@]}" "$backup_dir/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_PATH/$vm/$(basename "$backup_dir")/"; then
            report_failure "Rsync fail $vm"
            return 1
        fi
    fi

    log "$vm OK"
    return 0
}

exec 200>/var/lock/vm_backup.lock
flock -n 200 || { log "Already running"; exit 1; }
trap 'flock -u 200' EXIT

mkdir -p "$LOCAL_BACKUP_PATH"

log "Starting snapshot-copy backup"

VMLIST=$(virsh -c "$LIBVIRT_DEFAULT_URI" list --state-running | awk 'NR>2 && $1 ~ /^[0-9]+$/ {print $2}')
[ -z "$VMLIST" ] && { log "No running VMs"; exit 0; }

vm_count=$(echo "$VMLIST" | wc -w | tr -d ' ')
success=0

log "Running VMs: $VMLIST"

for VM in $VMLIST; do
    if backup_vm "$VM"; then
        ((success++))
    fi
done

log "Done: success $success / $vm_count"
notify "Backup complete: $success VMs"
