#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sandbox-vm-enter.sh — set up a Lume macOS VM for Tier 4 agent isolation.
# The layered sandbox-tier model is recorded in the forthcoming isolate-cli
# ADR (W6); until it lands, the sandbox-*.sh scripts are the reference.
#
# This is the PRIMARY Tier 4 entry point. It uses Pattern B: Claude Code
# runs INSIDE the VM. The maintainer SSHes into the VM and runs `claude`
# there. Prompt injection of Claude Code only affects the VM, not the
# host. Reference: HN discussion at
# https://news.ycombinator.com/item?id=46670181.
#
# Companion script:
#   sandbox-vm-enter-claude-on-host.sh — Pattern A variant where Claude
#   Code stays on the host and SSHes into the VM (the cua.ai recipe at
#   https://cua.ai/docs/lume/examples/claude-code/sandbox). Pattern A
#   leaves Claude Code on the host as a prompt-injection target; use it
#   only when the threat model does not require host-side containment.
#
# Pattern C (Lume MCP server) is documented in
# docs/lume-mcp-setup.md but is NOT used for the Tier 4 threat model
# because it leaves Claude Code on the host.
#
# Workflow:
#   1. First-run (one-time, ~30 min): create base VM, run vm-bootstrap.sh
#      inside it to install Claude Code and tooling, save as a golden image.
#   2. Per-session: clone golden -> sandbox, start headless, print SSH
#      instructions for the maintainer to log in and run `claude`.
#   3. Cleanup: scripts/sandbox-vm-exit.sh
#
# Usage:
#   sandbox-vm-enter.sh                       # Per-session (default).
#   sandbox-vm-enter.sh --mode=first-run      # One-time golden setup.
#   sandbox-vm-enter.sh --mode=update-golden  # Re-snapshot current sandbox.
#   sandbox-vm-enter.sh --mode=status         # Show VM state.
#
# Environment:
#   BLACKOUTD_VM_NAME      VM name        (default: blackoutd-sandbox)
#   BLACKOUTD_GOLDEN_NAME  Golden image   (default: blackoutd-golden)
#   BLACKOUTD_VM_TIMEOUT   SSH wait sec   (default: 120)

set -eu

VM_NAME="${BLACKOUTD_VM_NAME:-blackoutd-sandbox}"
GOLDEN_NAME="${BLACKOUTD_GOLDEN_NAME:-blackoutd-golden}"
SSH_TIMEOUT="${BLACKOUTD_VM_TIMEOUT:-120}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/sandbox-vm-bootstrap.sh"

mode="session"

usage() {
  cat << 'EOF'
Usage:
  sandbox-vm-enter.sh                       Per-session (default).
  sandbox-vm-enter.sh --mode=first-run      One-time golden image setup.
  sandbox-vm-enter.sh --mode=update-golden  Re-snapshot current sandbox.
  sandbox-vm-enter.sh --mode=status         Show VM state.
  sandbox-vm-enter.sh --help                This message.

Environment:
  BLACKOUTD_VM_NAME      VM name        (default: blackoutd-sandbox)
  BLACKOUTD_GOLDEN_NAME  Golden image   (default: blackoutd-golden)
  BLACKOUTD_VM_TIMEOUT   SSH wait sec   (default: 120)

Pattern B (this script): Claude Code runs IN the VM. Preferred for
adversarial-capability work. Pattern A is in
sandbox-vm-enter-claude-on-host.sh.
EOF
}

err() { printf 'sandbox-vm-enter: %s\n' "$*" >&2; }
die() {
  err "$*"
  exit 1
}
say() { printf 'sandbox-vm-enter: %s\n' "$*"; }

verify_dependencies() {
  command -v lume > /dev/null 2>&1 ||
    die "lume not found. See https://cua.ai/docs/lume/guide/getting-started/introduction"
  command -v jq > /dev/null 2>&1 ||
    die "jq not found. brew install jq"
}

