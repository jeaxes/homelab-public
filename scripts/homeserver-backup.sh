#!/usr/bin/env bash
# homeserver-backup.sh: daily backup of the homelab data
#
#   sudo bash homeserver-backup.sh            create a backup now
#   sudo bash homeserver-backup.sh --install  also install a daily cron job at 03:15
#
# ADMIN_USER is the account that owns ~/docker (default: the user who invoked sudo).
# Backs up: n8n database (pg_dump), n8n data directory including the encryption key,
#           Gitea, Grafana, Uptime Kuma, Portainer (volumes), ~/docker without .git
# Target:   /var/backups/homelab/ADMIN_USER/<timestamp>-<random>/ (kept for 7 days)
# Ownership: root only (directories 700, files 600).
# Offsite:  export with an approved privileged backup process and encrypt the copy.

set -euo pipefail
umask 077
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten"; exit 1; }

ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
if [ -z "$ADMIN_USER" ] || [ "$ADMIN_USER" = root ]; then
  echo "ADMIN_USER setzen, z. B.: sudo ADMIN_USER=<name> bash $0 ${1:-}"; exit 1
fi
USER_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || { echo "Benutzer $ADMIN_USER nicht gefunden"; exit 1; }
[[ "$ADMIN_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*\$?$ ]] || { echo "Ungültiger ADMIN_USER"; exit 1; }
DEST_ROOT=/var/backups/homelab/$ADMIN_USER
KEEP_DAYS=7
LOG="$DEST_ROOT/backup.log"
# Refuse symlinks and user-writable ancestors before privileged file writes.
ensure_root_directory() {
  local path=$1 mode
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then mkdir -m 755 "$path"; fi
  [ -d "$path" ] && [ ! -L "$path" ] && [ "$(stat -c %u "$path")" = 0 ] || {
    echo "Unsicheres Backup-Verzeichnis: $path"; exit 1;
  }
  mode=$(stat -c %a "$path")
  (( (8#$mode & 022) == 0 )) || { echo "Backup-Verzeichnis ist fremd beschreibbar: $path"; exit 1; }
}
for parent in /var /var/backups /var/backups/homelab "$DEST_ROOT"; do ensure_root_directory "$parent"; done
if [ -e "$LOG" ] || [ -L "$LOG" ]; then
  [ -f "$LOG" ] && [ ! -L "$LOG" ] && [ "$(stat -c %u "$LOG")" = 0 ] || {
    echo "Unsichere Backup-Logdatei: $LOG"; exit 1;
  }
fi
# Never reopen an earlier completed backup for privileged output.
DEST=$(mktemp -d "$DEST_ROOT/$(date +%F_%H%M%S)-XXXXXXXX")
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

if [ "${1:-}" = "--install" ]; then
  install -m 750 "$0" /usr/local/sbin/homeserver-backup.sh
  echo "15 3 * * * root ADMIN_USER=$ADMIN_USER /usr/local/sbin/homeserver-backup.sh >/dev/null 2>&1" > /etc/cron.d/homeserver-backup
  chmod 644 /etc/cron.d/homeserver-backup
  log "Cronjob eingerichtet: täglich 03:15"
fi

log "Backup startet nach $DEST"

# 1) Consistent n8n database dump with pg_dump (credentials come from the container environment and are not printed)
PG=$(docker ps --format '{{.Names}} {{.Image}}' | awk '/postgres/{print $1; exit}')
if [ -n "$PG" ]; then
  docker exec "$PG" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$DEST/n8n-db.dump"
  log "n8n-Datenbank gesichert aus $PG ($(du -h "$DEST/n8n-db.dump" | cut -f1))"
else log "WARN: kein Postgres-Container gefunden"; fi

# 2) Container data directories. Containers using SQLite are stopped briefly so the file is consistent.
backup_mounts() {
  local c=$1 stop=$2 srcs
  docker ps -a --format '{{.Names}}' | grep -qx "$c" || { log "übersprungen: $c (nicht vorhanden)"; return; }
  srcs=$(docker inspect "$c" --format '{{range .Mounts}}{{if ne .Destination "/var/run/docker.sock"}}{{println .Source}}{{end}}{{end}}' | grep -v '^$' | grep -v docker.sock || true)
  [ -z "$srcs" ] && { log "übersprungen: $c (keine Daten-Mounts)"; return; }
  [ "$stop" = 1 ] && docker stop "$c" >/dev/null
  # shellcheck disable=SC2086
  tar -czf "$DEST/$c.tar.gz" --ignore-failed-read $srcs 2>/dev/null || true
  [ "$stop" = 1 ] && docker start "$c" >/dev/null
  log "$c gesichert ($(du -h "$DEST/$c.tar.gz" | cut -f1))"
}
backup_mounts n8n 0           # contains the config with the encryption key
backup_mounts gitea 1
backup_mounts grafana 1
backup_mounts uptime-kuma 1
backup_mounts portainer 1

# 3) Compose files and configuration (includes .env files, so store offsite copies encrypted only)
tar -czf "$DEST/docker-config.tar.gz" --exclude='.git' -C "$USER_HOME" docker
log "Konfiguration ~/docker gesichert ($(du -h "$DEST/docker-config.tar.gz" | cut -f1))"

# 4) Checksums, permissions, removal of old backups
( cd "$DEST" && sha256sum * > SHA256SUMS )
chmod 700 "$DEST"; chmod 600 "$DEST"/*
find "$DEST_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +$KEEP_DAYS -exec rm -rf {} +
log "Backup fertig: $(du -sh "$DEST" | cut -f1), aufbewahrt werden $KEEP_DAYS Tage"
