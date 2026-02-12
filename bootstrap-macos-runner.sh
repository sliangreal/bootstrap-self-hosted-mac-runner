#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# REQUIRED VERSIONS (FAIL IF NOT EXACT)
# ==================================================
REQUIRED_XCODE_VERSION="16.4"
REQUIRED_NODE_VERSION="22.12.0"
REQUIRED_RUBY_VERSION="3.1.2"
REQUIRED_COCOAPODS_VERSION="1.16.2"
NVM_VERSION="v0.40.4"

# Simulator pinning
REQUIRED_IOS_SIM_RUNTIME_NAME="iOS 18.6"
REQUIRED_SIM_DEVICE_TYPE="iPhone 16 Pro"
CI_SIM_NAME="CI iPhone 16 Pro (18.6)"
# Optional escape hatch if runtime install isn't supported automatically:
# Provide a local path to a downloaded runtime DMG
# Example: export IOS_RUNTIME_DMG_PATH="/path/to/iOS_18.6_Simulator_Runtime.dmg"
IOS_RUNTIME_DMG_PATH="${IOS_RUNTIME_DMG_PATH:-}"

# ==================================================
# Helpers
# ==================================================
log() { echo -e "\n\033[1;34m==>\033[0m $*"; }
die() { echo -e "\n\033[1;31mERROR:\033[0m $*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ==================================================
# 1) Homebrew (official installer)
# ==================================================
log "Ensuring Homebrew is installed..."

# Ensure brew is on PATH (Apple Silicon + Intel)
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

if ! command_exists brew; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Set up PATH after fresh install
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  else
    die "Homebrew installed but brew not found on PATH"
  fi
fi

brew update

# ==================================================
# Xcode install (skip xcodes if already present)
# ==================================================
log "Ensuring Xcode ${REQUIRED_XCODE_VERSION} is installed..."

XCODE_ALREADY_INSTALLED=false
if command_exists xcodebuild; then
  CURRENT_XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -n1 | awk '{print $2}' || true)"
  if [[ "${CURRENT_XCODE_VERSION}" == "${REQUIRED_XCODE_VERSION}" ]]; then
    log "Xcode ${REQUIRED_XCODE_VERSION} is already installed — skipping xcodes"
    XCODE_ALREADY_INSTALLED=true
  fi
fi

if [[ "${XCODE_ALREADY_INSTALLED}" == false ]]; then
  # xcodes README: you can provide Apple ID creds via XCODES_USERNAME / XCODES_PASSWORD
  if [[ -z "${XCODE_APPLE_ID:-}" || -z "${XCODE_APPLE_ID_PASSWORD:-}" ]]; then
    die "Xcode install requires XCODE_APPLE_ID and XCODE_APPLE_ID_PASSWORD env vars"
  fi
  export XCODES_USERNAME="${XCODE_APPLE_ID}"
  export XCODES_PASSWORD="${XCODE_APPLE_ID_PASSWORD}"

  # Install xcodes if missing (use pre-built binary — brew formula requires
  # Xcode to compile from source, which defeats the purpose)
  if ! command_exists xcodes; then
    log "Installing xcodes (pre-built binary)..."
    curl -sL "https://github.com/XcodesOrg/xcodes/releases/latest/download/xcodes.zip" -o /tmp/xcodes.zip
    unzip -o /tmp/xcodes.zip -d /tmp
    install -m 755 /tmp/xcodes "$(brew --prefix)/bin/xcodes"
    rm -f /tmp/xcodes.zip /tmp/xcodes
  fi

  if ! xcodes installed | grep -q "^${REQUIRED_XCODE_VERSION}\b"; then
    log "Downloading and installing Xcode ${REQUIRED_XCODE_VERSION}..."
    xcodes install "${REQUIRED_XCODE_VERSION}" --select
  else
    log "Xcode ${REQUIRED_XCODE_VERSION} already installed"
    xcodes select "${REQUIRED_XCODE_VERSION}"
  fi
fi

# Accept license (required for xcodebuild, CocoaPods, etc.)
sudo xcodebuild -license accept

# ==================================================
# Validate Xcode version (FAIL FAST)
# ==================================================
ACTUAL_XCODE_VERSION="$(xcodebuild -version | head -n1 | awk '{print $2}')"
[[ "${ACTUAL_XCODE_VERSION}" == "${REQUIRED_XCODE_VERSION}" ]] \
  || die "Xcode version mismatch: expected ${REQUIRED_XCODE_VERSION}, got ${ACTUAL_XCODE_VERSION}"
log "Xcode OK: ${ACTUAL_XCODE_VERSION}"

