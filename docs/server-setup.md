# Debian 13 host setup

This runbook provisions a fresh Debian 13 amd64 server without storing an
OpenRouter key on it. Every phone continues to send its own key for each job.

The setup intentionally has two security phases. `prepare` keeps the existing
public root/password SSH route available. `lockdown` is run only after a new
administrator account has successfully logged in with its key over Tailscale.
This avoids turning a key-copy mistake into a server lockout.

## 1. Create or select a key on the Mac

Do not overwrite an existing key. The following commands create one only when
the default private Ed25519 key is absent; if only its public file is missing,
they reconstruct that public file from the private key:

```sh
if [ ! -f "$HOME/.ssh/id_ed25519.pub" ]; then
  if [ -f "$HOME/.ssh/id_ed25519" ]; then
    ssh-keygen -y -f "$HOME/.ssh/id_ed25519" >"$HOME/.ssh/id_ed25519.pub"
  else
    ssh-keygen -t ed25519 -a 100 -f "$HOME/.ssh/id_ed25519"
  fi
fi
ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub"
```

## 2. Copy the bootstrap files using the current root password

From the Quant Server repository on the Mac:

```sh
scp scripts/provision-host.sh "$HOME/.ssh/id_ed25519.pub" \
  root@v2202611463479563802.supersrv.de:/root/
```

Keep the provider web console open as a recovery path. Then log in through the
current password-based route and run phase one:

```sh
ssh root@v2202611463479563802.supersrv.de
sh /root/provision-host.sh prepare \
  --admin-user clemens \
  --admin-key-file /root/id_ed25519.pub
```

The script asks once for a local password for `clemens`. It is used by `sudo`,
not by SSH after lockdown. Phase one then:

- installs current Debian updates and automatic security updates;
- creates and activates a 2 GiB swap file;
- installs Docker Engine and Compose from Docker's official Debian repository;
- installs Tailscale from Tailscale's official Debian repository;
- enables AppArmor, fail2ban, nftables, Docker, and Tailscale services;
- applies conservative kernel hardening;
- opens only SSH, Tailscale's UDP port, essential ICMP, and established traffic.

It does not put the administrator into the `docker` group because that group is
effectively root. Docker and Make commands on the host therefore use `sudo`.

## 3. Join Tailscale and test a second session

On the server:

```sh
tailscale up
tailscale status
```

Open the printed login URL, authorize the server, and note its full MagicDNS
name ending in `.ts.net`. On the Mac, while the original root session stays
open, test a new session through Tailscale:

```sh
ssh -o PasswordAuthentication=no clemens@SERVER-NAME.ts.net 'id'
ssh -t clemens@SERVER-NAME.ts.net 'sudo -v'
```

Both commands must succeed. If they do not, do not run lockdown; correct the key
or Tailscale connection from the original root session or web console.

## 4. Lock down SSH and the firewall

Run this from the working Tailscale SSH session:

```sh
sudo quant-provision lockdown \
  --admin-user clemens \
  --confirm-tailscale-ssh
```

This changes SSH to public-key-only, denies root SSH, restricts SSH to the
administrator, and removes public TCP port 22 from the host firewall. The
firewall still permits traffic arriving through `tailscale0`, Tailscale direct
connections on UDP 41641, essential ICMP, and established connections.

Before closing either existing session, test one more fresh login:

```sh
ssh -o PasswordAuthentication=no clemens@SERVER-NAME.ts.net 'id'
```

The provider's web console remains the recovery path. If the provider has a
separate network firewall, allow public TCP 22 only during bootstrap and remove
it after lockdown. UDP 41641 may remain allowed; Tailscale can still use relays
if it is unavailable. Do not expose public TCP 80, 443, or 8080.

## 5. Deploy Quant Server

From this repository on the Mac:

```sh
scripts/deploy-server.sh \
  --host SERVER-NAME.ts.net \
  --user clemens
```

The deployment accepts only a full private `.ts.net` host name, verifies
key-only access, uploads the source, starts the container, runs its health check,
and enables Tailscale Serve. Enter the resulting `https://...ts.net/` root URL
in Quant. Never enable Tailscale Funnel for this service.

Useful commands on the server are:

```sh
cd /opt/quant-server
sudo make status
sudo make logs
sudo make health
sudo make tailscale-status
sudo quant-provision status
```

## Recovery

Use the provider web console if Tailscale or SSH is unavailable. To temporarily
restore the bootstrap firewall from the console, rerun phase one with the
existing public key file. To inspect the machine without changing it:

```sh
sudo quant-provision status
```

Original files replaced by the provisioner are preserved once with the suffix
`.before-quant`.
