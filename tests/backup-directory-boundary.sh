#!/usr/bin/env bash
# Test the actual backup path gate in an isolated directory, without Docker/root.
set -euo pipefail
source_file="$(cd "$(dirname "$0")/.." && pwd)/scripts/homeserver-backup.sh"
gate=$(sed -n '/^ensure_root_directory() {/,/^}/p' "$source_file")
[ -n "$gate" ] || { echo 'backup gate missing'; exit 1; }
eval "$gate"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/safe" "$test_dir/writable" "$test_dir/user-owned"
chmod 755 "$test_dir/safe" "$test_dir/user-owned"
chmod 777 "$test_dir/writable"
ln -s "$test_dir/safe" "$test_dir/link"
# Model root ownership for the safe fixture. All permissions and symlink
# checks use real filesystem metadata. user-owned explicitly returns uid 1000.
stat() {
  if [ "$1" = -c ] && [ "$2" = %u ]; then
    if [ "$3" = "$test_dir/user-owned" ]; then echo 1000; else echo 0; fi
  else command stat "$@"; fi
}
ensure_root_directory "$test_dir/safe"
for unsafe in writable user-owned link; do
  if (ensure_root_directory "$test_dir/$unsafe"); then
    echo "FAIL: accepted $unsafe parent"; exit 1
  fi
done
echo 'PASS: symlink, user-owned and writable parents rejected'