# ==================================================
# Simulator runtime + device (iPhone 16 Pro / iOS 18.6)
# ==================================================
log "Ensuring simulator runtime '${REQUIRED_IOS_SIM_RUNTIME_NAME}' and device '${CI_SIM_NAME}' exist..."

# Ensure the device type exists in this Xcode
if ! xcrun simctl list devicetypes | grep -Fq "${REQUIRED_SIM_DEVICE_TYPE}"; then
  die "Simulator device type '${REQUIRED_SIM_DEVICE_TYPE}' not found in this Xcode. Check Xcode version/components."
fi

get_runtime_id() {
  xcrun simctl list runtimes \
    | grep -F "${REQUIRED_IOS_SIM_RUNTIME_NAME}" \
    | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9.\-]+' \
    | head -n1 || true
}

runtime_identifier="$(get_runtime_id)"

if [[ -z "${runtime_identifier}" ]]; then
  log "Runtime '${REQUIRED_IOS_SIM_RUNTIME_NAME}' not installed yet."

  # First try: xcodes runtimes install (only if xcodes is available)
  if command_exists xcodes; then
    log "Attempting to install runtime via xcodes..."
    set +e
    xcodes runtimes install "${REQUIRED_IOS_SIM_RUNTIME_NAME}"
    rc=$?
    set -e

    runtime_identifier="$(get_runtime_id)"
  fi

  if [[ -z "${runtime_identifier}" ]]; then
    if [[ -n "${IOS_RUNTIME_DMG_PATH}" ]]; then
      log "Trying simctl runtime add from DMG: ${IOS_RUNTIME_DMG_PATH}"
      [[ -f "${IOS_RUNTIME_DMG_PATH}" ]] || die "IOS_RUNTIME_DMG_PATH does not exist: ${IOS_RUNTIME_DMG_PATH}"
      xcrun simctl runtime add "${IOS_RUNTIME_DMG_PATH}"

      runtime_identifier="$(get_runtime_id)"
    fi
  fi

  [[ -n "${runtime_identifier}" ]] || die "Unable to install/find runtime '${REQUIRED_IOS_SIM_RUNTIME_NAME}'. Install it in Xcode > Settings > Platforms, or provide IOS_RUNTIME_DMG_PATH to a runtime DMG."
fi

log "Runtime OK: ${runtime_identifier}"

# Boot the default simulator once to warm it up
set +eo pipefail
default_udid="$(xcrun simctl list devices \
  | grep "${REQUIRED_SIM_DEVICE_TYPE}" \
  | grep -oE '[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}' \
  | head -n1)"
set -eo pipefail

if [[ -n "${default_udid}" ]]; then
  log "Warming up default simulator: ${REQUIRED_SIM_DEVICE_TYPE} (${default_udid})..."
  xcrun simctl boot "${default_udid}" || true
  xcrun simctl bootstatus "${default_udid}" -b
  xcrun simctl shutdown "${default_udid}" || true
  log "Simulator ready: ${default_udid}"
else
  log "Warning: No ${REQUIRED_SIM_DEVICE_TYPE} simulator found for ${REQUIRED_IOS_SIM_RUNTIME_NAME}"
fi

# ==================================================
# 2) NVM + Node.js (official installer)
# ==================================================
log "Ensuring NVM and Node ${REQUIRED_NODE_VERSION}..."

if [[ ! -d "$HOME/.nvm" ]]; then
  log "Installing NVM (${NVM_VERSION})..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
source "$NVM_DIR/nvm.sh"

ACTUAL_NODE_VERSION="$(node -v 2>/dev/null | sed 's/^v//' || true)"
if [[ "${ACTUAL_NODE_VERSION}" == "${REQUIRED_NODE_VERSION}" ]]; then
  log "Node already at ${REQUIRED_NODE_VERSION} — skipping"
else
  log "Installing Node ${REQUIRED_NODE_VERSION}..."
  nvm install "${REQUIRED_NODE_VERSION}"
  nvm alias default "${REQUIRED_NODE_VERSION}"
  nvm use "${REQUIRED_NODE_VERSION}"

  ACTUAL_NODE_VERSION="$(node -v | sed 's/^v//')"
  [[ "${ACTUAL_NODE_VERSION}" == "${REQUIRED_NODE_VERSION}" ]] \
    || die "Node version mismatch: expected ${REQUIRED_NODE_VERSION}, got ${ACTUAL_NODE_VERSION}"
fi
log "Node OK: ${ACTUAL_NODE_VERSION}"

# ==================================================
# 3) applesimutils (MUST be before Ruby)
# ==================================================
log "Ensuring applesimutils..."
if command_exists applesimutils; then
  log "applesimutils already installed — skipping"
