#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Set up a GitHub Actions self-hosted runner as a LaunchAgent
# ==============================================================================
#
# WHY: A LaunchAgent runs inside the logged-in user's GUI session where
#      keychain operations (fastlane match, codesign) work properly.
#
# PREREQUISITES:
#   1. The GitHub Actions runner is already configured (config.sh has been run).
#   2. Auto-login MUST be enabled so a GUI session exists at boot.
#   3. Run this script from an SSH session (or Terminal) on the runner machine.
#
# WHAT IT DOES:
#   1. Validates auto-login and GUI session are available
#   2. Removes any existing LaunchDaemon (from a prior sudo svc.sh install)
#   3. Delegates to the runner's own svc.sh to install & start the LaunchAgent
#   4. Verifies the runner is running
#
# USAGE:
#   bash setup-runner-launchagent.sh [RUNNER_DIR]
#
# ==============================================================================

log()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\n\033[1;33mWARN:\033[0m $*"; }
die()  { echo -e "\n\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

RUNNER_DIR="${1:-${RUNNER_DIR:-$HOME/actions-runner}}"
[[ -d "${RUNNER_DIR}" ]] || die "Runner directory not found at ${RUNNER_DIR}.\n    Usage: bash $0 [/path/to/actions-runner]"

# --------------------------------------------------------------------------
# 1) Pre-flight checks
# --------------------------------------------------------------------------
CURRENT_USER="$(whoami)"

# Verify runner has been configured
for required_file in .runner .credentials svc.sh; do
  if [[ ! -f "${RUNNER_DIR}/${required_file}" ]]; then
    die "Missing ${RUNNER_DIR}/${required_file} — the runner has not been configured.\n    Run: cd ${RUNNER_DIR} && ./config.sh --url <repo-or-org-url> --token <token>"
  fi
done

# Enforce auto-login
CURRENT_AUTO_LOGIN="$(sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
if [[ "${CURRENT_AUTO_LOGIN}" != "${CURRENT_USER}" ]]; then
  die "Auto-login is NOT enabled for ${CURRENT_USER}.
  On a headless Mac, the LaunchAgent won't start after reboot without a GUI session.

  To fix: VNC into this Mac and enable auto-login in:
    System Settings > General > Login Items > Automatic login: ${CURRENT_USER}

  Then re-run this script."
fi
log "Auto-login is enabled for ${CURRENT_USER}"

# Verify GUI session exists
GUI_DOMAIN="gui/$(id -u)"
if ! launchctl print "${GUI_DOMAIN}" &>/dev/null; then
  die "No GUI session available (${GUI_DOMAIN} domain not found).\n    You must log in via VNC/Screen Sharing first, then re-run this script."
fi

# --------------------------------------------------------------------------
# 2) Fix ownership (in case runner was previously run as root/LaunchDaemon)
# --------------------------------------------------------------------------
log "Ensuring ${CURRENT_USER} owns ${RUNNER_DIR}..."
sudo chown -R "${CURRENT_USER}" "${RUNNER_DIR}"

# --------------------------------------------------------------------------
# 3) Remove any existing LaunchDaemon
# --------------------------------------------------------------------------
for f in /Library/LaunchDaemons/actions.runner.*.plist; do
  [[ -f "$f" ]] || continue
  if grep -q "${RUNNER_DIR}" "$f" 2>/dev/null; then
    DAEMON_LABEL="$(/usr/bin/plutil -extract Label raw "$f")"
    log "Removing existing LaunchDaemon: $f (label: ${DAEMON_LABEL})"
    sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
    sudo rm "$f"
  fi
done

# --------------------------------------------------------------------------
# 4) Uninstall any existing LaunchAgent (svc.sh handles this cleanly)
# --------------------------------------------------------------------------
cd "${RUNNER_DIR}"
log "Uninstalling any previous LaunchAgent..."
./svc.sh stop 2>/dev/null || true
./svc.sh uninstall 2>/dev/null || true

# --------------------------------------------------------------------------
# 5) Write .path and install/start via svc.sh
# --------------------------------------------------------------------------
# The runner reads .path (not shell profiles) to set its PATH at startup.
# Build the ideal PATH and write it so the runner can find rbenv Ruby, node, etc.
DESIRED_PATH="${HOME}/.rbenv/shims:${HOME}/.rbenv/bin:${HOME}/.nvm/versions/node/$(ls -1 "${HOME}/.nvm/versions/node/" 2>/dev/null | tail -1)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
log "Writing .path for runner service..."
echo "${DESIRED_PATH}" > "${RUNNER_DIR}/.path"
log "Runner PATH: $(cat "${RUNNER_DIR}/.path")"

log "Installing LaunchAgent via svc.sh..."
./svc.sh install

log "Starting runner..."
./svc.sh start

# --------------------------------------------------------------------------
# 6) Verify
# --------------------------------------------------------------------------
sleep 2
./svc.sh status

if pgrep -f "${RUNNER_DIR}/runsvc.sh" >/dev/null; then
  log "Runner is running (PID $(pgrep -f "${RUNNER_DIR}/runsvc.sh"))"
else
  warn "Runner process not detected — check status above."
fi

# --------------------------------------------------------------------------
# 7) Verify keychain operations work
# --------------------------------------------------------------------------
log "Testing keychain operations..."
TEST_KC="/tmp/test-runner-kc-$$-db"
if security create-keychain -p "" "${TEST_KC}" 2>/dev/null && \
   security default-keychain -s "${TEST_KC}" 2>/dev/null && \
   security list-keychains -s "${TEST_KC}" /Library/Keychains/System.keychain 2>/dev/null; then
  security delete-keychain "${TEST_KC}" 2>/dev/null
  log "Keychain operations OK"
else
  security delete-keychain "${TEST_KC}" 2>/dev/null || true
  warn "Keychain operations may not work. The runner might not have a proper security session."
fi

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
SVC_NAME="$(grep '^SVC_NAME=' "${RUNNER_DIR}/svc.sh" | head -1 | cut -d'"' -f2)"
log "Setup complete ✅"
cat <<EOF

Runner service configured as LaunchAgent.
  Runner dir: ${RUNNER_DIR}
  Service:    ${SVC_NAME:-unknown}

The runner will auto-start on boot as long as auto-login is enabled.
To check status:  cd ${RUNNER_DIR} && ./svc.sh status
To stop:          cd ${RUNNER_DIR} && ./svc.sh stop
To start:         cd ${RUNNER_DIR} && ./svc.sh start
To uninstall:     cd ${RUNNER_DIR} && ./svc.sh uninstall

EOF
