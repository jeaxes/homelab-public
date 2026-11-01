#!/usr/bin/env bash
# homeserver-check.sh: security and health check for the homelab server
#
#   sudo bash homeserver-check.sh          check only (changes nothing)
#   sudo bash homeserver-check.sh --fix    check and apply the safe corrections defined below
#
# Configuration:
#   ADMIN_USER   account that owns ~/docker (default: the user who invoked sudo)
#   SRV_IP       address Traefik listens on (default: LAN_IP from ~/docker/traefik/.env)
#   DOMAIN       base domain of the web services (default: DOMAIN from ~/docker/traefik/.env)
#
# Report: /var/log/homelab/ADMIN_USER/check-<timestamp>-<random>.txt (root only)
# Rating: OK = fine, WARN = review, FAIL = fix

set -u
umask 077
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten: sudo bash $0 ${1:-}"; exit 1; }

ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
if [ -z "$ADMIN_USER" ] || [ "$ADMIN_USER" = root ]; then
  echo "ADMIN_USER setzen, z. B.: sudo ADMIN_USER=<name> bash $0 ${1:-}"; exit 1
fi
USER_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || { echo "Benutzer $ADMIN_USER nicht gefunden"; exit 1; }
DOCKER_DIR=$USER_HOME/docker
# Read a value from traefik/.env without sourcing the file
env_value() { grep -E "^$1=" "$DOCKER_DIR/traefik/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'"; }
SRV_IP="${SRV_IP:-$(env_value LAN_IP)}"   # Traefik listens on this address, not on 127.0.0.1
DOMAIN="${DOMAIN:-$(env_value DOMAIN)}"
if [ -z "$SRV_IP" ] || [ -z "$DOMAIN" ]; then
  echo "SRV_IP und DOMAIN fehlen: in $DOCKER_DIR/traefik/.env (LAN_IP, DOMAIN) eintragen oder beim Aufruf setzen"; exit 1
