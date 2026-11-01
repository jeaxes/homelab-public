#!/usr/bin/env bash
# vm-setup.sh – Grundeinrichtung einer frischen Ubuntu-Server-VM nach dem homeserver-Standard
#
#   sudo bash vm-setup.sh <hostname> [ip/cidr gateway]
#
#   sudo GH_USER=<your-github-login> bash vm-setup.sh homeserver  # DHCP behalten
#   sudo DNS="192.0.2.53" bash vm-setup.sh homeserver 192.0.2.10/24 192.0.2.1
#
# Läuft in der VMware-Konsole direkt nach der Ubuntu-Installation (als der Benutzer, der dort angelegt wurde).
# Ablauf:
#   1. Pakete aktualisieren, Grundwerkzeuge, automatische Sicherheitsupdates
#   2. SSH-Schlüssel von GitHub holen (ssh-import-id gh:$GH_USER)
#   3. SSH härten – Passwort-Anmeldung wird NUR abgeschaltet, wenn ein Schlüssel hinterlegt ist
#   4. UFW (nur 22/80/443), fail2ban, Kernel-Härtung
#   5. Docker aus dem offiziellen Repo (Benutzer bewusst NICHT in der Gruppe docker)
#   6. optional feste IP
# Danach: sudo bash homeserver-check.sh (Pfade/IP darin anpassen) – erwartet FAIL: 0.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten: sudo bash $0 <hostname>"; exit 1; }
[ $# -ge 1 ] || { sed -n '4,7p' "$0"; exit 1; }

NEW_HOST=$1; IP=${2:-}; GW=${3:-}
ADMIN=${SUDO_USER:?Bitte mit sudo als normaler Benutzer starten, nicht als root}
ADMIN_HOME=$(getent passwd "$ADMIN" | cut -d: -f6)
GH_USER=${GH_USER:-}
DNS=${DNS:-}
# Validate before changing the host or importing any keys. No account is trusted implicitly.
[[ "$NEW_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || { echo "Ungültiger Hostname"; exit 1; }
[[ -z "$GH_USER" || "$GH_USER" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || { echo "Ungültiger GitHub-Name"; exit 1; }
[ -n "$IP" ] && [ -z "$GW" ] && { echo "Feste IP braucht auch das Gateway"; exit 1; }
[ -n "$IP" ] && [ -z "$DNS" ] && { echo "Feste IP braucht DNS (z. B. DNS=192.0.2.53)"; exit 1; }
[[ -z "$IP" || "$IP" =~ ^[0-9.]+/[0-9]{1,2}$ ]] || { echo "Ungültige IPv4/CIDR-Adresse"; exit 1; }
[[ -z "$GW" || "$GW" =~ ^[0-9.]+$ ]] || { echo "Ungültiges Gateway"; exit 1; }
[[ -z "$DNS" || "$DNS" =~ ^[0-9.,[:space:]]+$ ]] || { echo "Ungültige DNS-Adressen"; exit 1; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

step "1 Hostname, Updates, Grundpakete"
hostnamectl set-hostname "$NEW_HOST"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEW_HOST/" /etc/hosts
grep -q '^127\.0\.1\.1' /etc/hosts || echo "127.0.1.1 $NEW_HOST" >> /etc/hosts
timedatectl set-timezone Europe/Berlin
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get -y -q full-upgrade
apt-get -y -q install ca-certificates curl gnupg git ufw fail2ban unattended-upgrades \
  ssh-import-id open-vm-tools htop jq
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
  > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades

step "2 SSH-Schlüssel"
if [ -n "$GH_USER" ]; then
  echo "Importiere Schlüssel des ausdrücklich gewählten GitHub-Kontos: $GH_USER"
  sudo -u "$ADMIN" ssh-import-id "gh:$GH_USER" || { echo "!! Schlüsselimport fehlgeschlagen"; exit 1; }
else
  echo "Kein GH_USER gesetzt: kein Schlüsselimport. Bestehende authorized_keys bleiben erhalten."
fi
install -d -m 700 -o "$ADMIN" -g "$ADMIN" "$ADMIN_HOME/.ssh"
touch "$ADMIN_HOME/.ssh/authorized_keys"
chown "$ADMIN:$ADMIN" "$ADMIN_HOME/.ssh/authorized_keys"; chmod 600 "$ADMIN_HOME/.ssh/authorized_keys"
KEYS=$(grep -cE '^(ssh-|ecdsa-)' "$ADMIN_HOME/.ssh/authorized_keys" || true)
echo "Hinterlegte Schlüssel: $KEYS"
grep -E '^(ssh-|ecdsa-)' "$ADMIN_HOME/.ssh/authorized_keys" | awk '{print "   ", $1, $NF}' || true

step "3 SSH härten"
# 00- hat Vorrang vor 50-cloud-init.conf: sshd nimmt den ERSTEN Treffer
if [ "$KEYS" -gt 0 ]; then
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/00-keyonly.conf
  echo "Passwort-Anmeldung aus"
else
  rm -f /etc/ssh/sshd_config.d/00-keyonly.conf
  echo "!! KEIN Schlüssel hinterlegt – Passwort-Anmeldung bleibt AN, damit du dich nicht aussperrst."
  echo "   Später: Schlüssel eintragen und dieses Skript erneut starten."
fi
printf 'PermitRootLogin no\nPubkeyAuthentication yes\nX11Forwarding no\nMaxAuthTries 3\n' \
  > /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t && systemctl reload ssh

step "4 Firewall, fail2ban, Kernel"
ufw --force reset >/dev/null
ufw default deny incoming; ufw default allow outgoing
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
ufw --force enable
printf '[sshd]\nenabled = true\nbantime = 1h\nfindtime = 10m\nmaxretry = 5\n' > /etc/fail2ban/jail.d/sshd.local
systemctl enable --now fail2ban; systemctl restart fail2ban
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
EOF
sysctl -q --system

step "5 Docker"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get -y -q install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
# Log-Größe begrenzen, sonst läuft die Platte irgendwann voll
[ -f /etc/docker/daemon.json ] || printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' > /etc/docker/daemon.json
systemctl enable --now docker; systemctl restart docker
install -d -o "$ADMIN" -g "$ADMIN" "$ADMIN_HOME/docker"
docker version --format 'Docker {{.Server.Version}}'

if [ -n "$IP" ]; then
  step "6 Feste IP $IP"
  IF=$(ip -4 route show default | awk '{print $5; exit}')
  ADDR=${IP%/*}
  if ping -c1 -W1 "$ADDR" >/dev/null 2>&1 && ! ip -4 addr show "$IF" | grep -q "$ADDR/"; then
    echo "!! $ADDR antwortet schon – feste IP NICHT gesetzt"
  else
    cat > "/etc/netplan/99-$NEW_HOST-static.yaml" <<EOF
network:
  version: 2
  ethernets:
    $IF:
      dhcp4: false
      addresses: [$IP]
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [$DNS]
EOF
    chmod 600 "/etc/netplan/99-$NEW_HOST-static.yaml"
    netplan generate && netplan apply
    echo "IP im eigenen DHCP-Server reservieren, sonst droht eine Doppelvergabe."
  fi
fi

step "Fertig"
echo "Host:   $NEW_HOST   IP: $(hostname -I | awk '{print $1}')"
echo "Login:  ssh $ADMIN@$(hostname -I | awk '{print $1}')"
[ -f /var/run/reboot-required ] && echo "Neustart nötig (Kernel-Update): sudo reboot"
