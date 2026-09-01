#!/bin/bash
# git-fetch-vpn.sh — `git fetch` through an OpenVPN CLI daemon, raised on demand.
#
# Thin wrapper over vpn-run.sh: `git fetch` is cheap, so unlike the push
# variant there's no "nothing to do" short-circuit — always try direct first,
# fall back to VPN if unreachable.
#
# Usage:
#   ./git-fetch-vpn.sh                        # fetch default remote
#   ./git-fetch-vpn.sh --tags --force origin  # any git-fetch args pass through
#
# Config: see vpn-run.sh header (VPN_CHECK_HOST, OVPN_CONFIG, ...).

set -e

VPN_CHECK_HOST="${VPN_CHECK_HOST:-}"
VPN_CHECK_PORT="${VPN_CHECK_PORT:-22}"

if [ -z "$VPN_CHECK_HOST" ]; then
  printf "\033[31m[git-fetch-vpn]\033[0m VPN_CHECK_HOST is not set — see README.md → Setup\n" >&2
  exit 1
fi

target_reachable() {
  nc -z -G 2 "$VPN_CHECK_HOST" "$VPN_CHECK_PORT" 2>/dev/null \
    || nc -z -w 2 "$VPN_CHECK_HOST" "$VPN_CHECK_PORT" 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if target_reachable; then
  printf "\033[36m[git-fetch-vpn]\033[0m Target already reachable — fetching directly\n"
  git fetch "$@"
else
  "$SCRIPT_DIR/vpn-run.sh" git fetch "$@"
fi