fi
[[ "$ADMIN_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*\$?$ ]] || { echo "Ungültiger ADMIN_USER"; exit 1; }
OUT_DIR=/var/log/homelab/$ADMIN_USER
for parent in /var /var/log /var/log/homelab "$OUT_DIR"; do
  if [ ! -e "$parent" ] && [ ! -L "$parent" ]; then mkdir -m 755 "$parent" || exit 1; fi
  [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(stat -c %u "$parent")" = 0 ] || {
    echo "Unsicheres Report-Verzeichnis: $parent"; exit 1;
  }
  mode=$(stat -c %a "$parent")
  (( (8#$mode & 022) == 0 )) || { echo "Report-Verzeichnis ist fremd beschreibbar: $parent"; exit 1; }
done
REPORT=$(mktemp "$OUT_DIR/check-$(date +%F_%H%M%S)-XXXXXXXX.txt") || exit 1
exec > >(tee "$REPORT") 2>&1

ok=0; warn=0; fail=0; fixed=0
OK()   { printf '  [OK]   %s\n' "$*"; ok=$((ok+1)); }
WARN() { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }
FAIL() { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
FIXD() { printf '  [FIX]  %s\n' "$*"; fixed=$((fixed+1)); }
H()    { printf '\n== %s ==\n' "$*"; }

echo "homeserver-Check $(date '+%d.%m.%Y %H:%M')  Modus: $([ $FIX -eq 1 ] && echo 'prüfen + beheben' || echo 'nur prüfen')"
echo "Host: $(hostname)  Kernel: $(uname -r)  OS: $(. /etc/os-release; echo "$PRETTY_NAME")"

# ---------------------------------------------------------------- System
H "1 System und Updates"
apt-get update -qq >/dev/null 2>&1
UPG=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
SEC=$(apt list --upgradable 2>/dev/null | grep -ci -- '-security')
if [ "$UPG" -eq 0 ]; then OK "Keine Updates offen"; elif [ "$SEC" -gt 0 ]; then FAIL "$UPG Updates offen, davon $SEC Sicherheitsupdates"; else WARN "$UPG Updates offen (keine Sicherheitsupdates)"; fi
if [ -f /var/run/reboot-required ]; then WARN "Neustart nötig ($(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' '))"; else OK "Kein Neustart nötig"; fi
systemctl is-active --quiet unattended-upgrades && OK "unattended-upgrades aktiv" || FAIL "unattended-upgrades nicht aktiv"
grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && OK "Automatische Sicherheitsupdates eingeschaltet" || FAIL "20auto-upgrades fehlt oder aus"
timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes && OK "Uhrzeit synchron (NTP)" || WARN "Uhrzeit nicht per NTP synchron"
UP=$(uptime -p); echo "  [INFO] Laufzeit: $UP"

H "2 Ressourcen"
DISK=$(df --output=pcent / | tail -1 | tr -dc 0-9)
[ "$DISK" -lt 75 ] && OK "Festplatte / ${DISK}% belegt" || { [ "$DISK" -lt 90 ] && WARN "Festplatte / ${DISK}% belegt" || FAIL "Festplatte / ${DISK}% belegt"; }
INODE=$(df --output=ipcent / | tail -1 | tr -dc 0-9)
[ "$INODE" -lt 80 ] && OK "Inodes ${INODE}%" || WARN "Inodes ${INODE}%"
MEM=$(free | awk '/Mem:/{printf "%d", ($3/$2)*100}')
[ "$MEM" -lt 85 ] && OK "RAM ${MEM}% belegt" || WARN "RAM ${MEM}% belegt"
LOAD=$(cut -d' ' -f1 /proc/loadavg); CPUS=$(nproc)
awk -v l="$LOAD" -v c="$CPUS" 'BEGIN{exit !(l < c)}' && OK "Last $LOAD bei $CPUS CPUs" || WARN "Last $LOAD bei $CPUS CPUs"
JERR=$(journalctl -p err --since "24 hours ago" -q --no-pager 2>/dev/null | wc -l)
[ "$JERR" -lt 50 ] && OK "$JERR Fehlermeldungen im Journal (24 h)" || WARN "$JERR Fehlermeldungen im Journal (24 h) – journalctl -p err --since today"

# ---------------------------------------------------------------- SSH
H "3 SSH"
SSHT=$(sshd -T 2>/dev/null)
v() { echo "$SSHT" | awk -v k="$1" '$1==k{print $2; exit}'; }
[ "$(v passwordauthentication)" = "no" ] && OK "Passwort-Anmeldung aus" || {
  FAIL "Passwort-Anmeldung ist AN (effektiver Wert). Gesetzt in: $(grep -ril '^[[:space:]]*passwordauthentication[[:space:]]*yes' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | tr '\n' ' ')"
  if [ $FIX -eq 1 ]; then
    printf '# Takes precedence over 50-cloud-init.conf: sshd uses the FIRST match\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/00-keyonly.conf
    if sshd -t; then systemctl reload ssh && FIXD "00-keyonly.conf angelegt, SSH neu geladen (bestehende Sitzung bleibt offen)"; else rm -f /etc/ssh/sshd_config.d/00-keyonly.conf; FAIL "sshd -t meldet Fehler – Änderung zurückgenommen"; fi
  fi; }
[ "$(v kbdinteractiveauthentication)" = "no" ] && OK "Keyboard-Interactive aus" || FAIL "Keyboard-Interactive an"
case "$(v permitrootlogin)" in no) OK "Root-Login verboten";; prohibit-password|without-password) WARN "Root nur per Schlüssel (besser: no)";; *) FAIL "Root-Login erlaubt";; esac
[ "$(v pubkeyauthentication)" = "yes" ] && OK "Schlüssel-Anmeldung an" || FAIL "Schlüssel-Anmeldung aus"
[ "$(v x11forwarding)" = "no" ] && OK "X11-Forwarding aus" || WARN "X11-Forwarding an"
MAT=$(v maxauthtries); [ "${MAT:-6}" -le 4 ] && OK "MaxAuthTries $MAT" || WARN "MaxAuthTries ${MAT:-6} (empfohlen 3)"
[ "$(v permitemptypasswords)" = "no" ] && OK "Leere Passwörter verboten" || FAIL "Leere Passwörter erlaubt"
FAILED=$(journalctl -u ssh --since "24 hours ago" -q --no-pager 2>/dev/null | grep -ciE 'failed|invalid user')
echo "  [INFO] Fehlgeschlagene SSH-Versuche 24 h: $FAILED"

# ---------------------------------------------------------------- Firewall
H "4 Firewall und offene Ports"
UFW=$(ufw status verbose 2>/dev/null)
echo "$UFW" | grep -q 'Status: active' && OK "UFW aktiv" || FAIL "UFW nicht aktiv"
echo "$UFW" | grep -q 'deny (incoming)' && OK "Standard: eingehend blockiert" || FAIL "Standard eingehend nicht deny"
echo "  [INFO] UFW-Regeln:"; ufw status numbered 2>/dev/null | grep '\[' | sed 's/^/         /'
systemctl is-active --quiet fail2ban && OK "fail2ban aktiv ($(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{gsub(/^[ \t]+/,"",$2); print $2}'))" || FAIL "fail2ban nicht aktiv"
BANNED=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Total banned/{gsub(/ /,"",$2); print $2}')
echo "  [INFO] fail2ban sshd insgesamt gesperrt: ${BANNED:-?}"
echo "  [INFO] Dienste, die auf ALLEN Schnittstellen lauschen:"
PUB=$(ss -Hltnp | awk '{print $4, $6}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' )
echo "$PUB" | sed 's/users:((\("[^"]*"\).*/\1/; s/^/         /'
BAD=$(echo "$PUB" | awk '{split($1,a,":"); p=a[length(a)]; if (p!=22 && p!=80 && p!=443) print p}' | sort -u | tr '\n' ' ')
[ -z "$BAD" ] && OK "Nur 22/80/443 auf allen Schnittstellen" || WARN "Zusätzlich offen auf allen Schnittstellen: $BAD (UFW prüfen – Docker umgeht UFW!)"

# ---------------------------------------------------------------- Kernel
H "5 Kernel-Härtung"
chk() { local k=$1 want=$2 cur; cur=$(sysctl -n "$k" 2>/dev/null); [ "$cur" = "$want" ] && OK "$k = $cur" || WARN "$k = ${cur:-?} (Soll $want)"; }
chk net.ipv4.conf.all.rp_filter 1
chk net.ipv4.conf.all.accept_redirects 0
chk net.ipv4.conf.all.send_redirects 0
chk net.ipv4.tcp_syncookies 1
chk kernel.kptr_restrict 2
chk kernel.dmesg_restrict 1
chk fs.protected_symlinks 1
aa-status --enabled 2>/dev/null && OK "AppArmor aktiv ($(aa-status 2>/dev/null | awk '/profiles are in enforce mode/{print $1}') Profile erzwungen)" || WARN "AppArmor nicht aktiv"

# ---------------------------------------------------------------- Users
H "6 Benutzer und Rechte"
UID0=$(awk -F: '$3==0{print $1}' /etc/passwd | tr '\n' ' ')
[ "$UID0" = "root " ] && OK "Nur root hat UID 0" || FAIL "UID 0: $UID0"
SHELLS=$(awk -F: '$7 !~ /(nologin|false|sync)$/ {print $1}' /etc/passwd | tr '\n' ' ')
echo "  [INFO] Konten mit Login-Shell: $SHELLS"
SUDO=$(getent group sudo | cut -d: -f4)
echo "  [INFO] sudo-Gruppe: $SUDO"
grep -rqs 'NOPASSWD' /etc/sudoers /etc/sudoers.d/ && WARN "NOPASSWD-Einträge in sudoers" || OK "Kein NOPASSWD in sudoers"
[ "$(stat -c %a $USER_HOME/.ssh 2>/dev/null)" = "700" ] && OK "~/.ssh Rechte 700" || WARN "~/.ssh Rechte $(stat -c %a $USER_HOME/.ssh 2>/dev/null)"
[ "$(stat -c %a $USER_HOME/.ssh/authorized_keys 2>/dev/null)" = "600" ] && OK "authorized_keys Rechte 600" || WARN "authorized_keys Rechte $(stat -c %a $USER_HOME/.ssh/authorized_keys 2>/dev/null)"
echo "  [INFO] Hinterlegte SSH-Schlüssel: $(grep -cE '^(ssh|ecdsa)' $USER_HOME/.ssh/authorized_keys 2>/dev/null)"

# ---------------------------------------------------------------- Docker
H "7 Docker"
systemctl is-active --quiet docker && OK "Docker läuft ($(docker version --format '{{.Server.Version}}' 2>/dev/null))" || FAIL "Docker läuft nicht"
TOTAL=$(docker ps -a -q | wc -l); RUN=$(docker ps -q | wc -l)
[ "$TOTAL" -eq "$RUN" ] && OK "$RUN von $TOTAL Containern laufen" || FAIL "$RUN von $TOTAL Containern laufen – gestoppt: $(docker ps -a --filter status=exited --format '{{.Names}}' | tr '\n' ' ')"
UNH=$(docker ps --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ')
[ -z "$UNH" ] && OK "Kein Container unhealthy" || FAIL "Unhealthy: $UNH"
RST=$(docker ps -q | xargs -r docker inspect --format '{{.Name}} {{.RestartCount}}' | awk '$2>3{print $1"("$2")"}' | tr '\n' ' ')
[ -z "$RST" ] && OK "Keine Neustart-Schleifen" || WARN "Häufige Neustarts: $RST"
PRIV=$(docker ps -q | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.Privileged}}' | awk '$2=="true"{print $1}' | tr '\n' ' ')
[ -z "$PRIV" ] && OK "Kein Container privileged" || WARN "Privileged: $PRIV"
SOCK=$(docker ps -q | xargs -r docker inspect --format '{{.Name}}{{range .Mounts}} {{.Source}}{{end}}' | grep docker.sock | awk '{print $1}' | tr '\n' ' ')
echo "  [INFO] docker.sock eingebunden bei: ${SOCK:-keinem}  (sollte nur Socket-Proxys/Portainer/Alloy/Traefik sein)"
EXPOSED=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0:|\[::\]:' | grep -vE '0\.0\.0\.0:(80|443)->' | awk '{print $1}' | tr '\n' ' ')
[ -z "$EXPOSED" ] && OK "Keine Container-Ports außer 80/443 öffentlich gebunden" || FAIL "Öffentlich gebundene Ports bei: $EXPOSED (auf 127.0.0.1 binden)"
LATEST=$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 !~ /:/ || $2 ~ /:latest$/ {print $1}' | tr '\n' ' ')
[ -z "$LATEST" ] && OK "Alle Images mit fester Version" || WARN "Images ohne feste Version (latest): $LATEST"
DRIFT=""
while read -r c <&3; do
  wd=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
  [ -z "$wd" ] && continue
  fls=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
  sv=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.service"}}')
  rh=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  fa=(); IFS=',' read -ra fl <<< "$fls"; for f in "${fl[@]}"; do fa+=(-f "$f"); done
  fh=$(cd "$wd" 2>/dev/null && docker compose "${fa[@]}" config --hash "$sv" 2>/dev/null | awk '{print $2}')
  [ "$fh" = "$rh" ] || DRIFT="$DRIFT $c"
done 3< <(docker ps --format '{{.Names}}')
[ -z "$DRIFT" ] && OK "Alle Compose-Dateien passen zu den laufenden Containern" || FAIL "Compose-Datei weicht vom laufenden Container ab:$DRIFT (beim nächsten 'up' würde sich etwas ändern – git log/diff prüfen)"
DANG=$(docker images -f dangling=true -q | wc -l); RECL=$(docker system df --format '{{.Type}} {{.Reclaimable}}' | awk '/Images/{print $2}')
echo "  [INFO] Verwaiste Images: $DANG, freigebbar: $RECL"
[ "$(stat -c %a /var/run/docker.sock)" = "660" ] && OK "docker.sock Rechte 660" || WARN "docker.sock Rechte $(stat -c %a /var/run/docker.sock)"
echo "  [INFO] Container:"; docker ps --format '         {{.Names}}\t{{.Status}}\t{{.Image}}' | sort

# ---------------------------------------------------------------- Secrets
H "8 Zugangsdaten und Git"
while read -r f; do
  p=$(stat -c %a "$f")
  if [ "$p" = "600" ] || [ "$p" = "640" ]; then OK "${f#$DOCKER_DIR/} Rechte $p"
  else WARN "${f#$DOCKER_DIR/} Rechte $p (Soll 600)"; [ $FIX -eq 1 ] && chmod 600 "$f" && FIXD "${f#$DOCKER_DIR/} auf 600 gesetzt"; fi
done < <(find "$DOCKER_DIR" -maxdepth 3 -name '.env' 2>/dev/null)
if [ -d "$DOCKER_DIR/.git" ]; then
  TRACKED=$(sudo -u "$ADMIN_USER" git -C "$DOCKER_DIR" ls-files | grep -Ei '(^|/)\.env$|token|secret|\.key$|password|dashboard-auth' | tr '\n' ' ')
  [ -z "$TRACKED" ] && OK "Keine Geheimnis-Dateien im Git" || FAIL "Im Git versioniert: $TRACKED"
  DIRTY=$(sudo -u "$ADMIN_USER" git -C "$DOCKER_DIR" status --porcelain | wc -l)
  [ "$DIRTY" -eq 0 ] && OK "Git: alles committet" || WARN "Git: $DIRTY ungesicherte Änderungen (git status)"
  AHEAD=$(sudo -u "$ADMIN_USER" git -C "$DOCKER_DIR" rev-list --count @{u}..HEAD 2>/dev/null || echo "?")
  [ "$AHEAD" = "0" ] && OK "Git: alles zu GitHub gepusht" || WARN "Git: $AHEAD Commits nicht gepusht"
fi

# ---------------------------------------------------------------- n8n
H "9 n8n"
if docker ps --format '{{.Names}}' | grep -qx n8n; then
  N8NV=$(docker exec n8n n8n --version 2>/dev/null | tail -1)
  echo "  [INFO] n8n-Version: $N8NV  (mit https://github.com/n8n-io/n8n/security/advisories abgleichen)"
  ENVK=$(docker inspect n8n --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1)
  envv() { docker inspect n8n --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= -v k="$1" '$1==k{print $2}'; }
  echo "$ENVK" | grep -qx N8N_ENCRYPTION_KEY && OK "N8N_ENCRYPTION_KEY gesetzt (Wert nicht angezeigt)" || WARN "N8N_ENCRYPTION_KEY nicht als Umgebungsvariable gesetzt (liegt dann nur im Volume – sichern!)"
  [ "$(envv N8N_BLOCK_ENV_ACCESS_IN_NODE)" = "true" ] && OK "Env-Zugriff aus Workflows gesperrt" || WARN "N8N_BLOCK_ENV_ACCESS_IN_NODE nicht true"
  if echo "$(envv NODES_EXCLUDE)" | grep -q executeCommand; then OK "Execute-Command-Node per NODES_EXCLUDE gesperrt"
  elif [ -z "$(envv NODES_EXCLUDE)" ] && [ "${N8NV%%.*}" -ge 2 ] 2>/dev/null; then OK "Execute-Command-Node gesperrt (Standard ab n8n 2.x)"
  else WARN "NODES_EXCLUDE sperrt executeCommand nicht"; fi
  [ "$(envv EXECUTIONS_DATA_PRUNE)" = "true" ] && OK "Ausführungsdaten werden aufgeräumt (max. $(envv EXECUTIONS_DATA_MAX_AGE) h)" || WARN "EXECUTIONS_DATA_PRUNE nicht gesetzt"
  [ "$(envv DB_TYPE)" = "postgresdb" ] && OK "Datenbank PostgreSQL" || WARN "Datenbank nicht PostgreSQL"
  [ "$(envv N8N_SECURE_COOKIE)" != "false" ] && OK "Secure Cookie an" || WARN "N8N_SECURE_COOKIE=false"
  docker port n8n 2>/dev/null | grep -q '0.0.0.0' && FAIL "n8n-Port direkt veröffentlicht" || OK "n8n nur über Traefik erreichbar"
  MET=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 --resolve n8n.$DOMAIN:443:$SRV_IP https://n8n.$DOMAIN/metrics)
  if [ "$MET" = "200" ]; then
    WARN "n8n /metrics über Traefik ohne Anmeldung erreichbar (nur intern für Prometheus nötig)"
    EP=$(docker inspect n8n --format '{{range $k,$v := .Config.Labels}}{{println $k "=" $v}}{{end}}' | awk -F' = ' '/routers\..*\.entrypoints/{print $2; exit}')
    DYN="$DOCKER_DIR/traefik/dynamic"
    if [ $FIX -eq 1 ] && [ -n "$EP" ] && [ -d "$DYN" ]; then
      cat > "$DYN/n8n-metrics-block.yml" <<EOF
# Blocks external access to n8n /metrics. Prometheus scrapes http://n8n:5678/metrics internally.
http:
  routers:
    n8n-metrics-block:
      rule: 'HostRegexp(\`^n8n\..+\`) && PathPrefix(\`/metrics\`)'
      entryPoints: [$EP]
      priority: 10000
      service: noop@internal
      middlewares: [n8n-metrics-deny]
      tls: {}
  middlewares:
    n8n-metrics-deny:
      ipAllowList:
        sourceRange: ["127.0.0.2/32"]
EOF
      chown "$ADMIN_USER:" "$DYN/n8n-metrics-block.yml"; sleep 4
      MET2=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 --resolve n8n.$DOMAIN:443:$SRV_IP https://n8n.$DOMAIN/metrics)
      ROOT2=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 --resolve n8n.$DOMAIN:443:$SRV_IP https://n8n.$DOMAIN/)
      if [ "$MET2" = "403" ] && [ "$ROOT2" = "200" ]; then FIXD "/metrics über Traefik gesperrt (403), n8n selbst weiter erreichbar"
      else rm -f "$DYN/n8n-metrics-block.yml"; FAIL "Sperre wirkte nicht (metrics $MET2, n8n $ROOT2) – Datei wieder entfernt"; fi
    fi
  else OK "n8n /metrics von außen gesperrt ($MET)"; fi
  PG=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -i postgres | grep -c '0.0.0.0')
  [ "$PG" -eq 0 ] && OK "PostgreSQL nicht veröffentlicht" || FAIL "PostgreSQL-Port veröffentlicht"
else FAIL "n8n-Container läuft nicht"; fi

# ---------------------------------------------------------------- Traefik
H "10 Traefik und Zertifikate"
if docker ps --format '{{.Names}}' | grep -qx traefik; then
  echo "  [INFO] Traefik $(docker exec traefik traefik version 2>/dev/null | awk '/Version/{print $2; exit}')"
  for h in n8n gitea tools traefik; do
    c=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 --resolve $h.$DOMAIN:443:$SRV_IP https://$h.$DOMAIN/)
    case "$h:$c" in traefik:401) OK "$h: Anmeldung nötig (401)";; traefik:*) FAIL "$h: Dashboard ohne Anmeldung? ($c)";; *:200|*:302) OK "$h erreichbar ($c)";; *) WARN "$h antwortet $c";; esac
    exp=$(echo | openssl s_client -connect $SRV_IP:443 -servername $h.$DOMAIN 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$exp" ] && { d=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 )); [ $d -gt 30 ] && OK "  Zertifikat $h gültig noch $d Tage" || WARN "  Zertifikat $h läuft in $d Tagen ab"; }
  done
  TLS11=$(echo | openssl s_client -connect $SRV_IP:443 -tls1_1 -servername n8n.$DOMAIN 2>&1 | grep -c 'Cipher is (NONE)\|alert\|no protocols')
  [ "$TLS11" -gt 0 ] && OK "TLS 1.1 abgelehnt" || WARN "TLS 1.1 möglicherweise erlaubt"
  echo "  [INFO] Traefik-Entrypoints: $(docker inspect traefik --format '{{range .Args}}{{println .}}{{end}}' | grep -oE 'entrypoints\.[a-z0-9]+\.address=[^ ]+' | tr '\n' ' ')"
  echo "  [INFO] Dynamische Dateien: $(ls $DOCKER_DIR/traefik/dynamic 2>/dev/null | tr '\n' ' ')"
  echo "  [INFO] n8n-Router: $(docker inspect n8n --format '{{range $k,$v := .Config.Labels}}{{println $k "=" $v}}{{end}}' | grep -E 'routers\..*\.(rule|entrypoints|middlewares)' | tr '\n' ' ')"
else FAIL "Traefik läuft nicht"; fi

# ---------------------------------------------------------------- Monitoring
H "11 Monitoring und Alarme"
T=$(curl -s -m 5 http://127.0.0.1:9090/api/v1/targets 2>/dev/null)
if [ -n "$T" ]; then
  UPN=$(echo "$T" | grep -o '"health":"up"' | wc -l); DN=$(echo "$T" | grep -o '"health":"down"' | wc -l)
  [ "$DN" -eq 0 ] && OK "Prometheus: alle $UPN Ziele up" || FAIL "Prometheus: $DN Ziele down: $(echo "$T" | grep -oE '"job":"[^"]+"[^}]*"health":"down"' | grep -oE '"job":"[^"]+"' | cut -d'"' -f4 | sort -u | tr '\n' ' ')"
else WARN "Prometheus-API nicht erreichbar (127.0.0.1:9090)"; fi
FIRING=$(curl -s -m 5 http://127.0.0.1:9093/api/v2/alerts?active=true 2>/dev/null | grep -o '"alertname":"[^"]*"' | cut -d'"' -f4 | sort -u | tr '\n' ' ')
[ -z "$FIRING" ] && OK "Alertmanager: keine aktiven Alarme" || WARN "Aktive Alarme: $FIRING"
curl -s -m 5 http://127.0.0.1:3100/ready 2>/dev/null | grep -q ready && OK "Loki bereit" || echo "  [INFO] Loki nicht auf 127.0.0.1:3100 erreichbar (ggf. nur im Docker-Netz – dann ok)"
curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:3002/api/health 2>/dev/null | grep -q 200 && OK "Grafana gesund" || WARN "Grafana-Health nicht 200"

# ---------------------------------------------------------------- Backup
H "12 Backups"
BK=$(find / -xdev \( -path /proc -o -path /sys \) -prune -o -type f \( -name '*n8n*.sql*' -o -name '*backup*.tar*' -o -name '*.dump' \) -mtime -8 -print 2>/dev/null | head -3)
[ -n "$BK" ] && OK "Backup der letzten 7 Tage gefunden: $(echo $BK | tr '\n' ' ')" || FAIL "Kein Backup der letzten 7 Tage gefunden (n8n-Datenbank + Encryption-Key, Gitea, Grafana)"

# ---------------------------------------------------------------- Result
H "Ergebnis"
printf '  OK: %d   WARN: %d   FAIL: %d   behoben: %d\n' "$ok" "$warn" "$fail" "$fixed"
echo "  Bericht: $REPORT"
chmod 600 "$REPORT"
