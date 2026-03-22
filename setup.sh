#!/bin/bash
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.sh"
CRON_FILE="/etc/cron.d/vmbackup"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

prompt() {
    local var_name="$1"
    local label="$2"
    local default_value="$3"
    local secret="${4:-0}"
    local value

    if [ "$secret" = "1" ]; then
        read -r -s -p "$label [$default_value]: " value
        echo
    else
        read -r -p "$label [$default_value]: " value
    fi

    if [ -z "$value" ]; then
        value="$default_value"
    fi

    printf -v "$var_name" '%s' "$value"
}

prompt_bool() {
    local var_name="$1"
    local label="$2"
    local default_value="$3"
    local value

    read -r -p "$label [$default_value]: " value
    value=${value:-$default_value}
    printf -v "$var_name" '%s' "$value"
}

echo "vmbackup setup"
echo "Repo path: $SCRIPT_DIR"

prompt LOCAL_BACKUP_PATH "Local backup path" "/local/vm_backups"
prompt LIBVIRT_TMPDIR "Libvirt temp path" "/var/lib/libvirt/backup"
prompt LIBVIRT_DEFAULT_URI "Libvirt URI" "qemu:///system"
prompt REMOTE_HOST "Remote backup host (blank disables rsync)" ""
prompt REMOTE_USER "Remote backup user" "root"
prompt REMOTE_BACKUP_PATH "Remote backup path" "/vm_backups"
prompt RSYNC_SSH_KEY "SSH key for rsync" "/root/.ssh/id_rsa_backup"
prompt DOMAIN "Alert email domain (blank disables email)" ""
prompt RESEND_API_KEY "Resend API key" "" 1
prompt NTFY_URL "ntfy URL (blank disables ntfy)" ""
prompt INCREMENTAL_RETENTION_DAYS "Incremental retention days" "7"
prompt FULL_RETENTION_DAYS "Full retention days" "28"
prompt LOGFILE "Backup log file" "/var/log/vm_backup.log"
prompt RESTORE_LOGFILE "Restore log file" "/var/log/vm_restore.log"
prompt RETENTION_LOGFILE "Retention log file" "/var/log/vm_retention.log"
prompt_bool INSTALL_CRON "Install cron jobs? (yes/no)" "yes"
prompt BACKUP_SUNDAY_SCHEDULE "Sunday full backup schedule" "0 3 * * 0"
prompt BACKUP_INCREMENTAL_SCHEDULE "Incremental backup schedule" "0 */4 * * *"
prompt RETENTION_SCHEDULE "Retention schedule" "0 4 * * *"

mkdir -p "$LOCAL_BACKUP_PATH" "$LIBVIRT_TMPDIR" /var/lock
chown libvirt-qemu:kvm "$LIBVIRT_TMPDIR"
chmod 770 "$LIBVIRT_TMPDIR"
touch "$LOGFILE" "$RESTORE_LOGFILE" "$RETENTION_LOGFILE"
chmod 640 "$LOGFILE" "$RESTORE_LOGFILE" "$RETENTION_LOGFILE"

cat >"$CONFIG_FILE" <<EOF
#!/bin/bash
LOCAL_BACKUP_PATH="$LOCAL_BACKUP_PATH"
LIBVIRT_TMPDIR="$LIBVIRT_TMPDIR"
LIBVIRT_DEFAULT_URI="$LIBVIRT_DEFAULT_URI"
REMOTE_HOST="$REMOTE_HOST"
REMOTE_USER="$REMOTE_USER"
REMOTE_BACKUP_PATH="$REMOTE_BACKUP_PATH"
RSYNC_SSH_KEY="$RSYNC_SSH_KEY"
DOMAIN="$DOMAIN"
RESEND_API_KEY="$RESEND_API_KEY"
NTFY_URL="$NTFY_URL"
INCREMENTAL_RETENTION_DAYS="$INCREMENTAL_RETENTION_DAYS"
FULL_RETENTION_DAYS="$FULL_RETENTION_DAYS"
LOGFILE="$LOGFILE"
RESTORE_LOGFILE="$RESTORE_LOGFILE"
RETENTION_LOGFILE="$RETENTION_LOGFILE"
EOF
chmod 600 "$CONFIG_FILE"

chmod +x "$SCRIPT_DIR/vm_backup.sh" "$SCRIPT_DIR/vm_restore.sh" "$SCRIPT_DIR/vm_retention.sh" "$SCRIPT_DIR/cleanup.sh" "$SCRIPT_DIR/setup.sh"

if [[ "$INSTALL_CRON" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
    cat >"$CRON_FILE" <<EOF
$BACKUP_SUNDAY_SCHEDULE root $SCRIPT_DIR/vm_backup.sh >> $LOGFILE 2>&1
$BACKUP_INCREMENTAL_SCHEDULE root $SCRIPT_DIR/vm_backup.sh >> $LOGFILE 2>&1
$RETENTION_SCHEDULE root $SCRIPT_DIR/vm_retention.sh >> $RETENTION_LOGFILE 2>&1
EOF
    chmod 644 "$CRON_FILE"
    echo "Wrote cron file: $CRON_FILE"
else
    echo "Skipped cron installation."
fi

echo "Wrote config: $CONFIG_FILE"
echo "Setup complete. Future updates should only require git pull in $SCRIPT_DIR."