else
  brew tap wix/brew
  brew install applesimutils
  command_exists applesimutils || die "applesimutils installation failed"
fi
log "applesimutils OK"

# ==================================================
# 4) Ruby via rbenv
# ==================================================
log "Ensuring rbenv and Ruby ${REQUIRED_RUBY_VERSION}..."

if ! command_exists rbenv; then
  log "Installing rbenv and ruby-build..."
  brew install rbenv ruby-build openssl@1.1 || true
else
  log "rbenv already installed — skipping brew install"
fi

export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"
rbenv rehash 2>/dev/null || true

if ! rbenv versions --bare | grep -Fxq "${REQUIRED_RUBY_VERSION}"; then
  log "Installing Ruby ${REQUIRED_RUBY_VERSION} (this may take a while)..."
  OPENSSL_DIR="$(brew --prefix openssl@1.1)"
  RUBY_CONFIGURE_OPTS="--with-openssl-dir=${OPENSSL_DIR} --disable-shared" \
    rbenv install "${REQUIRED_RUBY_VERSION}"
else
  log "Ruby ${REQUIRED_RUBY_VERSION} already installed via rbenv — skipping build"
fi

rbenv global "${REQUIRED_RUBY_VERSION}"
rbenv rehash

# Ensure rbenv is available in future zsh sessions (GitHub Actions runner shell)
RBENV_PATH_LINE='export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"'
RBENV_INIT='eval "$(rbenv init - zsh)"'
for rcfile in "$HOME/.zshrc" "$HOME/.zprofile"; do
  if ! grep -Fq '.rbenv' "${rcfile}" 2>/dev/null; then
    echo "${RBENV_PATH_LINE}" >> "${rcfile}"
    echo "${RBENV_INIT}" >> "${rcfile}"
    log "Added rbenv PATH and init to ${rcfile}"
  fi
done

# Validate rbenv shims are active and correct version is running
if [[ "$(command -v ruby)" != "$HOME/.rbenv/shims/ruby" ]]; then
  die "rbenv is not active: ruby resolves to '$(command -v ruby)'"
fi

ACTUAL_RUBY_VERSION="$(ruby -v | awk '{print $2}')"
[[ "${ACTUAL_RUBY_VERSION}" == "${REQUIRED_RUBY_VERSION}"* ]] \
  || die "Ruby runtime mismatch: expected ${REQUIRED_RUBY_VERSION}, got ${ACTUAL_RUBY_VERSION}"
log "Ruby OK: ${ACTUAL_RUBY_VERSION}"

# ==================================================
# 5) CocoaPods (exact version)
# ==================================================
log "Ensuring CocoaPods ${REQUIRED_COCOAPODS_VERSION}..."

ACTUAL_COCOAPODS_VERSION="$(pod --version 2>/dev/null || true)"
if [[ "${ACTUAL_COCOAPODS_VERSION}" == "${REQUIRED_COCOAPODS_VERSION}" ]]; then
  log "CocoaPods already at ${REQUIRED_COCOAPODS_VERSION} — skipping"
else
  log "Installing CocoaPods ${REQUIRED_COCOAPODS_VERSION}..."
  gem install bundler --no-document || true
  gem install cocoapods -v "${REQUIRED_COCOAPODS_VERSION}" --no-document
  rbenv rehash

  ACTUAL_COCOAPODS_VERSION="$(pod --version)"
  [[ "${ACTUAL_COCOAPODS_VERSION}" == "${REQUIRED_COCOAPODS_VERSION}" ]] \
    || die "CocoaPods version mismatch: expected ${REQUIRED_COCOAPODS_VERSION}, got ${ACTUAL_COCOAPODS_VERSION}"
fi
log "CocoaPods OK: ${ACTUAL_COCOAPODS_VERSION}"

# ==================================================
# 6) Summary
# ==================================================
log "Bootstrap complete ✅"
cat <<EOF

Locked versions:
- Xcode         : ${ACTUAL_XCODE_VERSION}
- Node          : ${ACTUAL_NODE_VERSION}
- Ruby          : ${ACTUAL_RUBY_VERSION}
- CocoaPods     : ${ACTUAL_COCOAPODS_VERSION}
- applesimutils : $(applesimutils --version 2>/dev/null || echo "installed")
- Simulator     : ${REQUIRED_SIM_DEVICE_TYPE} (${default_udid:-none})
- Runtime       : ${REQUIRED_IOS_SIM_RUNTIME_NAME} (${runtime_identifier})

To use the installed tools in your current shell, run:
  source ~/.zshrc
Or open a new terminal session.

EOF