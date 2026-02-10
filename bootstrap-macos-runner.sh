#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# REQUIRED VERSIONS (FAIL IF NOT EXACT)
# ==================================================
REQUIRED_NODE_VERSION="22.12.0"
REQUIRED_RUBY_VERSION="3.1.2"
REQUIRED_COCOAPODS_VERSION="1.16.2"
NVM_VERSION="v0.40.4"

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
if ! command_exists brew; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Ensure brew is on PATH (Apple Silicon + Intel)
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
else
  die "Homebrew installed but brew not found on PATH"
fi

brew update

# ==================================================
# Xcode install (non-interactive via xcodes)
# ==================================================
REQUIRED_XCODE_VERSION="16.4"

log "Ensuring Xcode ${REQUIRED_XCODE_VERSION} is installed..."

if [[ -z "${XCODE_APPLE_ID:-}" || -z "${XCODE_APPLE_ID_PASSWORD:-}" ]]; then
  die "Xcode install requires XCODE_APPLE_ID and XCODE_APPLE_ID_PASSWORD env vars"
fi

# Install xcodes if missing
if ! command -v xcodes >/dev/null 2>&1; then
  log "Installing xcodes..."
  brew install xcodes
fi

# Authenticate (non-interactive)
log "Authenticating with Apple Developer account..."
xcodes auth login \
  --apple-id "${XCODE_APPLE_ID}" \
  --password "${XCODE_APPLE_ID_PASSWORD}" \
  --non-interactive

# Install Xcode if missing
if ! xcodes installed | grep -q "^${REQUIRED_XCODE_VERSION}\b"; then
  log "Downloading and installing Xcode ${REQUIRED_XCODE_VERSION}..."
  xcodes install "${REQUIRED_XCODE_VERSION}" --select
else
  log "Xcode ${REQUIRED_XCODE_VERSION} already installed"
  xcodes select "${REQUIRED_XCODE_VERSION}"
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
# 2) NVM + Node.js (official installer)
# ==================================================
log "Installing NVM (${NVM_VERSION})..."
if [[ ! -d "$HOME/.nvm" ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
source "$NVM_DIR/nvm.sh"

log "Installing Node ${REQUIRED_NODE_VERSION}..."
nvm install "${REQUIRED_NODE_VERSION}"
nvm alias default "${REQUIRED_NODE_VERSION}"
nvm use "${REQUIRED_NODE_VERSION}"

ACTUAL_NODE_VERSION="$(node -v | sed 's/^v//')"
[[ "${ACTUAL_NODE_VERSION}" == "${REQUIRED_NODE_VERSION}" ]] \
  || die "Node version mismatch: expected ${REQUIRED_NODE_VERSION}, got ${ACTUAL_NODE_VERSION}"

log "Node OK: ${ACTUAL_NODE_VERSION}"

# ==================================================
# 3) applesimutils (MUST be before Ruby)
# ==================================================
log "Installing applesimutils..."
brew tap wix/brew
brew install applesimutils

if ! command_exists applesimutils; then
  die "applesimutils installation failed"
fi

log "applesimutils OK"

# ==================================================
# 4) Ruby via rbenv
# ==================================================
log "Installing rbenv and ruby-build..."
brew install rbenv ruby-build openssl@1.1 || true

export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"

if ! rbenv versions --bare | grep -Fxq "${REQUIRED_RUBY_VERSION}"; then
  OPENSSL_DIR="$(brew --prefix openssl@1.1)"
  RUBY_CONFIGURE_OPTS="--with-openssl-dir=${OPENSSL_DIR}" \
    rbenv install "${REQUIRED_RUBY_VERSION}"
fi

rbenv global "${REQUIRED_RUBY_VERSION}"
rbenv rehash

ACTUAL_RUBY_VERSION="$(ruby -v | awk '{print $2}')"
[[ "${ACTUAL_RUBY_VERSION}" == "${REQUIRED_RUBY_VERSION}" ]] \
  || die "Ruby version mismatch: expected ${REQUIRED_RUBY_VERSION}, got ${ACTUAL_RUBY_VERSION}"

log "Ruby OK: ${ACTUAL_RUBY_VERSION}"

# ==================================================
# 5) CocoaPods (exact version)
# ==================================================
log "Installing CocoaPods ${REQUIRED_COCOAPODS_VERSION}..."
gem install bundler --no-document || true
gem install cocoapods -v "${REQUIRED_COCOAPODS_VERSION}" --no-document
rbenv rehash

ACTUAL_COCOAPODS_VERSION="$(pod --version)"
[[ "${ACTUAL_COCOAPODS_VERSION}" == "${REQUIRED_COCOAPODS_VERSION}" ]] \
  || die "CocoaPods version mismatch: expected ${REQUIRED_COCOAPODS_VERSION}, got ${ACTUAL_COCOAPODS_VERSION}"

log "CocoaPods OK: ${ACTUAL_COCOAPODS_VERSION}"

# ==================================================
# 6) Summary
# ==================================================
log "Bootstrap complete ✅"

cat <<EOF

Locked versions:
- Node       : ${ACTUAL_NODE_VERSION}
- Ruby       : ${ACTUAL_RUBY_VERSION}
- CocoaPods  : ${ACTUAL_COCOAPODS_VERSION}
- applesimutils : $(applesimutils --version 2>/dev/null || echo "installed")

EOF