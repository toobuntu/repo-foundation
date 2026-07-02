#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sandbox-vm-exit.sh — tear down or reset the Tier 4 Lume VM.
# Companion to sandbox-vm-enter.sh.
#
# Modes:
#   --mode=stop     Stop the VM but keep its disk image. Default.
#   --mode=reset    Stop + delete the sandbox; golden image preserved.
#                   Next sandbox-vm-enter.sh creates a fresh clone from golden.
#   --mode=destroy  Stop + delete sandbox AND golden image. Full teardown.
#                   Reverses sandbox-vm-enter.sh --mode=first-run.
#   --mode=status   Show VM state without modifying.
#
# Environment:
#   BLACKOUTD_VM_NAME      VM name        (default: blackoutd-sandbox)
#   BLACKOUTD_GOLDEN_NAME  Golden image   (default: blackoutd-golden)

set -eu

VM_NAME="${BLACKOUTD_VM_NAME:-blackoutd-sandbox}"
GOLDEN_NAME="${BLACKOUTD_GOLDEN_NAME:-blackoutd-golden}"

mode="stop"

usage() {
  cat << 'EOF'
Usage:
  sandbox-vm-exit.sh                    Stop the sandbox VM (default).
  sandbox-vm-exit.sh --mode=reset       Stop + delete sandbox; keep golden.
  sandbox-vm-exit.sh --mode=destroy     Stop + delete sandbox AND golden.
  sandbox-vm-exit.sh --mode=status      Show state.
  sandbox-vm-exit.sh --help             This message.

Environment:
  BLACKOUTD_VM_NAME      VM name        (default: blackoutd-sandbox)
  BLACKOUTD_GOLDEN_NAME  Golden image   (default: blackoutd-golden)
EOF
}

err() { printf 'sandbox-vm-exit: %s\n' "$*" >&2; }
die() {
  err "$*"
  exit 1
}
say() { printf 'sandbox-vm-exit: %s\n' "$*"; }

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

stop_vm_if_running() {
  if vm_running "$1"; then
    say "Stopping VM '$1'..."
    lume stop "$1"
  else
    say "VM '$1' is not running."
  fi
}

stop_mode() {
  if vm_exists "${VM_NAME}"; then
    stop_vm_if_running "${VM_NAME}"
    say "Sandbox '${VM_NAME}' preserved. Restart with sandbox-vm-enter.sh."
  else
    say "Sandbox '${VM_NAME}' does not exist. Nothing to stop."
  fi
}

reset_mode() {
  if vm_exists "${VM_NAME}"; then
    stop_vm_if_running "${VM_NAME}"
    say "Deleting sandbox '${VM_NAME}'..."
    lume delete "${VM_NAME}"
  else
    say "Sandbox '${VM_NAME}' does not exist. Nothing to reset."
  fi
  if vm_exists "${GOLDEN_NAME}"; then
    say "Golden '${GOLDEN_NAME}' preserved. Re-create sandbox with sandbox-vm-enter.sh."
  else
    err "Golden image '${GOLDEN_NAME}' is also missing. You'll need --mode=first-run."
  fi
}

destroy_mode() {
  say "DESTROY: This deletes both the sandbox and the golden image."
  say "         To rebuild, sandbox-vm-enter.sh --mode=first-run (~30 min)."
  if vm_exists "${VM_NAME}"; then
    stop_vm_if_running "${VM_NAME}"
    say "Deleting sandbox '${VM_NAME}'..."
    lume delete "${VM_NAME}"
  fi
  if vm_exists "${GOLDEN_NAME}"; then
    say "Deleting golden '${GOLDEN_NAME}'..."
    lume delete "${GOLDEN_NAME}"
  fi
  say "All Tier 4 VM state removed."
}

status_mode() {
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
      printf 'running\n'
    else
      printf 'stopped\n'
    fi
  else
    printf 'absent\n'
  fi
}

parse_args() {
  for arg; do
    case "${arg}" in
    --mode=stop | --mode=reset | --mode=destroy | --mode=status)
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
  stop) stop_mode ;;
  reset) reset_mode ;;
  destroy) destroy_mode ;;
  status) status_mode ;;
  esac
}

main "$@"
