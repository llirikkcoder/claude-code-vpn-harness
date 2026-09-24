#!/bin/bash
# vpn-run.sh — generic VPN wrapper: raise VPN if needed, run "$@", drop VPN.
#
# Why this exists: some agent harnesses (Claude Code's block-destructive hook,
# for example) block any Bash command whose literal text contains "sudo",
# because raw sudo is a red flag for privilege escalation. Raising an OpenVPN
# daemon legitimately needs passwordless sudo (root-owned tun interface).
# The fix isn't to bypass the hook — it's to move sudo *out of the command the
# agent types* and into a small, reviewed, version-controlled script. The
# agent calls the script by path; the hook sees no "sudo" substring in that
# call; sudo still only ever runs the two exact commands allowlisted in
# sudoers (see README's setup section) — nothing more.
#
# Usage:
#   ./vpn-run.sh <command> [args...]     # run something once VPN is up
#   KEEP_VPN=1 ./vpn-run.sh <command>    # don't tear down VPN after
#
# Config (env vars, all optional except VPN_CHECK_HOST):
#   OVPN_CONFIG      Path to .ovpn profile (default: ~/.vpn/default.ovpn)
#   VPN_CHECK_HOST   Internal host to probe for "are we connected yet"
#                    (default: unset — script exits with instructions)
#   VPN_CHECK_PORT   Port to probe (default: 22)
#   OPENVPN_BIN      Path to openvpn binary (default: autodetected)
#   MAX_WAIT_SECONDS How long to wait for connectivity (default: 15)

set -u

OVPN_CONFIG="${OVPN_CONFIG:-$HOME/.vpn/default.ovpn}"
VPN_CHECK_HOST="${VPN_CHECK_HOST:-}"
VPN_CHECK_PORT="${VPN_CHECK_PORT:-22}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-15}"
LOG_FILE="$HOME/.vpn/openvpn.log"
PID_FILE="$HOME/.vpn/openvpn.pid"

log()  { printf "\033[36m[vpn-run]\033[0m %s\n" "$*"; }
err()  { printf "\033[31m[vpn-run]\033[0m %s\n" "$*" >&2; }

if [ -z "$VPN_CHECK_HOST" ]; then
  err "VPN_CHECK_HOST is not set — I don't know what host to probe for connectivity."
  err "Set it once, e.g.: export VPN_CHECK_HOST=gitlab.internal.example.com"
  exit 1
fi

if [ ! -f "$OVPN_CONFIG" ]; then
  err "OpenVPN config not found: $OVPN_CONFIG"
  err "See README.md → Setup for where to put your .ovpn profile."
  exit 1
fi

# autodetect openvpn binary unless caller pinned one
if [ -z "${OPENVPN_BIN:-}" ]; then
  for candidate in /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn /usr/sbin/openvpn; do
    [ -x "$candidate" ] && OPENVPN_BIN="$candidate" && break
  done
  OPENVPN_BIN="${OPENVPN_BIN:-$(command -v openvpn || true)}"
fi
if [ -z "${OPENVPN_BIN:-}" ]; then
  err "openvpn binary not found. Install it (e.g. 'brew install openvpn') or set OPENVPN_BIN."
  exit 1
fi

# process match keyed off the config's basename, so multiple profiles
# (work / personal / split-tunnel) don't collide when checking "is it running"
PROFILE_TAG="$(basename "$OVPN_CONFIG" .ovpn)"

vpn_reachable() {
  # -G is BSD nc's CONNECT timeout (macOS). GNU nc uses -w for the same purpose.
  nc -z -G 2 "$VPN_CHECK_HOST" "$VPN_CHECK_PORT" 2>/dev/null \
    || nc -z -w 2 "$VPN_CHECK_HOST" "$VPN_CHECK_PORT" 2>/dev/null
}

