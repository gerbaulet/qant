#!/bin/sh

set -eu

HOST=""
REMOTE_USER=""
REMOTE_STAGE="quant-server-upload"

usage() {
    cat <<'EOF'
Usage: scripts/deploy-server.sh --host SERVER.tailnet.ts.net --user ADMIN

Copies the current Quant Server source to an already provisioned host over
Tailscale, starts the Compose service, checks it, and enables Tailscale Serve.
EOF
}

die() {
    printf 'deploy-server: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            [ "$#" -ge 2 ] || die "--host needs a value"
            HOST="$2"
            shift 2
            ;;
        --user)
            [ "$#" -ge 2 ] || die "--user needs a value"
            REMOTE_USER="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "$HOST" ] || die "pass --host"
[ -n "$REMOTE_USER" ] || die "pass --user"
case "$HOST" in
    *.ts.net) ;;
    *) die "use the server's full private *.ts.net name, not its public DNS name" ;;
esac
case "$REMOTE_USER" in
    *[!a-z0-9_-]*|'') die "unsupported remote user name" ;;
esac

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SOURCE_DIR="$(dirname -- "$SCRIPT_DIR")"
TARGET="${REMOTE_USER}@${HOST}"

[ -f "$SOURCE_DIR/compose.yaml" ] || die "compose.yaml not found beside scripts/"

printf 'Checking key-only Tailscale SSH access to %s...\n' "$TARGET"
ssh -o BatchMode=yes -o PasswordAuthentication=no "$TARGET" 'command -v sudo >/dev/null && command -v rsync >/dev/null && command -v docker >/dev/null'

printf 'Uploading Quant Server source...\n'
rsync -az --delete \
    --exclude '.git/' \
    --exclude '.DS_Store' \
    "$SOURCE_DIR/" "$TARGET:$REMOTE_STAGE/"

printf 'Installing and starting Quant Server...\n'
ssh -t "$TARGET" \
    'set -eu
     test -d "$HOME/quant-server-upload"
     sudo install -d -o root -g root -m 0755 /opt/quant-server
     sudo rsync -a --delete --exclude ".git/" "$HOME/quant-server-upload/" /opt/quant-server/
     cd /opt/quant-server
     sudo make up
     sudo make health
     sudo make tailscale-up
     sudo make tailscale-status'

printf '\nDeployment completed. Use the HTTPS URL printed by Tailscale Serve in Quant.\n'
