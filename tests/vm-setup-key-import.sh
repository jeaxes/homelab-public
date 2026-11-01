#!/usr/bin/env bash
# Exercise only the key-import branch with stubbed sudo; never changes the host.
set -euo pipefail
source_file="$(cd "$(dirname "$0")/.." && pwd)/scripts/vm-setup.sh"
import_block=$(sed -n '/^step "2 SSH/,/^install -d/p' "$source_file" | sed '$d')
[ -n "$import_block" ] || { echo 'key import branch missing'; exit 1; }
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
calls="$test_dir/calls"
step() { :; }
sudo() { printf '%s\n' "$*" >> "$calls"; }
ADMIN=test-admin
GH_USER=
eval "$import_block"
[ ! -e "$calls" ] || { echo 'unset GH_USER must not import any account keys'; exit 1; }
GH_USER=example-account
eval "$import_block"
[ "$(cat "$calls")" = '-u test-admin ssh-import-id gh:example-account' ] || {
  echo 'explicit account must be the only key source'; exit 1;
}
echo 'PASS: no implicit GitHub trust; explicit account imported'
