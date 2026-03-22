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

normalize_ntfy_url() {
    case "$1" in
        http://*|https://*) printf '%s' "$1" ;;
        "") printf '' ;;
        *) printf 'https://ntfy.sh/%s' "$1" ;;
    esac
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
prompt RESTORE_IMAGE_DIR "Restore image directory" "/var/lib/libvirt/images"
prompt LIBVIRT_DEFAULT_URI "Libvirt URI" "qemu:///system"
prompt REMOTE_HOST "Remote backup host (blank stores local .zst backups)" ""
prompt REMOTE_USER "Remote backup user" "root"
prompt REMOTE_BACKUP_PATH "Remote backup path" "/vm_backups"
prompt RSYNC_SSH_KEY "SSH key for rsync" "/root/.ssh/id_rsa_backup"
prompt ALERT_EMAIL_FROM "Alert email from (blank disables email)" ""
prompt ALERT_EMAIL_TO "Alert email to (blank disables email)" ""
prompt RESEND_API_KEY "Resend API key" "" 1
prompt NTFY_URL_INPUT "ntfy URL or topic (blank disables ntfy)" ""
NTFY_URL=$(normalize_ntfy_url "$NTFY_URL_INPUT")
prompt_bool QUIESCE_WITH_GUEST_AGENT "Quiesce with guest agent when possible? (yes/no)" "yes"
prompt FULL_RETENTION_DAYS "Full backup retention days" "14"
prompt LOGFILE "Backup log file" "/var/log/vm_backup.log"
prompt RESTORE_LOGFILE "Restore log file" "/var/log/vm_restore.log"
prompt RETENTION_LOGFILE "Retention log file" "/var/log/vm_retention.log"
prompt_bool INSTALL_CRON "Install cron jobs? (yes/no)" "yes"
prompt BACKUP_SCHEDULE "Backup schedule" "0 3 * * *"
prompt RETENTION_SCHEDULE "Retention schedule" "15 3 * * *"

mkdir -p "$LOCAL_BACKUP_PATH" "$RESTORE_IMAGE_DIR" /var/lock
touch "$LOGFILE" "$RESTORE_LOGFILE" "$RETENTION_LOGFILE"
chmod 640 "$LOGFILE" "$RESTORE_LOGFILE" "$RETENTION_LOGFILE"

cat >"$CONFIG_FILE" <<EOF
#!/bin/bash
LOCAL_BACKUP_PATH="$LOCAL_BACKUP_PATH"
RESTORE_IMAGE_DIR="$RESTORE_IMAGE_DIR"
LIBVIRT_DEFAULT_URI="$LIBVIRT_DEFAULT_URI"
REMOTE_HOST="$REMOTE_HOST"
REMOTE_USER="$REMOTE_USER"
REMOTE_BACKUP_PATH="$REMOTE_BACKUP_PATH"
RSYNC_SSH_KEY="$RSYNC_SSH_KEY"
ALERT_EMAIL_FROM="$ALERT_EMAIL_FROM"
ALERT_EMAIL_TO="$ALERT_EMAIL_TO"
RESEND_API_KEY="$RESEND_API_KEY"
NTFY_URL="$NTFY_URL"
QUIESCE_WITH_GUEST_AGENT="$QUIESCE_WITH_GUEST_AGENT"
FULL_RETENTION_DAYS="$FULL_RETENTION_DAYS"
LOGFILE="$LOGFILE"
RESTORE_LOGFILE="$RESTORE_LOGFILE"
RETENTION_LOGFILE="$RETENTION_LOGFILE"
EOF
chmod 600 "$CONFIG_FILE"

chmod +x "$SCRIPT_DIR/vm_backup.sh" "$SCRIPT_DIR/vm_restore.sh" "$SCRIPT_DIR/vm_retention.sh" "$SCRIPT_DIR/cleanup.sh" "$SCRIPT_DIR/setup.sh"

if [[ "$INSTALL_CRON" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
    cat >"$CRON_FILE" <<EOF
$BACKUP_SCHEDULE root $SCRIPT_DIR/vm_backup.sh >> $LOGFILE 2>&1
$RETENTION_SCHEDULE root $SCRIPT_DIR/vm_retention.sh >> $RETENTION_LOGFILE 2>&1
EOF
    chmod 644 "$CRON_FILE"
    echo "Wrote cron file: $CRON_FILE"
else
    echo "Skipped cron installation."
fi

echo "Wrote config: $CONFIG_FILE"
if [ -n "$REMOTE_HOST" ]; then
    echo "Backup mode: remote zstd stream to $REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_PATH"
else
    echo "Backup mode: local zstd-compressed full backups under $LOCAL_BACKUP_PATH"
fi
echo "Setup complete. Future updates should only require git pull in $SCRIPT_DIR."
