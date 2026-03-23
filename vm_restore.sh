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

remote_ssh_cmd() {
    if [ -n "$RSYNC_SSH_KEY" ] && [ -f "$RSYNC_SSH_KEY" ]; then
        ssh -i "$RSYNC_SSH_KEY" "$@"
    else
        ssh "$@"
    fi
}

fetch_remote_file() {
    local remote_file="$1"
    local local_file="$2"
    remote_ssh_cmd "$REMOTE_USER@$REMOTE_HOST" "cat '$remote_file'" >"$local_file"
}

set_interfaces_link_down() {
    local xml_file="$1"
    local perl_script

    perl_script=$(mktemp)
    cat >"$perl_script" <<'PERL'
s{<interface\b.*?</interface>}{
    my $block = $&;
    $block =~ s{<link\s+state=(["']).*?\1\s*/>}{<link state="down"/>}g;
    if ($block !~ /<link\s+state=/) {
        $block =~ s{(<source\b[^>]*/>)}{$1\n      <link state="down"/>};
    }
    $block;
}gse;
PERL

    perl -0pi "$perl_script" "$xml_file"
    local status=$?
    rm -f "$perl_script"
    return "$status"
}

NO_LINK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --nolink)
            NO_LINK=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--nolink] <VM_NAME> [NEW_VM_NAME]"
            exit 0
            ;;
        --*)
            echo "Unknown option: $1"
            echo "Usage: $0 [--nolink] <VM_NAME> [NEW_VM_NAME]"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

VM_NAME=${1:-""}
NEW_VM_NAME=${2:-$VM_NAME}

if [ -z "$VM_NAME" ]; then
    echo "Usage: $0 [--nolink] <VM_NAME> [NEW_VM_NAME]"
    exit 1
fi

VM_DIR="$LOCAL_BACKUP_PATH/$VM_NAME"
TMP_XML=$(mktemp)
MANIFEST=$(mktemp)
XML_SOURCE=$(mktemp)

if [ -n "$REMOTE_HOST" ]; then
    LATEST_BACKUP=$(remote_ssh_cmd "$REMOTE_USER@$REMOTE_HOST" "find '$REMOTE_BACKUP_PATH/$VM_NAME' -mindepth 1 -maxdepth 1 -type d -name 'full-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-")
else
    if [ ! -d "$VM_DIR" ]; then
        log "ERROR: No backups found for $VM_NAME at $VM_DIR"
        rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
        exit 1
    fi
    LATEST_BACKUP=$(find "$VM_DIR" -mindepth 1 -maxdepth 1 -type d -name 'full-*' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
fi

if [ -z "$LATEST_BACKUP" ]; then
    log "No backup directories found for $VM_NAME"
    rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
    exit 1
fi

if [ -n "$REMOTE_HOST" ]; then
    fetch_remote_file "$LATEST_BACKUP/metadata/disks.manifest" "$MANIFEST" || {
        log "Unable to fetch remote disk manifest"
        rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
        exit 1
    }
    fetch_remote_file "$LATEST_BACKUP/metadata/domain.xml" "$XML_SOURCE" || {
        log "Unable to fetch remote domain XML"
        rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
        exit 1
    }
else
    cp "$LATEST_BACKUP/metadata/disks.manifest" "$MANIFEST" || {
        log "Unable to read disk manifest"
        rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
        exit 1
    }
    cp "$LATEST_BACKUP/metadata/domain.xml" "$XML_SOURCE" || {
        log "Unable to read domain XML"
        rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
        exit 1
    }
fi

log "Restoring from $LATEST_BACKUP to VM $NEW_VM_NAME"

if virsh -c "$LIBVIRT_DEFAULT_URI" dominfo "$NEW_VM_NAME" >/dev/null 2>&1; then
    read -r -p "VM $NEW_VM_NAME exists. Undefine it? (y/N): " REPLY
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if virsh -c "$LIBVIRT_DEFAULT_URI" domstate "$NEW_VM_NAME" 2>/dev/null | grep -qi running; then
            virsh -c "$LIBVIRT_DEFAULT_URI" destroy "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1 || {
                log "Failed to stop existing VM $NEW_VM_NAME"
                rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
                exit 1
            }
        fi

        virsh -c "$LIBVIRT_DEFAULT_URI" undefine "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1 || {
            log "Failed to undefine existing VM $NEW_VM_NAME"
            rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
            exit 1
        }
    else
        log "Aborted restore"
        rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
        exit 1
    fi
fi

cp "$XML_SOURCE" "$TMP_XML"

OLD_VM_NAME=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$XML_SOURCE" | head -1)
OLD_VM_NAME_ESCAPED=$(escape_sed "$OLD_VM_NAME")
NEW_VM_NAME_ESCAPED=$(escape_sed "$NEW_VM_NAME")

sed -i.bak "0,/<name>${OLD_VM_NAME_ESCAPED}<\/name>/s//<name>${NEW_VM_NAME_ESCAPED}<\/name>/" "$TMP_XML"
sed -i.bak '/<uuid>/d' "$TMP_XML"
sed -i.bak "/<mac address=/d" "$TMP_XML"
if [ "$NO_LINK" -eq 1 ]; then
    if ! set_interfaces_link_down "$TMP_XML"; then
        log "Failed to mark restored interfaces link-down"
        rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
        exit 1
    fi
    log "Interfaces will be restored with link state down"
fi
rm -f "$TMP_XML.bak"

while IFS='|' read -r target source_path overlay_path backup_name; do
    local_source="$source_path"
    source_basename=$(basename "$source_path")
    extension="${source_basename##*.}"

    [ -n "$target" ] || continue

    if [ "$NEW_VM_NAME" = "$VM_NAME" ]; then
        dest_path="$local_source"
    else
        dest_path="$RESTORE_IMAGE_DIR/${NEW_VM_NAME}-${target}.${extension}"
    fi

    mkdir -p "$(dirname "$dest_path")"

    if [ -n "$REMOTE_HOST" ]; then
        if ! remote_ssh_cmd "$REMOTE_USER@$REMOTE_HOST" "cat '$LATEST_BACKUP/disks/$backup_name'" | zstd -d -q -o "$dest_path" -f; then
            log "Failed to restore disk $target to $dest_path"
            rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
            exit 1
        fi
    else
        if ! zstd -d -q -f -o "$dest_path" "$LATEST_BACKUP/disks/$backup_name"; then
            log "Failed to restore disk $target to $dest_path"
            rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
            exit 1
        fi
    fi

    src_escaped=$(escape_sed "$source_path")
    dst_escaped=$(escape_sed "$dest_path")
    sed -i.bak "s/${src_escaped}/${dst_escaped}/g" "$TMP_XML"
    rm -f "$TMP_XML.bak"
done <"$MANIFEST"

if ! virsh -c "$LIBVIRT_DEFAULT_URI" define "$TMP_XML" >>"$RESTORE_LOGFILE" 2>&1; then
    log "Restore failed while defining $NEW_VM_NAME"
    rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"
    exit 1
fi

rm -f "$TMP_XML" "$MANIFEST" "$XML_SOURCE"

if virsh -c "$LIBVIRT_DEFAULT_URI" start "$NEW_VM_NAME" >>"$RESTORE_LOGFILE" 2>&1; then
    log "Restore successful for $NEW_VM_NAME from $VM_NAME backups"
else
    log "Restore completed but failed to start $NEW_VM_NAME"
    exit 1
fi
