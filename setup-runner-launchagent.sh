#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Convert a GitHub Actions self-hosted runner from LaunchDaemon to LaunchAgent
# ==============================================================================
#
# WHY: A LaunchDaemon runs outside any GUI session.  macOS only exposes user
#      keychains in the effective search list inside a GUI session, so fastlane's
#      setup_ci / match / codesign all fail silently on a LaunchDaemon runner.
#
#      A LaunchAgent runs inside the logged-in user's GUI session where keychain
#      operations work normally.
#
# PREREQUISITES:
#   1. The GitHub Actions runner is already configured (config.sh has been run).
#   2. Auto-login MUST be enabled via System Settings so a GUI session exists at
#      boot.  On a headless Mac (e.g. MacStadium), VNC/Screen Sharing into the
#      machine and enable:
#        System Settings > General > Login Items > Automatic login: <your user>
#      This script will remind you if auto-login is not detected.
#   3. Run this script from an SSH session (or Terminal) on the runner machine.
#
# WHAT IT DOES:
#   1. Detects the runner's existing LaunchDaemon plist (if any)
#   2. Converts it to a LaunchAgent, OR creates a fresh LaunchAgent plist
#      (removes UserName, adds SessionCreate and ProcessType keys)
#   3. Loads the LaunchAgent in the gui/<uid> domain
#
# USAGE:
#   bash setup-runner-launchagent.sh
#
# ==============================================================================

