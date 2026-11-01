#!/usr/bin/env bash
# fertigstellen.sh: completes the server setup
#
#   sudo bash ~/docker/scripts/fertigstellen.sh
#   (ADMIN_USER defaults to the user who invoked sudo)
#
# 1. removes the temporary sudo grant used during setup
# 2. pins all images (only if the preview is clean)
# 3. creates a fresh backup
# 4. runs the final check
# 5. commits the changes (the push asks for the GitHub key passphrase)

set -u
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten: sudo bash $0"; exit 1; }
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
if [ -z "$ADMIN_USER" ] || [ "$ADMIN_USER" = root ]; then
  echo "ADMIN_USER setzen, z. B.: sudo ADMIN_USER=<name> bash $0"; exit 1
fi
USER_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || { echo "Benutzer $ADMIN_USER nicht gefunden"; exit 1; }
S=$USER_HOME/docker/scripts
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

step "1 Vorübergehende sudo-Freigabe entfernen"
rm -f /etc/sudoers.d/90-claude-temp
systemctl stop claude-sudo-ende.timer 2>/dev/null || true
[ -e /etc/sudoers.d/90-claude-temp ] && echo "!! Datei noch vorhanden" || echo "erledigt"

step "2 Images festschreiben"
PREVIEW=$(bash "$S/pin-images.sh" 2>&1)
echo "$PREVIEW"
if echo "$PREVIEW" | grep -q '^!!'; then
  echo; echo ">> Mindestens ein Container weicht von seiner Compose-Datei ab, Pinnen übersprungen. Abweichung prüfen und erneut starten."
elif echo "$PREVIEW" | grep -q -- '->'; then
  bash "$S/pin-images.sh" --apply
  sleep 20
  echo; docker ps --format '{{.Names}}\t{{.Status}}' | sort
else
  echo "Nichts zu pinnen."
fi

step "3 Frisches Backup"
ADMIN_USER="$ADMIN_USER" bash "$S/homeserver-backup.sh"

step "4 Abschluss-Check"
ADMIN_USER="$ADMIN_USER" bash "$S/homeserver-check.sh" | grep -E '\[(FAIL|WARN|FIX)\]|OK:'

step "5 Git"
cd "$USER_HOME/docker"
sudo -u "$ADMIN_USER" git add -A
sudo -u "$ADMIN_USER" git commit -q -m "chore: pin images and update scripts" && echo "committet" || echo "nichts zu committen"
echo "Push (fragt nach der Passphrase des GitHub-Schlüssels):"
sudo -u "$ADMIN_USER" git push

step "Fertig"
echo "Ausgabe ab '== 2' auf FAIL- und WARN-Zeilen prüfen."
