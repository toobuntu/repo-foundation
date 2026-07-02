#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sandbox-vm-bootstrap.sh — runs INSIDE the Lume macOS VM during first-run
# to install the tooling needed for blackoutd development.
#
# This script is copied into the VM by sandbox-vm-enter.sh --mode=first-run
# and executed via SSH as user 'lume'. It installs Xcode Command Line Tools,
# Homebrew, Claude Code, and the project's lint/dev tooling.
#
# DELIBERATE TRADE-OFFS:
#   - curl-pipe-shell is used to install Homebrew. Standard practice.
#     The VM is the containment; if the install script were compromised,
#     the host would still be unaffected.
#   - xcode-select --install is normally interactive; the workaround here
#     uses softwareupdate which is non-interactive but slower (~10 min).
#
# Idempotent where reasonable: re-running checks if a tool is already
# installed before re-installing. Re-running on a complete bootstrap is a
# no-op.

set -eu

log() { printf '[bootstrap] %s\n' "$*"; }
die() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

ensure_xcode_clt() {
  if xcode-select --print-path > /dev/null 2>&1; then
    log "Xcode CLT already present at $(xcode-select --print-path)"
    return 0
  fi
  log "Installing Xcode Command Line Tools (~10 min, non-interactive)..."
  placeholder=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  sudo touch "${placeholder}"
  label=$(softwareupdate --list 2>&1 |
    grep --extended-regexp '\* (Command Line|Label:.*Command Line)' |
    head -n 1 |
    sed -e 's/^[[:space:]]*\* //' -e 's/^Label: //')
  [ -n "${label}" ] || die "Could not find Command Line Tools in softwareupdate --list"
  sudo softwareupdate --install --verbose "${label}"
  sudo rm -f "${placeholder}"
  xcode-select --print-path > /dev/null 2>&1 ||
    die "Xcode CLT installation appears incomplete"
}

ensure_homebrew() {
  if command -v brew > /dev/null 2>&1; then
    log "Homebrew already installed at $(command -v brew)"
    return 0
  fi
  log "Installing Homebrew (curl-pipe-shell, by design — see header)..."
  NONINTERACTIVE=1 \
    /bin/bash -c \
    "$(curl --fail --silent --show-error --location https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  arch=$(uname -m)
  case "${arch}" in
  arm64) brew_prefix=/opt/homebrew ;;
  x86_64) brew_prefix=/usr/local ;;
  *) die "Unrecognized architecture: ${arch}" ;;
  esac
  eval "$(${brew_prefix}/bin/brew shellenv)"
  {
    printf '\n# Homebrew (added by sandbox-vm-bootstrap.sh)\n'
    printf 'eval "$(%s/bin/brew shellenv)"\n' "${brew_prefix}"
  } >> "${HOME}/.zprofile"
  command -v brew > /dev/null 2>&1 || die "Homebrew install appears incomplete"
}

ensure_brew_packages() {
  packages="
        gh
        jq
        ksh
        shellcheck
        shfmt
        actionlint
        zizmor
        pinact
        clang-format
        reuse
        sshpass
    "
  log "Installing Homebrew packages..."
  for pkg in ${packages}; do
    if brew list --formula --quiet "${pkg}" > /dev/null 2>&1; then
      log "  ${pkg}: already installed"
    else
      log "  ${pkg}: installing"
      brew install "${pkg}" || log "  ${pkg}: install failed (continuing)"
    fi
  done
}

ensure_claude_code() {
  if command -v claude > /dev/null 2>&1; then
    log "Claude Code already installed at $(command -v claude)"
    return 0
  fi
  log "Installing Claude Code..."
  if ! brew install --cask claude-code 2> /dev/null; then
    log "Cask install failed; falling back to claude.ai/install.sh"
    curl --fail --silent --show-error --location https://claude.ai/install.sh | bash
  fi
  command -v claude > /dev/null 2>&1 || die "Claude Code install appears incomplete"
}

print_summary() {
  log "=== Bootstrap complete ==="
  log "Versions:"
  for cmd in xcode-select brew claude gh jq ksh shellcheck shfmt actionlint zizmor pinact clang-format reuse; do
    if command -v "${cmd}" > /dev/null 2>&1; then
      ver=$("${cmd}" --version 2> /dev/null | head -n 1)
      printf '  %-15s %s\n' "${cmd}" "${ver:-(installed)}"
    else
      printf '  %-15s (NOT INSTALLED)\n' "${cmd}"
    fi
  done
  log "VM is ready. Stop with 'sudo shutdown -h now', clone to golden on host."
}

main() {
  [ "$(uname -s)" = "Darwin" ] || die "This bootstrap targets macOS only"
  [ "$(id -un)" = "lume" ] || log "WARNING: expected user 'lume', got '$(id -un)'"

  log "Starting blackoutd VM bootstrap on $(uname -srv)"

  ensure_xcode_clt
  ensure_homebrew
  ensure_brew_packages
  ensure_claude_code
  print_summary
}

main "$@"