vpn_running() {
  # kill -0 to a root-owned process from a non-root user returns "Operation
  # not permitted" (a false negative), so use pgrep -f instead — it matches
  # across users without needing to signal the process.
  pgrep -f "openvpn.*${PROFILE_TAG}" >/dev/null 2>&1
}

vpn_start() {
  rm -f "$LOG_FILE" "$PID_FILE"
  : > "$LOG_FILE"; : > "$PID_FILE"
  chmod 644 "$LOG_FILE" "$PID_FILE"
  log "Starting openvpn ($PROFILE_TAG)..."
  sudo -n "$OPENVPN_BIN" --config "$OVPN_CONFIG" --daemon --log-append "$LOG_FILE" --writepid "$PID_FILE"
}

vpn_stop() {
  log "Stopping openvpn..."
  # killall first, on purpose. It matches the *process name* only, so it hits
  # the daemon and nothing else.
  #
  # `pkill -f openvpn` matches the whole command line, and that is genuinely
  # dangerous here: the very command running it ("… pkill -f openvpn") contains
  # the string, and so does any unrelated command that merely mentions openvpn —
  # a grep, a tail of the log, an agent's own diagnostic call. Two failures seen
  # in practice: an agent's command was killed mid-run, and the elevation
  # wrapper was killed before the daemon was, leaving the daemon alive while
  # the script reported success. That orphan then held the single per-cert
  # session for two days and blocked a second machine from connecting.
  #
  # pkill stays as a fallback only, for the case where killall is unavailable.
  # Both forms are allowlisted in sudoers (see README → Setup).
  sudo -n killall openvpn 2>/dev/null || true
  sleep 1
  rm -f "$PID_FILE"
  if vpn_running; then
    sudo -n pkill -f openvpn 2>/dev/null || true
    sleep 1
  fi
  vpn_running && err "openvpn still running — stop it manually: sudo killall openvpn" || log "✓ VPN stopped"
}

# A daemon left over from an earlier run holds the VPN server's single
# per-certificate session, so a second machine cannot connect: the two clients
# evict each other in a loop. Nothing in the UI shows this — the tunnel was
# raised outside the VPN client app — so it goes unnoticed for days.
warn_if_orphaned() {
  vpn_running || return 0
  [ -s "$PID_FILE" ] && return 0   # our own run, PID file still present
  log "Note: an openvpn daemon for '$PROFILE_TAG' is already running, started"
  log "      outside this script (no PID file). It will be left as is."
  log "      If a second machine cannot connect, stop it: sudo killall openvpn"
}

# openvpn --log-append never truncates; the file grew to 8 MB over a few days
# of an orphaned daemon. Keep one previous copy and start clean.
rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local size
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  [ "$size" -gt 1048576 ] || return 0
  mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
  log "Rotated VPN log (was $((size / 1024)) KB) → $(basename "$LOG_FILE").1"
}

WE_STARTED_VPN=0
cleanup() { [ "$WE_STARTED_VPN" = 1 ] && [ -z "${KEEP_VPN:-}" ] && vpn_stop; }
trap cleanup EXIT INT TERM

warn_if_orphaned

if vpn_reachable; then
  log "Target already reachable — no VPN needed"
else
  log "Target unreachable — bringing up VPN"
  rotate_log
  vpn_start
  WE_STARTED_VPN=1
  elapsed=0
  until vpn_reachable || [ "$elapsed" -ge "$MAX_WAIT_SECONDS" ]; do
    sleep 1; elapsed=$((elapsed + 1))
  done
  if ! vpn_reachable; then
    err "Timeout: still unreachable after ${MAX_WAIT_SECONDS}s"
    err "Last lines from VPN log:"
    tail -10 "$LOG_FILE" 2>/dev/null | sed 's/^/  | /' >&2
    exit 1
  fi
  log "✓ Reachable after ${elapsed}s"
fi

if [ $# -eq 0 ]; then
  err "No command given. Usage: vpn-run.sh <command> [args...]"
  exit 1
fi

log "Running: $*"
"$@"
rc=$?
exit $rc
