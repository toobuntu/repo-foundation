#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# act-run.sh — run this repository's GitHub Actions workflows locally with act.
#
# A thin wrapper that remembers the flags. Every one of them exists because
# omitting it fails in a way that looks like something else: the wrong
# container architecture pours x86_64 bottles onto a CPU without SSSE3, the
# default image has no Linuxbrew, and act tries to bind-mount Colima's socket
# unless told not to. docs/testing-github-workflows-locally.md explains each.
#
# The subcommand names the runner family because a job runs one of two ways:
# `linux` starts a container through Colima, `macos` runs on this host and
# therefore touches it (a real brew install, a real toolchain setup).
#
# Usage:
#   act-run.sh list [<event>]        jobs act can see, optionally for one event
#   act-run.sh validate [<event>]    schema-check the workflows; no daemon
#   act-run.sh plan <job>            plan every step, execute none; no daemon
#   act-run.sh linux <job>           run one ubuntu-latest job in a container
#   act-run.sh macos <job>           run one macos-latest job on this host
#
# Options:
#   --offline        use cached image and actions; no registry contact
#   --keep-colima    leave Colima running afterwards (saves the next boot)
#   --yes            skip the confirmation prompt before a host run
#   --               pass every remaining argument through to act

set -eu

# Any non-empty value silences act's M-series warning, and the value is unused
# when no container starts. NOASSERTION is deliberate, not a placeholder.
ARCH_NONE=NOASSERTION
ARCH_LINUX=linux/arm64
ARCH_MACOS=darwin/arm64
IMAGE_LINUX=catthehacker/ubuntu:full-latest
SELF_HOSTED=-self-hosted

offline=""
keep_colima=""
assume_yes=""
colima_started=""

usage() {
  printf 'Usage: %s [--offline] [--keep-colima] [--yes] <list|validate|plan|linux|macos> [<arg>] [-- <act-arg>...]\n' "${0##*/}" >&2
}

die() {
  printf '%s: %s\n' "${0##*/}" "$1" >&2
  exit 1
}

require_tool() {
  command -v "$1" > /dev/null 2>&1 || die "$1 is not installed (brew install $2)"
}

# Offline flags are shared by every act invocation that can reach the network.
# --action-offline-mode also turns off force pull, so --pull=false is belt and
# braces for the runner image specifically.
offline_flags() {
  [ -n "$offline" ] && printf -- '--pull=false --action-offline-mode'
}

colima_running() {
  colima status > /dev/null 2>&1
}

# Bring Colima up only if it is down, and remember that we did, so an already
# running daemon is never stopped out from under another user of it.
colima_up() {
  if colima_running; then
    return 0
  fi
  colima start
  colima_started=1
}

# Registered as an EXIT trap for the duration of a linux run, so the VM comes
# down even when act fails or the run is interrupted.
colima_down() {
  if [ -n "$colima_started" ] && [ -z "$keep_colima" ]; then
    colima stop || true
  fi
}

confirm_host_run() {
  [ -n "$assume_yes" ] && return 0
  printf 'A macos run executes the job on THIS Mac: a real brew install, a real\n' >&2
  printf 'toolchain setup, and the suite runs in this checkout. Continue? [y/N] ' >&2
  read -r reply || reply=""
  case "$reply" in
  [Yy]*) return 0 ;;
  *) die "cancelled" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --offline) offline=1 ;;
  --keep-colima) keep_colima=1 ;;
  --yes) assume_yes=1 ;;
  --help | -h)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*) die "unknown option: $1" ;;
  *) break ;;
  esac
  shift
done

[ "$#" -gt 0 ] || {
  usage
  exit 2
}

command=$1
shift

require_tool act act

case "$command" in
list | validate)
  # The event is a bare positional argument to act, and act accepts at most
  # one, so it has to be consumed here rather than left in "$@".
  event=""
  if [ "$#" -gt 0 ]; then
    event=$1
    shift
  fi
  if [ "$command" = validate ]; then
    action=--validate
  else
    action=--list
  fi
  exec act --container-architecture="$ARCH_NONE" ${event:+"$event"} "$action" "$@"
  ;;
plan)
  [ "$#" -gt 0 ] || die "plan needs a job id"
  job=$1
  shift
  # -self-hosted keeps the plan off the Docker API entirely, so this form
  # needs no daemon and runs inside the agent sandbox.
  # shellcheck disable=SC2046
  exec act --container-architecture="$ARCH_NONE" --job "$job" \
    --platform "macos-latest=$SELF_HOSTED" \
    --platform "ubuntu-latest=$SELF_HOSTED" \
    --no-cache-server --action-cache-path "${TMPDIR:-/tmp}/actcache" \
    --dryrun $(offline_flags) "$@"
  ;;
linux)
  [ "$#" -gt 0 ] || die "linux needs a job id"
  job=$1
  shift
  require_tool colima colima
  require_tool docker docker
  trap colima_down EXIT INT TERM
  colima_up
  # shellcheck disable=SC2046
  act --job "$job" \
    --platform "ubuntu-latest=$IMAGE_LINUX" \
    --container-architecture "$ARCH_LINUX" \
    --container-daemon-socket=- \
    --rm $(offline_flags) "$@"
  ;;
macos)
  [ "$#" -gt 0 ] || die "macos needs a job id"
  job=$1
  shift
  confirm_host_run
  # shellcheck disable=SC2046
  exec act --job "$job" \
    --platform "macos-latest=$SELF_HOSTED" \
    --container-architecture "$ARCH_MACOS" \
    --quiet $(offline_flags) "$@"
  ;;
*)
  usage
  exit 2
  ;;
esac
