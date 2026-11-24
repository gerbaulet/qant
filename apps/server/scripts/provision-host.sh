#!/bin/sh

set -eu

PROGRAM_NAME="quant-provision"
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_KEY_FILE="${ADMIN_KEY_FILE:-}"
CONFIRM_TAILSCALE_SSH=0
MODE=""

log() {
    printf '\n[%s] %s\n' "$PROGRAM_NAME" "$*"
}

die() {
    printf '\n[%s] ERROR: %s\n' "$PROGRAM_NAME" "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  quant-provision prepare --admin-user USER --admin-key-file FILE
  quant-provision lockdown --admin-user USER --confirm-tailscale-ssh
  quant-provision status

prepare
  Creates the administrator account and installs its SSH public key, applies
  updates, configures automatic security updates, a 2 GiB swap file, Docker,
  Tailscale, fail2ban, kernel hardening, and a bootstrap firewall. Public SSH
  remains available until lockdown is run.

lockdown
  Disables SSH passwords and root login and removes public SSH from the host
  firewall. Run it only after standard SSH with the administrator key has been
  tested over Tailscale in a second terminal.

status
  Prints a privacy-safe summary of the relevant services and security state.
EOF
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run this command as root (or with sudo)."
}

validate_platform() {
    [ -r /etc/os-release ] || die "Cannot identify the operating system."
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "debian" ] || die "This script supports Debian only."
    [ "${VERSION_ID:-}" = "13" ] || die "This script was written for Debian 13; found ${VERSION_ID:-unknown}."
    [ "$(dpkg --print-architecture)" = "amd64" ] || die "This script currently supports amd64 only."
    command -v systemctl >/dev/null 2>&1 || die "systemd is required."
}

validate_admin_user() {
    [ -n "$ADMIN_USER" ] || die "Pass --admin-user USER."
    case "$ADMIN_USER" in
        *[!a-z0-9_-]*|'') die "The administrator user name contains unsupported characters." ;;
    esac
    case "$ADMIN_USER" in
        [a-z_]*) ;;
        *) die "The administrator user name must begin with a lower-case letter or underscore." ;;
    esac
    [ "$ADMIN_USER" != "root" ] || die "Choose a non-root administrator user."
}

validate_public_key() {
    [ -n "$ADMIN_KEY_FILE" ] || die "Pass --admin-key-file FILE."
    [ -f "$ADMIN_KEY_FILE" ] || die "SSH public key file not found: $ADMIN_KEY_FILE"
    [ "$(grep -cve '^[[:space:]]*$' "$ADMIN_KEY_FILE")" -eq 1 ] || die "The key file must contain exactly one public key."
    grep -Eq '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa)[[:space:]]+' "$ADMIN_KEY_FILE" \
        || die "The file does not look like an OpenSSH public key."
}

backup_once() {
    path="$1"
    if [ -e "$path" ] && [ ! -e "${path}.before-quant" ]; then
        cp -a "$path" "${path}.before-quant"
    fi
}

write_file() {
    destination="$1"
    mode="$2"
    temporary="$(mktemp)"
    cat >"$temporary"
    install -o root -g root -m "$mode" "$temporary" "$destination"
    rm -f "$temporary"
}

