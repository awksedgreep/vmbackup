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
    echo "Please run as root"
    exit 1
fi

log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$RESTORE_LOGFILE"
}

escape_sed() {
    printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

VM_NAME=${1:-""}
NEW_VM_NAME=${2:-$VM_NAME}

if [ -z "$VM_NAME" ]; then
    echo "Usage: $0 <VM_NAME> [NEW_VM_NAME]"
    exit 1
fi

VM_DIR="$LOCAL_BACKUP_PATH/$VM_NAME"
if [ ! -d "$VM_DIR" ]; then
    log "ERROR: No backups found for $VM_NAME at $VM_DIR"
    exit 1
fi

LATEST_BACKUP=$(find "$VM_DIR" -mindepth 1 -maxdepth 1 -type d -name 'full-*' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
if [ -z "$LATEST_BACKUP" ]; then
    log "No backup directories found in $VM_DIR"
    exit 1
fi

MANIFEST="$LATEST_BACKUP/metadata/disks.manifest"
XML_SOURCE="$LATEST_BACKUP/metadata/domain.xml"
TMP_XML=$(mktemp)

if [ ! -f "$MANIFEST" ] || [ ! -f "$XML_SOURCE" ]; then
    log "Backup metadata missing in $LATEST_BACKUP"
    exit 1
fi

log "Restoring from $LATEST_BACKUP to VM $NEW_VM_NAME"

if virsh -c "$LIBVIRT_DEFAULT_URI" dominfo "$NEW_VM_NAME" >/dev/null 2>&1; then
    read -r -p "VM $NEW_VM_NAME exists. Undefine it? (y/N): " REPLY
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if virsh -c "$LIBVIRT_DEFAULT_URI" domstate "$NEW_VM_NAME" 2>/dev/null | grep -qi running; then
            virsh -c "$LIBVIRT_DEFAULT_URI" destroy "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1 || {
                log "Failed to stop existing VM $NEW_VM_NAME"
                rm -f "$TMP_XML"
                exit 1
            }
        fi

        virsh -c "$LIBVIRT_DEFAULT_URI" undefine "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1 || {
            log "Failed to undefine existing VM $NEW_VM_NAME"
            rm -f "$TMP_XML"
            exit 1
        }
    else
        log "Aborted restore"
        rm -f "$TMP_XML"
        exit 1
    fi
fi

cp "$XML_SOURCE" "$TMP_XML"

OLD_VM_NAME=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$XML_SOURCE" | head -1)
OLD_VM_NAME_ESCAPED=$(escape_sed "$OLD_VM_NAME")
NEW_VM_NAME_ESCAPED=$(escape_sed "$NEW_VM_NAME")

sed -i.bak "0,/<name>${OLD_VM_NAME_ESCAPED//\//\\/}<\/name>/s//<name>${NEW_VM_NAME_ESCAPED//\//\\/}<\/name>/" "$TMP_XML"
sed -i.bak '/<uuid>/d' "$TMP_XML"
sed -i.bak "/<mac address=/d" "$TMP_XML"
rm -f "$TMP_XML.bak"

while IFS='|' read -r target source_path overlay_path backup_name; do
    [ -n "$target" ] || continue

    source_basename=$(basename "$source_path")
    extension="${source_basename##*.}"
    if [ "$NEW_VM_NAME" = "$VM_NAME" ]; then
        dest_path="$source_path"
    else
        dest_path="$RESTORE_IMAGE_DIR/${NEW_VM_NAME}-${target}.${extension}"
    fi

    mkdir -p "$(dirname "$dest_path")"
    rsync -a --sparse "$LATEST_BACKUP/disks/$backup_name" "$dest_path" >>"$RESTORE_LOGFILE" 2>&1 || {
        log "Failed to restore disk $target to $dest_path"
        rm -f "$TMP_XML"
        exit 1
    }

    src_escaped=$(escape_sed "$source_path")
    dst_escaped=$(escape_sed "$dest_path")
    sed -i.bak "s/${src_escaped}/${dst_escaped}/g" "$TMP_XML"
    rm -f "$TMP_XML.bak"
done <"$MANIFEST"

if ! virsh -c "$LIBVIRT_DEFAULT_URI" define "$TMP_XML" >>"$RESTORE_LOGFILE" 2>&1; then
    log "Restore failed while defining $NEW_VM_NAME"
    rm -f "$TMP_XML"
    exit 1
fi

rm -f "$TMP_XML"

if virsh -c "$LIBVIRT_DEFAULT_URI" start "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1; then
    log "Restore successful for $NEW_VM_NAME from $VM_NAME backups"
else
    log "Restore completed but failed to start $NEW_VM_NAME"
    exit 1
fi
