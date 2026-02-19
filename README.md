## Bootstrap a macOS self-hosted runner

This script provisions a fresh macOS machine as a GitHub Actions self-hosted runner. It installs and pins Homebrew, Xcode, iOS simulator runtimes, Node.js (via NVM), Ruby (via rbenv), and CocoaPods to exact versions required by the project. The script is idempotent — if it fails mid-way or is run again, it skips steps that are already complete.

### Prerequisites

If Xcode is not already installed, the script uses [xcodes](https://github.com/XcodesOrg/xcodes) to download and install it. This requires an Apple ID. Export the following environment variables before running the script:

```bash
export XCODE_APPLE_ID="your@apple.id"
export XCODE_APPLE_ID_PASSWORD="your-apple-id-password"
```

If Xcode is already installed at the required version, these variables are not needed.

### Pinned versions

| Tool | Version |
|------|---------|
| Xcode | 16.4 |
| Node.js | 22.12.0 |
| Ruby | 3.1.2 |
| CocoaPods | 1.16.2 |
| iOS Simulator | iOS 18.6 (iPhone 16 Pro) |

### Usage

```bash
curl -fsSL https://raw.githubusercontent.com/sliangreal/bootstrap-self-hosted-mac-runner/main/bootstrap-macos-runner.sh -o /tmp/bootstrap-macos-runner.sh && bash /tmp/bootstrap-macos-runner.sh
```

> **Note:** The script runs interactively. It will prompt for your `sudo` password (for Homebrew and Xcode license acceptance) and may ask for confirmation during certain install steps. Stay at the terminal and watch for prompts.

### Set up runner as LaunchAgent

A GitHub Actions runner installed as a LaunchDaemon runs outside any GUI session, which means macOS user keychains are not available. This causes fastlane's `setup_ci` / `match` / codesign to fail silently. The `setup-runner-launchagent.sh` script sets up the runner as a LaunchAgent so it runs inside the logged-in user's GUI session where keychain operations work normally. If an existing LaunchDaemon is found, it will be converted; otherwise a fresh LaunchAgent plist is created.

```bash
curl -fsSL https://raw.githubusercontent.com/sliangreal/bootstrap-self-hosted-mac-runner/main/setup-runner-launchagent.sh -o /tmp/setup-runner-launchagent.sh && bash /tmp/setup-runner-launchagent.sh
```
