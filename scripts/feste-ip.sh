#!/usr/bin/env bash
# feste-ip.sh: switches the server from DHCP to a static IPv4 address and restarts Traefik
#
#   sudo IP=192.0.2.10 GW=192.0.2.1 DNS="192.0.2.53, 192.0.2.54" bash ~/docker/scripts/feste-ip.sh
#   Optional: IF=<interface> (default ens33)
#
# The SSH session on the old DHCP address drops after a few seconds; reconnect to the new address.
# Recovery: open the VM console and run  sudo rm /etc/netplan/99-homeserver-static.yaml && sudo netplan apply
#
# Reserve the address on the network's DHCP server or exclude it from the DHCP range,
# otherwise it can be assigned twice later.
# Traefik (LAN_IP, DOMAIN in traefik/.env), the certificates and the nip.io names depend on this address.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten"; exit 1; }

: "${IP:?IP setzen, z. B. sudo IP=192.0.2.10 GW=192.0.2.1 DNS=192.0.2.53 bash $0}"
: "${GW:?GW (Gateway) setzen}"
: "${DNS:?DNS setzen (kommagetrennt)}"
IF="${IF:-ens33}"
if ping -c1 -W1 "$IP" >/dev/null 2>&1 && ! ip -4 addr show "$IF" | grep -q "$IP/"; then
  echo "ABBRUCH: $IP antwortet schon, ein anderes Gerät benutzt die Adresse."; exit 1
fi

cat > /etc/netplan/99-homeserver-static.yaml <<NETPLAN
# Static IPv4 address for the homelab server, written by feste-ip.sh
network:
  version: 2
  ethernets:
    $IF:
      dhcp4: false
      addresses: [$IP/24]
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [$DNS]
NETPLAN
chmod 600 /etc/netplan/99-homeserver-static.yaml
netplan generate
echo "Konfiguration geprüft. Umstellung startet in 3 Sekunden, die Verbindung über die alte Adresse bricht dann ab."
echo "Danach in ca. 30 Sekunden per SSH auf $IP verbinden."

# Run in the background so it continues after the SSH session drops
nohup bash -c "sleep 3; netplan apply; sleep 8; docker restart traefik; sleep 5; docker ps --format '{{.Names}} {{.Status}}' | grep traefik > /root/feste-ip.log 2>&1" >/dev/null 2>&1 &