log()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\n\033[1;33mWARN:\033[0m $*"; }
die()  { echo -e "\n\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
[[ -d "${RUNNER_DIR}" ]] || die "Runner directory not found at ${RUNNER_DIR}. Set RUNNER_DIR if it's elsewhere."

# --------------------------------------------------------------------------
# 1) Find the runner's LaunchDaemon plist
# --------------------------------------------------------------------------
log "Looking for existing runner LaunchDaemon..."

DAEMON_PLIST=""
for f in /Library/LaunchDaemons/actions.runner.*.plist; do
  [[ -f "$f" ]] || continue
  # Match plists whose ProgramArguments reference this runner directory
  if grep -q "${RUNNER_DIR}/runsvc.sh" "$f" 2>/dev/null; then
    DAEMON_PLIST="$f"
    break
  fi
done

# Extract the label from the plist (used for launchctl commands and naming)
if [[ -n "${DAEMON_PLIST}" ]]; then
  RUNNER_LABEL="$(/usr/bin/plutil -extract Label raw "${DAEMON_PLIST}")"
  log "Found LaunchDaemon: ${DAEMON_PLIST} (label: ${RUNNER_LABEL})"
else
  # No daemon — check if a LaunchAgent already exists
  for f in "$HOME/Library/LaunchAgents"/actions.runner.*.plist; do
    [[ -f "$f" ]] || continue
    if grep -q "${RUNNER_DIR}/runsvc.sh" "$f" 2>/dev/null; then
      RUNNER_LABEL="$(/usr/bin/plutil -extract Label raw "$f")"
      log "LaunchAgent already exists at $f (label: ${RUNNER_LABEL})"
      log "Skipping conversion — will ensure it's loaded."
      AGENT_PLIST="$f"
      break
    fi
  done
  if [[ -z "${AGENT_PLIST:-}" ]]; then
    log "No existing LaunchDaemon or LaunchAgent found — will create a fresh plist."
  fi
fi

# --------------------------------------------------------------------------
# 2) Create or convert the LaunchAgent plist
# --------------------------------------------------------------------------
if [[ -n "${DAEMON_PLIST}" ]]; then
  # --- Convert existing LaunchDaemon → LaunchAgent ---
  RUNNER_LABEL="$(/usr/bin/plutil -extract Label raw "${DAEMON_PLIST}")"
  AGENT_PLIST="${AGENT_PLIST:-$HOME/Library/LaunchAgents/${RUNNER_LABEL}.plist}"

  log "Stopping LaunchDaemon..."
  sudo launchctl bootout "system/${RUNNER_LABEL}" 2>/dev/null || true
  sleep 2

  log "Creating LaunchAgent at ${AGENT_PLIST}..."
  mkdir -p "$HOME/Library/LaunchAgents"
  sudo cp "${DAEMON_PLIST}" "${AGENT_PLIST}"
  sudo chown "$(whoami)" "${AGENT_PLIST}"

  # Remove UserName (not valid for LaunchAgents)
  /usr/bin/plutil -remove UserName "${AGENT_PLIST}" 2>/dev/null || true

  # Add SessionCreate and ProcessType for a proper security session
  /usr/bin/plutil -replace SessionCreate -bool true "${AGENT_PLIST}" 2>/dev/null || true
  /usr/bin/plutil -replace ProcessType -string "Interactive" "${AGENT_PLIST}" 2>/dev/null || true

  # Remove the old LaunchDaemon
  sudo rm "${DAEMON_PLIST}"
  log "Removed LaunchDaemon: ${DAEMON_PLIST}"

elif [[ -z "${AGENT_PLIST:-}" ]]; then
  # --- Create a fresh LaunchAgent plist ---
  # Derive the label from the runner's .runner config if available
  if [[ -f "${RUNNER_DIR}/.runner" ]]; then
    RUNNER_NAME="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['agentName'])" "${RUNNER_DIR}/.runner" 2>/dev/null || echo "self-hosted-runner")"
  else
    RUNNER_NAME="mac-m4-runner"
  fi
  RUNNER_LABEL="actions.runner.${RUNNER_NAME}"
  AGENT_PLIST="$HOME/Library/LaunchAgents/${RUNNER_LABEL}.plist"
  LOG_DIR="$HOME/Library/Logs/${RUNNER_LABEL}"

  log "Creating fresh LaunchAgent plist at ${AGENT_PLIST}..."
  mkdir -p "$HOME/Library/LaunchAgents"
  mkdir -p "${LOG_DIR}"

  cat > "${AGENT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${RUNNER_LABEL}</string>
  <key>WorkingDirectory</key>
  <string>${RUNNER_DIR}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUNNER_DIR}/runsvc.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>SessionCreate</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ACTIONS_RUNNER_SVC</key>
    <string>1</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST

  log "Created LaunchAgent: ${AGENT_PLIST}"
else
  RUNNER_LABEL="$(/usr/bin/plutil -extract Label raw "${AGENT_PLIST}")"
fi

# --------------------------------------------------------------------------
# 3) Check auto-login
# --------------------------------------------------------------------------
CURRENT_AUTO_LOGIN="$(sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
CURRENT_USER="$(whoami)"

if [[ "${CURRENT_AUTO_LOGIN}" != "${CURRENT_USER}" ]]; then
  warn "Auto-login is NOT enabled for ${CURRENT_USER}."
  warn "On a headless Mac, the LaunchAgent won't start after reboot without a GUI session."
  warn ""
  warn "To fix: VNC into this Mac and enable auto-login in:"
  warn "  System Settings > General > Login Items > Automatic login: ${CURRENT_USER}"
  warn ""
  warn "Continuing anyway (the agent can still be loaded manually)..."
else
  log "Auto-login is enabled for ${CURRENT_USER}"
fi

# --------------------------------------------------------------------------
# 4) Load the LaunchAgent
# --------------------------------------------------------------------------
GUI_DOMAIN="gui/$(id -u)"

if ! launchctl print "${GUI_DOMAIN}" &>/dev/null; then
  die "No GUI session available (${GUI_DOMAIN} domain not found).\n    You must log in via VNC/Screen Sharing first, then re-run this script."
fi

# Unload any previous instance
launchctl bootout "${GUI_DOMAIN}/${RUNNER_LABEL}" 2>/dev/null || true
kill "$(pgrep -f "${RUNNER_DIR}/runsvc.sh")" 2>/dev/null || true
sleep 1

log "Loading LaunchAgent in ${GUI_DOMAIN}..."
launchctl bootstrap "${GUI_DOMAIN}" "${AGENT_PLIST}"

sleep 2
if pgrep -f "${RUNNER_DIR}/runsvc.sh" >/dev/null; then
  log "Runner is running (PID $(pgrep -f "${RUNNER_DIR}/runsvc.sh"))"
else
  die "Runner failed to start. Check logs:\n    tail ~/Library/Logs/${RUNNER_LABEL}/*.log"
fi

# --------------------------------------------------------------------------
# 5) Verify keychain operations work
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
log "Setup complete ✅"
cat <<EOF

Runner service configured as LaunchAgent:
  Plist : ${AGENT_PLIST}
  Label : ${RUNNER_LABEL}
  Domain: ${GUI_DOMAIN}

The runner will auto-start on boot as long as auto-login is enabled.
To check status:  launchctl print ${GUI_DOMAIN}/${RUNNER_LABEL}
To stop:          launchctl bootout ${GUI_DOMAIN}/${RUNNER_LABEL}
To start:         launchctl bootstrap ${GUI_DOMAIN} ${AGENT_PLIST}

EOF
