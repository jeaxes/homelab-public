#!/usr/bin/env bash
# pin-images.sh: writes the digest of the running image into the Compose file for every container
# without a fixed version, so a later "docker compose pull" does not start anything unexpected.
#
#   bash pin-images.sh           preview the changes only
#   bash pin-images.sh --apply   edit the Compose files (backup *.bak), validate, recreate the containers
#
# Deliberate updates: replace the digest line with the new version, then "docker compose pull && docker compose up -d".

set -euo pipefail
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
DOCKER="docker"; docker ps >/dev/null 2>&1 || DOCKER="sudo docker"
changed_dirs=()

while read -r name <&3; do   # separate fd 3: docker/sudo must not consume stdin
  img=$($DOCKER inspect "$name" --format '{{.Config.Image}}')
  # only images without a tag or with :latest
  if [[ "$img" == *@sha256:* ]] || { [[ "${img##*/}" == *:* ]] && [[ "$img" != *:latest ]]; }; then continue; fi
  dir=$($DOCKER inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
  files=$($DOCKER inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
  svc=$($DOCKER inspect "$name" --format '{{index .Config.Labels "com.docker.compose.service"}}')
  runhash=$($DOCKER inspect "$name" --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  fargs=(); IFS=',' read -ra fl <<< "$files"; for f in "${fl[@]}"; do fargs+=(-f "$f"); done
  file=${fl[0]}
  # Safety net: does the Compose file still match the running container? Otherwise change NOTHING.
  filehash=$(cd "$dir" && $DOCKER compose "${fargs[@]}" config --hash "$svc" 2>/dev/null | awk '{print $2}')
  if [ -z "$filehash" ] || [ "$filehash" != "$runhash" ]; then
    echo "!! $name: Compose-Datei weicht vom laufenden Container ab – übersprungen (erst klären, dann pinnen)"; continue
  fi
  # find the file containing this service's image line (when several Compose files are used)
  for f in "${fl[@]}"; do grep -qE "^[[:space:]]*image:[[:space:]]*[\"']?${img%:latest}" "$f" && file=$f; done
  imgid=$($DOCKER inspect "$name" --format '{{.Image}}')
  digest=$($DOCKER image inspect "$imgid" --format '{{range .RepoDigests}}{{println .}}{{end}}' | head -1)
  ver=$($DOCKER image inspect "$imgid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)
  [ -z "$digest" ] && { echo "?? $name: kein Digest (lokal gebautes Image) – übersprungen"; continue; }
  [ -f "$file" ] || { echo "?? $name: Compose-Datei $file nicht gefunden – übersprungen"; continue; }
  base=${img%:latest}
  new="${base}@${digest#*@}"
  comment="# pinned $(date +%F)${ver:+, version $ver}"
  printf '%-22s %s\n%-22s -> %s  %s\n' "$name" "$img" "" "$new" "$comment"
  if [ $APPLY -eq 1 ]; then
    [ -f "$file.bak" ] || cp "$file" "$file.bak"
    # replace exactly the image line with this image (with or without :latest, with or without quotes)
    esc=${base//./[.]}   # escape dots; the sed delimiter is |, so / needs no escaping
    sed -i -E "s|^([[:space:]]*image:[[:space:]]*)[\"']?${esc}(:latest)?[\"']?[[:space:]]*(#.*)?$|\1${new}  ${comment}|" "$file"
    grep -q "$new" "$file" && echo "                       eingetragen in ${file#$HOME/}" || echo "!! nicht gefunden in $file – bitte von Hand"
    changed_dirs+=("$dir|$files|$svc")
  fi
done 3< <($DOCKER ps --format '{{.Names}}' | sort)

[ $APPLY -eq 0 ] && { echo; echo "Nur Vorschau. Mit --apply anwenden."; exit 0; }

echo; echo "Prüfen und nur die gepinnten Dienste neu erstellen (gleiches Image, kurzer Neustart):"
for entry in $(printf '%s\n' "${changed_dirs[@]}" | sort -u); do
  IFS='|' read -r dir files svc <<< "$entry"
  fargs=(); IFS=',' read -ra fl <<< "$files"; for f in "${fl[@]}"; do fargs+=(-f "$f"); done
  if (cd "$dir" && $DOCKER compose "${fargs[@]}" config -q); then
    # only this service, without dependencies; other services in the project stay untouched
    (cd "$dir" && $DOCKER compose "${fargs[@]}" up -d --no-build --no-deps "$svc" 2>&1 | grep -vE 'Running|up-to-date' || true)
    echo "  OK  ${dir#$HOME/} / $svc"
  else
    for f in "${fl[@]}"; do [ -f "$f.bak" ] && cp "$f.bak" "$f"; done
    echo "  !!  ${dir#$HOME/}: Compose-Datei ungültig – Sicherung zurückgespielt"
  fi
done
echo; echo "Fertig. Kontrolle: docker ps --format '{{.Names}} {{.Status}}' ; danach git diff und commit."
