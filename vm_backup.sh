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

remote_ssh_cmd() {
    if [ -n "$RSYNC_SSH_KEY" ] && [ -f "$RSYNC_SSH_KEY" ]; then
        ssh -i "$RSYNC_SSH_KEY" "$@"
    else
        ssh "$@"
    fi
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

ensure_base_disks() {
    local vm="$1"
    local normalized=0
    local line type device target source_path

    while read -r type device target source_path; do
        [ "$type" = "file" ] || continue
        [ "$device" = "disk" ] || continue
        [ -n "$target" ] || continue

        if [[ "$source_path" == *".vmbackup-"*".overlay.qcow2" ]]; then
            log "Detected leftover overlay for $vm disk $target at $source_path"
            if ! virsh -c "$LIBVIRT_DEFAULT_URI" blockcommit "$vm" "$target" --active --pivot --verbose >>"$LOGFILE" 2>&1; then
                report_failure "Backup fail $vm: unable to pivot leftover overlay on $target"
                return 1
            fi
            normalized=1
        fi
    done < <(virsh -c "$LIBVIRT_DEFAULT_URI" domblklist --details "$vm" | awk 'NR>2 && NF >= 4 {print $1, $2, $3, $4}')

    if [ "$normalized" -eq 1 ]; then
        log "Normalized active disks for $vm before backup"
    fi

    return 0
}

stream_disk_to_remote() {
    local source_path="$1"
    local remote_file="$2"

    zstd -T0 -q -c "$source_path" | remote_ssh_cmd "$REMOTE_USER@$REMOTE_HOST" "cat > '$remote_file'"
}

store_file() {
    local source_file="$1"
    local dest_file="$2"

    if [ -n "$REMOTE_HOST" ]; then
        remote_ssh_cmd "$REMOTE_USER@$REMOTE_HOST" "mkdir -p '$(dirname "$dest_file")'" >>"$LOGFILE" 2>&1 || return 1
        cat "$source_file" | remote_ssh_cmd "$REMOTE_USER@$REMOTE_HOST" "cat > '$dest_file'"
    else
        mkdir -p "$(dirname "$dest_file")"
        cp "$source_file" "$dest_file"
    fi
}

backup_vm() {
    local vm="$1"
    local vm_dir="$LOCAL_BACKUP_PATH/$vm"
    local timestamp backup_dir remote_backup_dir metadata_dir remote_metadata_dir metadata_xml_dest metadata_manifest_dest manifest xml_file
    local snapshot_name snapshot_attempted backup_failed=0
    local -a diskspec_args snapshot_cmd

    timestamp=$(date +"%Y%m%d-%H%M%S")
    backup_dir="$vm_dir/full-$timestamp"
    remote_backup_dir="$REMOTE_BACKUP_PATH/$vm/full-$timestamp"
    metadata_dir="$backup_dir/metadata"
    remote_metadata_dir="$remote_backup_dir/metadata"
    metadata_xml_dest="$metadata_dir/domain.xml"
    metadata_manifest_dest="$metadata_dir/disks.manifest"
    manifest=$(mktemp)
    xml_file=$(mktemp)
    snapshot_name="vmbackup-$timestamp"

    if ! ensure_base_disks "$vm"; then
        rm -f "$manifest" "$xml_file"
        return 1
    fi

    if [ -n "$REMOTE_HOST" ]; then
        metadata_xml_dest="$remote_metadata_dir/domain.xml"
        metadata_manifest_dest="$remote_metadata_dir/disks.manifest"
        if ! remote_ssh_cmd "$REMOTE_USER@$REMOTE_HOST" "mkdir -p '$remote_metadata_dir' '$remote_backup_dir/disks'" >>"$LOGFILE" 2>&1; then
            report_failure "Remote mkdir fail $vm"
            rm -f "$manifest" "$xml_file"
            return 1
        fi
    else
        mkdir -p "$metadata_dir" "$backup_dir/disks"
    fi

    if ! virsh -c "$LIBVIRT_DEFAULT_URI" dumpxml "$vm" >"$xml_file"; then
        report_failure "Backup fail $vm: unable to dump domain XML"
        rm -f "$manifest" "$xml_file"
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
        backup_name="${target}__$(basename "$source_path").zst"
        printf '%s|%s|%s|%s\n' "$target" "$source_path" "$overlay_path" "$backup_name" >>"$manifest"
        diskspec_args+=(--diskspec "$target,snapshot=external,file=$overlay_path")
    done < <(virsh -c "$LIBVIRT_DEFAULT_URI" domblklist --details "$vm" | awk 'NR>2 && NF >= 4 {print $1, $2, $3, $4}')

    if [ ! -s "$manifest" ]; then
        report_failure "Backup fail $vm: no file-backed disks found"
        rm -f "$manifest" "$xml_file"
        return 1
    fi

    snapshot_cmd=(virsh -c "$LIBVIRT_DEFAULT_URI" snapshot-create-as "$vm" "$snapshot_name" --disk-only --atomic --no-metadata)
    snapshot_cmd+=("${diskspec_args[@]}")

    log "Backup $vm (snapshot stream)"
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
            rm -f "$manifest" "$xml_file"
            return 1
        fi
    fi

    while IFS='|' read -r target source_path overlay_path backup_name; do
        local disk_dest="$backup_dir/disks/$backup_name"
        local remote_disk_dest="$remote_backup_dir/disks/$backup_name"

        [ -n "$target" ] || continue
        log "Streaming $vm disk $target from $source_path"

        if [ -n "$REMOTE_HOST" ]; then
            if ! stream_disk_to_remote "$source_path" "$remote_disk_dest" >>"$LOGFILE" 2>&1; then
                log "Disk stream failed for $vm disk $target"
                backup_failed=1
                break
            fi
        else
            mkdir -p "$backup_dir/disks"
            if ! zstd -T0 -q -f "$source_path" -o "$disk_dest" >>"$LOGFILE" 2>&1; then
                log "Disk compression failed for $vm disk $target"
                backup_failed=1
                break
            fi
        fi
    done <"$manifest"

    if ! cleanup_snapshots "$vm" "$manifest"; then
        backup_failed=1
    fi

    if [ "$backup_failed" -eq 1 ]; then
        report_failure "Backup fail $vm"
        rm -f "$manifest" "$xml_file"
        return 1
    fi

    if ! store_file "$xml_file" "$metadata_xml_dest" >>"$LOGFILE" 2>&1; then
        report_failure "Backup fail $vm: unable to store domain XML"
        rm -f "$manifest" "$xml_file"
        return 1
    fi

    if ! store_file "$manifest" "$metadata_manifest_dest" >>"$LOGFILE" 2>&1; then
        report_failure "Backup fail $vm: unable to store disk manifest"
        rm -f "$manifest" "$xml_file"
        return 1
    fi

    rm -f "$manifest" "$xml_file"
    log "$vm OK"
    return 0
}

exec 200>/var/lock/vm_backup.lock
flock -n 200 || { log "Already running"; exit 1; }
trap 'flock -u 200' EXIT

mkdir -p "$LOCAL_BACKUP_PATH"

log "Starting snapshot-stream backup"

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
