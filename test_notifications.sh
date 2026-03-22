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

HYPERVISOR_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
MESSAGE=${1:-"vmbackup notification test from $HYPERVISOR_HOSTNAME"}

ntfy() {
    [ -n "$NTFY_URL" ] || { echo "NTFY_URL is not configured"; return 1; }
    curl -fsS -H "Title: VM Backup Alert ($HYPERVISOR_HOSTNAME)" -d "$1" "$NTFY_URL"
}

notify() {
    [ -n "$RESEND_API_KEY" ] || { echo "RESEND_API_KEY is not configured"; return 1; }
    [ -n "$ALERT_EMAIL_FROM" ] || { echo "ALERT_EMAIL_FROM is not configured"; return 1; }
    [ -n "$ALERT_EMAIL_TO" ] || { echo "ALERT_EMAIL_TO is not configured"; return 1; }
    curl -fsS -H "Authorization: Bearer $RESEND_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"from\":\"$ALERT_EMAIL_FROM\",\"to\":[\"$ALERT_EMAIL_TO\"],\"subject\":\"VM Backup [$HYPERVISOR_HOSTNAME]\",\"text\":\"$1\"}" \
        https://api.resend.com/emails
}

echo "Sending ntfy test"
ntfy "$MESSAGE"
echo
echo "Sending email test"
notify "$MESSAGE"
echo
echo "Notification tests completed"
