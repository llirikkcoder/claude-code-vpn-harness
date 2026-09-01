#!/bin/bash
# git-push-vpn.sh — fully automated `git push` through an OpenVPN CLI daemon.
#
# Behaviour:
#   1. If VPN_CHECK_HOST is already reachable — just `git push` (skip VPN).
#   2. Otherwise: start openvpn in background, wait for connectivity, push,
#      then kill openvpn (or keep it if KEEP_VPN=1).
#
# Usage:
#   ./git-push-vpn.sh                 # push current branch
#   ./git-push-vpn.sh origin main     # push a specific ref
#   KEEP_VPN=1 ./git-push-vpn.sh      # don't disconnect after push
#
# Config: see vpn-run.sh header — same env vars (VPN_CHECK_HOST, OVPN_CONFIG, ...).
# Setup (sudoers, .ovpn placement): see ../README.md.

set -e

VPN_CHECK_HOST="${VPN_CHECK_HOST:-}"
VPN_CHECK_PORT="${VPN_CHECK_PORT:-22}"

log()  { printf "\033[36m[git-push-vpn]\033[0m %s\n" "$*"; }

if [ -z "$VPN_CHECK_HOST" ]; then
  printf "\033[31m[git-push-vpn]\033[0m VPN_CHECK_HOST is not set — see README.md → Setup\n" >&2
  exit 1
fi

target_reachable() {
  nc -z -G 2 "$VPN_CHECK_HOST" "$VPN_CHECK_PORT" 2>/dev/null \
    || nc -z -w 2 "$VPN_CHECK_HOST" "$VPN_CHECK_PORT" 2>/dev/null
}

# Short-circuit: skip VPN entirely if there's nothing to push. Only safe for
# the bare `git push` (no args) form, where @{u} unambiguously names the
# comparison point — an explicit `git push origin some-branch` might target a
# branch with no local upstream, so we can't reliably diff it and always
# bring up VPN in that case.
if [ $# -eq 0 ]; then
  ahead=$(git rev-list @{u}..HEAD --count 2>/dev/null || echo "?")
  if [ "$ahead" = "0" ]; then
    log "Nothing to push (HEAD == @{u}). Skipping VPN."
    exit 0
  fi
  [ "$ahead" != "?" ] && log "$ahead commit(s) to push"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if target_reachable; then
  log "Target already reachable — pushing directly"
  git push "$@"
else
  "$SCRIPT_DIR/vpn-run.sh" git push "$@"
fi
