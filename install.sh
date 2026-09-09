#!/usr/bin/env bash
# Put the launcher on PATH and the app in the desktop's launcher. Everything
# else stays in this checkout, so updating is `git pull` — there is no shell to
# restart and no plugin to reload.
set -euo pipefail

app_dir=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
bin_dir=${XDG_BIN_HOME:-$HOME/.local/bin}
apps_dir=${XDG_DATA_HOME:-$HOME/.local/share}/applications

mkdir -p -- "$bin_dir" "$apps_dir"
ln -sfn -- "$app_dir/bin/subspace-communicator" "$bin_dir/subspace-communicator"
sed "s|@BIN@|$bin_dir/subspace-communicator|" \
  "$app_dir/subspace-communicator.desktop.in" > "$apps_dir/subspace-communicator.desktop"
update-desktop-database "$apps_dir" >/dev/null 2>&1 || true

printf 'Installed.\n'
printf '  launcher entry: %s\n' "$apps_dir/subspace-communicator.desktop"
printf '  command:        %s\n' "$bin_dir/subspace-communicator"
