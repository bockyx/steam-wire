#!/usr/bin/env bash
# Install (or --uninstall) steam-game-audio and remove legacy steam-wire files.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
script_dir="${XDG_DATA_HOME:-$HOME/.local/share}/wireplumber/scripts"

legacy=("$conf_dir/90-steam-wire.conf" "$script_dir/steam-wire.lua")
current=("$conf_dir/90-steam-game-audio.conf" "$script_dir/steam-game-audio.lua")

remove() {
  for f in "$@"; do
    if [[ -e $f || -L $f ]]; then rm -v -- "$f"; fi
  done
}

restart() {
  # `restart` also starts the unit if it was stopped.
  if systemctl --user restart wireplumber.service; then
    echo "WirePlumber (re)started."
  else
    echo "Could not start wireplumber.service; start it or log out/in to apply." >&2
  fi
}

case "${1:-}" in
  --uninstall)
    remove "${legacy[@]}" "${current[@]}"
    restart
    ;;
  "")
    remove "${legacy[@]}"
    mkdir -p "$conf_dir" "$script_dir"
    install -v -m 644 "$src/90-steam-game-audio.conf" "$conf_dir/"
    install -v -m 644 "$src/steam-game-audio.lua" "$script_dir/"
    restart
    ;;
  *)
    echo "Usage: $0 [--uninstall]" >&2
    exit 1
    ;;
esac