vm_exists() {
  lume list --format json 2> /dev/null |
    jq --exit-status --arg n "$1" '[.[] | select(.name == $n)] | length > 0' \
      > /dev/null 2>&1
}

vm_running() {
  lume list --format json 2> /dev/null |
    jq --exit-status --arg n "$1" \
      '[.[] | select(.name == $n and .status == "running")] | length > 0' \
      > /dev/null 2>&1
}

vm_ip() {
  lume get "$1" --format json 2> /dev/null |
    jq --raw-output '.ip // empty' |
    grep --extended-regexp '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ||
    return 1
}

wait_for_ssh() {
  vm="$1"
  user="$2"
  pw="$3"
  elapsed=0
  while [ "${elapsed}" -lt "${SSH_TIMEOUT}" ]; do
    ip=$(vm_ip "${vm}" 2> /dev/null || true)
    if [ -n "${ip}" ]; then
      if sshpass -p "${pw}" \
        ssh -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${user}@${ip}" "exit 0" 2> /dev/null; then
        printf '%s' "${ip}"
        return 0
      fi
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

session_mode() {
  vm_exists "${GOLDEN_NAME}" ||
    die "Golden image '${GOLDEN_NAME}' not found. Run with --mode=first-run."

  if vm_exists "${VM_NAME}"; then
    if vm_running "${VM_NAME}"; then
      ip=$(vm_ip "${VM_NAME}" 2> /dev/null || printf '<unknown>')
      say "VM '${VM_NAME}' already running at ${ip}"
      print_session_instructions "${ip}" "lume" "lume"
      return 0
    fi
    say "Removing previous sandbox '${VM_NAME}' (golden preserved)..."
    lume delete "${VM_NAME}"
  fi

  say "Cloning '${GOLDEN_NAME}' -> '${VM_NAME}'..."
  lume clone "${GOLDEN_NAME}" "${VM_NAME}"

  say "Starting '${VM_NAME}' headlessly..."
  lume run "${VM_NAME}" --no-display &

  say "Waiting up to ${SSH_TIMEOUT}s for SSH..."
  if ip=$(wait_for_ssh "${VM_NAME}" "lume" "lume"); then
    say "VM ready at ${ip}"
    print_session_instructions "${ip}" "lume" "lume"
  else
    err "VM did not become SSH-reachable within ${SSH_TIMEOUT}s."
    err "Check 'lume list' and 'lume get ${VM_NAME}'."
    return 1
  fi
}

first_run_mode() {
  vm_exists "${GOLDEN_NAME}" &&
    die "Golden image '${GOLDEN_NAME}' already exists. Use --mode=update-golden."
  vm_exists "${VM_NAME}" &&
    die "Sandbox '${VM_NAME}' already exists. Run sandbox-vm-exit.sh --mode=destroy first."
  [ -r "${BOOTSTRAP_SCRIPT}" ] ||
    die "Bootstrap script not found: ${BOOTSTRAP_SCRIPT}"
  command -v sshpass > /dev/null 2>&1 ||
    die "sshpass not installed. brew install sshpass"

  say "Step 1/5: Creating base VM '${VM_NAME}' (15-20 min)..."
  lume create "${VM_NAME}" --os macos --ipsw latest --unattended tahoe

  say "Step 2/5: Starting VM headlessly..."
  lume run "${VM_NAME}" --no-display &

  say "Step 3/5: Waiting for SSH..."
  ip=$(wait_for_ssh "${VM_NAME}" "lume" "lume") ||
    die "VM did not become SSH-reachable within ${SSH_TIMEOUT}s."
  say "VM up at ${ip}"

  say "Step 4/5: Copying bootstrap script and running it inside VM..."
  sshpass -p "lume" \
    scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${BOOTSTRAP_SCRIPT}" \
    "lume@${ip}:/tmp/sandbox-vm-bootstrap.sh"
  sshpass -p "lume" \
    ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "lume@${ip}" \
    "chmod +x /tmp/sandbox-vm-bootstrap.sh && /tmp/sandbox-vm-bootstrap.sh"

  say "Step 5/5: Saving golden image..."
  lume stop "${VM_NAME}"
  lume clone "${VM_NAME}" "${GOLDEN_NAME}"

  say "Done. Golden image saved as '${GOLDEN_NAME}'. Sandbox '${VM_NAME}' preserved."
  say "For next session: ${0}"
  say "To rebuild golden:  ${0} --mode=update-golden"
}

update_golden_mode() {
  vm_exists "${GOLDEN_NAME}" ||
    die "Golden '${GOLDEN_NAME}' not found. Use --mode=first-run instead."
  vm_exists "${VM_NAME}" ||
    die "Sandbox '${VM_NAME}' not found. Start it, modify, then update-golden."
  vm_running "${VM_NAME}" &&
    die "Sandbox '${VM_NAME}' is running. Stop with 'lume stop ${VM_NAME}' first."

  say "Removing existing golden '${GOLDEN_NAME}'..."
  lume delete "${GOLDEN_NAME}"
  say "Saving '${VM_NAME}' as new golden '${GOLDEN_NAME}'..."
  lume clone "${VM_NAME}" "${GOLDEN_NAME}"
  say "Done."
}

status_mode() {
  printf 'Lume version:  '
  lume --version 2> /dev/null || printf '(not installed)\n'
  printf '\n'

  printf 'VMs (lume list):\n'
  lume list 2> /dev/null || printf '  (none or lume not available)\n'
  printf '\n'

  printf 'Golden image (%s):  ' "${GOLDEN_NAME}"
  if vm_exists "${GOLDEN_NAME}"; then
    printf 'present\n'
  else
    printf 'missing\n'
  fi

  printf 'Sandbox      (%s):  ' "${VM_NAME}"
  if vm_exists "${VM_NAME}"; then
    if vm_running "${VM_NAME}"; then
      ip=$(vm_ip "${VM_NAME}" 2> /dev/null || printf '<unknown>')
      printf 'running at %s\n' "${ip}"
    else
      printf 'stopped\n'
    fi
  else
    printf 'absent\n'
  fi
}

print_session_instructions() {
  ip="$1"
  user="$2"
  pw="$3"
  cat << EOF

  ┌─ Sandbox VM ready (Pattern B: Claude Code IN the VM) ───────────┐
  │  IP:        ${ip}
  │  User:      ${user}
  │  Password:  ${pw}
  │
  │  In a separate terminal, SSH into the VM:
  │    ssh ${user}@${ip}
  │
  │  INSIDE the VM:
  │    1. export ANTHROPIC_API_KEY=<your-key-here>
  │       (Or use 'claude /login' for OAuth on first run.)
  │    2. cd ~ && git clone https://github.com/toobuntu/blackoutd.git
  │    3. cd blackoutd
  │    4. claude
  │
  │  Claude Code runs INSIDE the VM. Prompt-injection that
  │  compromises Claude Code only affects this VM. Reset by:
  │    scripts/sandbox-vm-exit.sh --mode=reset
  │
  │  When done with the session, exit SSH, then on the HOST:
  │    scripts/sandbox-vm-exit.sh                # Stop, keep VM
  │    scripts/sandbox-vm-exit.sh --mode=reset   # Stop, delete sandbox
  │
  │  API key handling: per-session env var is recommended over
  │  persisting credentials in the golden image. The golden image
  │  contains tooling only, no credentials.
  └─────────────────────────────────────────────────────────────────┘

EOF
}

parse_args() {
  for arg; do
    case "${arg}" in
    --mode=session | --mode=first-run | --mode=update-golden | --mode=status)
      mode="${arg#--mode=}"
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: ${arg}"
      usage >&2
      exit 2
      ;;
    esac
  done
}

main() {
  parse_args "$@"
  verify_dependencies
  case "${mode}" in
  session) session_mode ;;
  first-run) first_run_mode ;;
  update-golden) update_golden_mode ;;
  status) status_mode ;;
  esac
}

main "$@"