install_self() {
    source_path="$0"
    case "$source_path" in
        /*) ;;
        *) source_path="$(pwd)/$source_path" ;;
    esac
    if [ -f "$source_path" ]; then
        install -o root -g root -m 0750 "$source_path" /usr/local/sbin/quant-provision
    fi
}

configure_admin() {
    log "Creating the administrator account and installing its SSH key"
    if ! id "$ADMIN_USER" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash "$ADMIN_USER"
    fi
    usermod --append --groups sudo "$ADMIN_USER"

    admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [ -n "$admin_home" ] && [ -d "$admin_home" ] || die "Cannot determine the home directory for $ADMIN_USER."
    install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0700 "$admin_home/.ssh"
    touch "$admin_home/.ssh/authorized_keys"
    chmod 0600 "$admin_home/.ssh/authorized_keys"
    chown "$ADMIN_USER:$ADMIN_USER" "$admin_home/.ssh/authorized_keys"
    public_key="$(grep -v '^[[:space:]]*$' "$ADMIN_KEY_FILE")"
    if ! grep -Fqx "$public_key" "$admin_home/.ssh/authorized_keys"; then
        printf '%s\n' "$public_key" >>"$admin_home/.ssh/authorized_keys"
    fi

    password_state="$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')"
    if [ "$password_state" = "L" ]; then
        log "Set a local sudo password for $ADMIN_USER (it will not be accepted by SSH after lockdown)"
        passwd "$ADMIN_USER"
    fi
}

install_base_packages() {
    log "Installing updates and base security packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y -o Dpkg::Options::=--force-confold upgrade
    apt-get install -y \
        apparmor-utils \
        ca-certificates \
        curl \
        fail2ban \
        file \
        git \
        gnupg \
        jq \
        make \
        nftables \
        openssh-server \
        rsync \
        sudo \
        unattended-upgrades
    systemctl enable --now apparmor
}

configure_automatic_updates() {
    log "Enabling automatic security updates"
    write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    write_file /etc/apt/apt.conf.d/52quant-unattended-upgrades 0644 <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

configure_swap() {
    if swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
        log "Swap file is already active"
        return
    fi

    log "Creating a 2 GiB swap file"
    if [ -e /swapfile ]; then
        [ -f /swapfile ] || die "/swapfile exists but is not a regular file."
        file /swapfile | grep -q 'swap file' || die "/swapfile already exists but is not a swap file; refusing to overwrite it."
    else
        if ! fallocate -l 2G /swapfile; then
            dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
        fi
        chmod 0600 /swapfile
        mkswap /swapfile
    fi
    chmod 0600 /swapfile
    grep -Eq '^/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    swapon /swapfile
}

configure_kernel() {
    log "Applying conservative kernel and network hardening"
    write_file /etc/sysctl.d/99-quant-hardening.conf 0644 <<'EOF'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF
    sysctl --system >/dev/null
}

install_docker() {
    log "Installing Docker Engine from Docker's Debian repository"
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --silent --show-error --location \
        https://download.docker.com/linux/debian/gpg \
        --output /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    write_file /etc/apt/sources.list.d/docker.sources 0644 <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    backup_once /etc/docker/daemon.json
    write_file /etc/docker/daemon.json 0644 <<'EOF'
{
  "live-restore": true,
  "log-driver": "local",
  "log-opts": {
    "max-file": "3",
    "max-size": "10m"
  }
}
EOF
    systemctl enable --now containerd docker
    systemctl restart docker
}

install_tailscale() {
    log "Installing Tailscale from its Debian repository"
    curl --fail --silent --show-error --location \
        https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
        --output /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl --fail --silent --show-error --location \
        https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
        --output /etc/apt/sources.list.d/tailscale.list
    chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg /etc/apt/sources.list.d/tailscale.list

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y tailscale
    systemctl enable --now tailscaled
}

configure_fail2ban() {
    log "Enabling SSH rate limiting with fail2ban"
    install -d -m 0755 /etc/fail2ban/jail.d
    write_file /etc/fail2ban/jail.d/quant-sshd.local 0644 <<'EOF'
[sshd]
enabled = true
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
EOF
    systemctl enable --now fail2ban
    systemctl restart fail2ban
}

write_firewall() {
    firewall_mode="$1"
    log "Applying the $firewall_mode host firewall"
    backup_once /etc/nftables.conf

    if [ "$firewall_mode" = "bootstrap" ]; then
        ssh_rule='        tcp dport 22 accept comment "Temporary public SSH for bootstrap"'
    else
        ssh_rule='        iifname "tailscale0" accept comment "Private tailnet traffic"'
    fi

    temporary="$(mktemp)"
    cat >"$temporary" <<EOF
#!/usr/sbin/nft -f

destroy table inet quant_filter

table inet quant_filter {
    chain input {
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
$ssh_rule
        udp dport 41641 accept comment "Tailscale direct connections"
    }
}
EOF
    nft --check --file "$temporary"
    install -o root -g root -m 0755 "$temporary" /etc/nftables.conf
    rm -f "$temporary"
    nft --file /etc/nftables.conf

    # Debian's stock ExecStop flushes the complete ruleset. That would also
    # remove rules owned by Docker and Tailscale during a manual service
    # restart, so limit shutdown cleanup to this provisioner's own table.
    install -d -m 0755 /etc/systemd/system/nftables.service.d
    write_file /etc/systemd/system/nftables.service.d/quant-docker.conf 0644 <<'EOF'
[Service]
ExecStop=
ExecStop=/usr/sbin/nft destroy table inet quant_filter
EOF
    systemctl daemon-reload
    systemctl enable --now nftables
}

prepare_host() {
    validate_admin_user
    validate_public_key
    validate_platform
    install_self
    install_base_packages
    configure_admin
    configure_automatic_updates
    configure_swap
    configure_kernel
    install_docker
    install_tailscale
    configure_fail2ban
    write_firewall bootstrap
    install -d -o root -g root -m 0755 /opt/quant-server

    log "Preparation completed"
    cat <<EOF

Public SSH is intentionally still open and root/password login is unchanged.

Next steps:
  1. Join this host to your tailnet:
       sudo tailscale up
  2. In a second terminal, use the server's *.ts.net name and verify key login:
       ssh -o PasswordAuthentication=no ${ADMIN_USER}@SERVER-NAME.ts.net 'id'
  3. Also verify sudo in that Tailscale SSH session:
       ssh -t ${ADMIN_USER}@SERVER-NAME.ts.net 'sudo -v'
  4. Only after both tests succeed, run from that Tailscale session:
       sudo quant-provision lockdown --admin-user ${ADMIN_USER} --confirm-tailscale-ssh

Keep the current root session or provider web console open until step 4 has
completed and a fresh administrator login still succeeds.
EOF
}

tailscale_is_ready() {
    systemctl is-active --quiet tailscaled \
        && tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null \
        && tailscale ip -4 >/dev/null 2>&1
}

configure_sshd_lockdown() {
    log "Disabling root and password SSH authentication"
    backup_once /etc/ssh/sshd_config.d/00-quant-hardening.conf
    write_file /etc/ssh/sshd_config.d/00-quant-hardening.conf 0644 <<EOF
# Managed by quant-provision. This file sorts first because OpenSSH uses the
# first value it obtains for most keywords.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitUserEnvironment no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ${ADMIN_USER}
EOF

    /usr/sbin/sshd -t
    effective_config="$(/usr/sbin/sshd -T)"
    printf '%s\n' "$effective_config" | grep -qx 'permitrootlogin no' || die "Effective SSH configuration still permits root login."
    printf '%s\n' "$effective_config" | grep -qx 'passwordauthentication no' || die "Effective SSH configuration still permits passwords."
    printf '%s\n' "$effective_config" | grep -qx 'kbdinteractiveauthentication no' || die "Effective SSH configuration still permits keyboard-interactive login."
    printf '%s\n' "$effective_config" | grep -qx 'authenticationmethods publickey' || die "Effective SSH configuration does not require a public key."
    systemctl reload ssh
}

lockdown_host() {
    validate_admin_user
    validate_platform
    [ "$CONFIRM_TAILSCALE_SSH" -eq 1 ] || die "First test administrator SSH over Tailscale, then pass --confirm-tailscale-ssh."
    id "$ADMIN_USER" >/dev/null 2>&1 || die "Administrator user does not exist: $ADMIN_USER"
    admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [ -s "$admin_home/.ssh/authorized_keys" ] || die "No authorized key is installed for $ADMIN_USER."
    tailscale_is_ready || die "Tailscale is not connected. Run 'sudo tailscale up' first."

    configure_sshd_lockdown
    write_firewall locked
    configure_fail2ban

    log "Lockdown completed"
    cat <<EOF

New public SSH connections are now blocked. SSH is key-only and restricted to
${ADMIN_USER}; connect through the server's Tailscale address.

Do not close this session until a new login succeeds:
  ssh -o PasswordAuthentication=no ${ADMIN_USER}@SERVER-NAME.ts.net 'id'

The provider web console remains the recovery path if Tailscale is unavailable.
EOF
}

service_state() {
    service="$1"
    if systemctl is-active --quiet "$service"; then
        printf '%-24s %s\n' "$service" active
    else
        printf '%-24s %s\n' "$service" inactive
    fi
}

show_status() {
    validate_platform
    printf '%-24s %s\n' 'Operating system' "$(. /etc/os-release; printf '%s %s' "$PRETTY_NAME" "$(uname -m)")"
    service_state ssh
    service_state nftables
    service_state fail2ban
    service_state docker
    service_state tailscaled
    swap_summary="$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | awk 'NF {printf "%s%s %s", separator, $1, $2; separator=", "}')"
    printf '%-24s %s\n' 'Swap' "${swap_summary:-none}"
    printf '\nListening TCP/UDP sockets:\n'
    ss -lntup
    printf '\nEffective SSH settings:\n'
    /usr/sbin/sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods|allowusers|x11forwarding|allowtcpforwarding) '
    printf '\nQuant firewall table:\n'
    nft list table inet quant_filter 2>/dev/null || printf 'not configured\n'
    printf '\nTailscale status:\n'
    tailscale status 2>/dev/null || printf 'not connected\n'
}

[ "$#" -gt 0 ] || {
    usage
    exit 2
}

MODE="$1"
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --admin-user)
            [ "$#" -ge 2 ] || die "--admin-user needs a value."
            ADMIN_USER="$2"
            shift 2
            ;;
        --admin-key-file)
            [ "$#" -ge 2 ] || die "--admin-key-file needs a value."
            ADMIN_KEY_FILE="$2"
            shift 2
            ;;
        --confirm-tailscale-ssh)
            CONFIRM_TAILSCALE_SSH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

case "$MODE" in
    help|-h|--help) usage; exit 0 ;;
esac

require_root
case "$MODE" in
    prepare) prepare_host ;;
    lockdown) lockdown_host ;;
    status) show_status ;;
    *) usage; die "Unknown command: $MODE" ;;
esac
