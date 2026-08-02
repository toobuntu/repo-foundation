<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Testing GitHub workflows locally

[`act`](https://github.com/nektos/act) runs GitHub Actions workflows locally, before a push, so a workflow edit can be checked without burning a CI round-trip. It is a developer tool, never part of CI itself. This page records what works for this organization's workflows on an Apple-silicon Mac with Colima, verified by running them, and what each flag is for — because the flags are hard to discover. The page is canonical, synced from repo-foundation: the job names in the examples are the synced org workflows, present in every consumer unless marked otherwise, and the transcripts were recorded in repo-foundation, the hub.

## The wrapper

`scripts/act-run.sh` carries the flag combinations below so you do not have to. It is synced alongside this page and the workflows it runs, so it is present wherever this page is. A thin wrapper, not an abstraction — every flag it passes is documented here, and `--` hands the rest through to act:

```sh
scripts/act-run.sh list [<event>]     # jobs act can see, optionally for one event
scripts/act-run.sh validate           # schema check; no daemon
scripts/act-run.sh plan <job>         # every step planned, none executed; no daemon
scripts/act-run.sh linux <job>        # one ubuntu-latest job, Colima lifecycle included
scripts/act-run.sh macos <job>        # one macos-latest job, on this host, after a prompt
```

`--offline` adds `--pull=false --action-offline-mode`, `--keep-colima` leaves the VM up between runs, and `--yes` skips the host-run prompt. The `linux` subcommand starts Colima only if it is down and stops it from an `EXIT` trap, so an already-running daemon is never taken out from under something else and a failed job still cleans up.

Read the rest of this page when a run surprises you. The wrapper encodes the answers; the sections below are why they are the answers.

## Quick reference

Copy-paste forms for the common cases, and what the wrapper is doing on your behalf. Everything below is explained in the sections that follow.

**Pick the event first.** `act` defaults to `push`, and a job whose workflow does not list `push` is then simply invisible — `scaffold-drift` (`schedule`) is the one that catches people in every repo; repo-foundation's own `sync-from-upstreams` (`schedule`, `workflow_dispatch`) is another. The event is a bare positional argument. List what an event actually reaches before running anything:

```sh
act --list                    # every job, with the events each responds to
act pull_request --list       # only the jobs a pull request triggers
act schedule --list           # only the cron jobs
```

**Structure check — no Docker, no Colima, fast.** `--validate` schema-checks and exits; it is the one form that also works inside the agent sandbox:

```sh
act --container-architecture=NOASSERTION pull_request --validate
```

**Plan check.** `--dryrun` plans every step without executing any. It does **not** pull: `NewDockerPullExecutor` returns early on `common.Dryrun(ctx)`, before `ImageExistsLocally` or `GetDockerClient`. What it still does, and each of these was measured rather than assumed:

- **Reaches the Docker API for a *container* job**, somewhere later in job setup than the pull — so a daemon must be up. Forcing `--platform <label>=-self-hosted` skips that entirely and needs no daemon.
- **Binds a TCP port for act's cache server** (default address, port 0). This is the cache server, not the artifact server — that one starts only when `--artifact-server-path` is given. `--no-cache-server` removes the bind.
- **Writes to `~/.cache/act`** for the action cache and host workspaces. `--action-cache-path` moves it.

The last two are what the agent sandbox refuses (`bind: operation not permitted`, then `mkdir …: operation not permitted`). Redirect both and `--dryrun` runs there:

```sh
act --container-architecture=NOASSERTION --no-cache-server \
  --action-cache-path "$TMPDIR/actcache" \
  --job spec --platform macos-latest=-self-hosted --dryrun
```

Verified in-sandbox to `✅ Success - Set up job`, stopping only where the sandbox intercepts TLS to `github.com` while fetching actions (`x509: OSStatus -26276`) — an environment limit, not act's. In an ordinary terminal the plain form is enough:

```sh
colima start
act --container-architecture=NOASSERTION pull_request --job shell-lint --dryrun
```

**Real run of one `ubuntu-latest` job**, with the Colima lifecycle wrapped around it. `;` rather than `&&` before `colima stop` so the VM comes down even when the job fails:

```sh
colima start && act pull_request --job shell-lint \
  --platform ubuntu-latest=catthehacker/ubuntu:full-latest \
  --container-architecture linux/arm64 \
  --container-daemon-socket=- ; colima stop
```

Notes on that form:

- **No `DOCKER_HOST`, deliberately.** act finds a default-profile Colima by probing `~/.colima/docker.sock`; it is only Docker *contexts* that act ignores. Set `DOCKER_HOST` for a non-default profile or a remote daemon — see Setup for both forms and which to prefer.
- **`--container-daemon-socket=-` is required** with Colima for any container job — otherwise act tries to bind-mount `~/.colima/docker.sock` and Colima refuses (see the flag table).
- **`;` rather than `&&` before `colima stop`**, so the VM comes down even when the job fails.

**The `macos-latest` job (`spec.yml`)** needs no Docker and no Colima at all — it runs on the host. That means a real `brew install` and Ruby setup against your actual Mac:

```sh
act --job spec --platform macos-latest=-self-hosted \
  --container-architecture darwin/arm64 --quiet
```

To keep the host untouched, run that same command inside a throwaway lume VM instead. That needs a prepared baseline, which is a one-time build — the whole flow, and the per-run clone that uses it, is under *Isolating it in a VM (lume)* below rather than duplicated here.

**Leaving Colima up** between runs is fine and saves the boot; `colima stop` is for reclaiming the VM's memory. `--pull=false` after the first run skips the image check.

`NOASSERTION` in the validate and dryrun forms is deliberate, not a placeholder: any non-empty `--container-architecture` value silences the M-series warning, and the value is unused when no container starts. A real run needs a real platform — `linux/arm64` here.

## Setup

```sh
brew install act colima docker      # core: everything except the lume VM path
colima start                        # boots a Linux VM (Lima) that speaks the Docker API

brew install lume                   # only for "Isolating it in a VM (lume)" below
```

**Three separate pieces, and knowing which does what makes the failures legible.** [act speaks the Docker API directly](https://github.com/nektos/act#how-does-it-work) — "It uses the Docker API to either pull or build the necessary images … and finally … to run containers for each action" — so it never shells out to the `docker` command. Colima supplies the other end: a Lima VM running the Docker **daemon**. The `docker` formula is the **client** only, and [Colima requires it](https://github.com/abiosoft/colima#runtimes) for the Docker runtime — "Docker client is required for Docker runtime. Installable with `brew install docker`" — because Colima uses it to create and select the Docker context at startup. It is also what every diagnostic on this page is written in (`docker context inspect`, `docker system df`, `docker image rm`).

So the client is genuinely required, just not by act. **Docker Desktop is not needed at any point** — `brew install docker` is the CLI alone, and Colima replaces the desktop application's daemon.

**With a default-profile Colima you need no `DOCKER_HOST` at all** — verified, both for the host job and for a real container job that pulled an image and ran `docker exec`. The precise condition is that the compatibility socket `~/.colima/docker.sock` **exists**: a non-default profile does not create it, and neither does a Colima that is stopped. When it is absent, act falls through the rest of its probe list to `/var/run/docker.sock` and fails there — set `DOCKER_HOST` in that case (below). This is worth explaining, because it sits next to a true statement that sounds like it should forbid it.

Two different mechanisms:

- [act does not support Docker **contexts**.](https://nektosact.com/missing_functionality/docker_context.html) Selecting one with `docker context use` genuinely does not reach act. That is upstream's own note, and it is correct.
- act does probe a fixed list of **socket paths** when `DOCKER_HOST` is unset. `$HOME/.colima/docker.sock` is the third entry in that list (`CommonSocketLocations` in `pkg/container/docker_socket.go`, after `/var/run/docker.sock` and Podman's), so a default-profile Colima is found by path — not by context. `DOCKER_HOST` wins whenever it is set.

So the routine case needs nothing, and `act` announces what it picked:

```text
INFO Using docker host 'unix:///Users/you/.colima/docker.sock', and daemon socket 'unix:///Users/you/.colima/docker.sock'
```

**Set `DOCKER_HOST` when your socket is not on that list**: a non-default Colima profile (`colima start --profile x` puts its socket at `~/.colima/x/docker.sock`, which is not probed), a remote or TCP daemon, or another runtime that keeps its socket elsewhere. The symptom is `Couldn't get a valid docker connection: no DOCKER_HOST and an invalid container socket ''`. Upstream's workaround, resolved with Docker's own `--format` and no `jq`:

```sh
export DOCKER_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
```

That passes no context name, so it reads whichever context is active — brief, and correct when you know which that is. Naming the context is the deterministic form, and is the better habit on a machine with more than one:

```sh
export DOCKER_HOST=$(docker context inspect colima --format '{{.Endpoints.docker.Host}}')
```

The two resolve to different-looking but equivalent paths for a default Colima — auto-detection finds `~/.colima/docker.sock`, the named context reports `~/.colima/default/docker.sock`. Either connects.

`DOCKER_CERT_PATH` (which upstream mentions alongside) is only for a daemon reached over TLS-secured TCP with client certificates. A local Unix socket never needs it, so it does not arise here.

macOS jobs need no backend at all.

## Flag reference

| Flag | What it does | When |
| --- | --- | --- |
| `-j, --job <id>` | Run one job by id. | Always — narrow to the job you're checking. |
| `-P, --platform <label>=<target>` | Map a `runs-on:` label to a container image, or to `-self-hosted` to run on this host. | `ubuntu-latest=catthehacker/ubuntu:full-latest` for the brew jobs; `macos-latest=-self-hosted` for `spec.yml`. |
| `--container-architecture <arch>` | Container CPU architecture. | `linux/arm64` (native, alias `linux/aarch64`) is what makes the brew jobs work here — see below. Also silences the M-series warning on a host job, where it is otherwise ignored. |
| `--container-daemon-socket=-` | Do **not** bind-mount the Docker socket into the container. | **Required with Colima** for container jobs — else `act` tries to mount `~/.colima/docker.sock` and Colima rejects it (`operation not supported`). The jobs here don't talk to Docker, so `-` is correct. |
| `--dryrun` | Plan every step; execute nothing. | Quick structure check. |
| `--validate` | Schema-check the workflow files. | Quick structure check. |
| `--pull=false` | Skip the registry check and use the local image. | Offline, or pinning behavior for a debugging session. Not needed for speed — see below. |

A `~/.actrc` (or `~/Library/Application Support/act/actrc`) holds machine defaults; act ships one mapping `ubuntu-latest` to the medium `act-latest` image. This repo commits no `.actrc` — the useful flags describe your Colima and arch, not the project.

`act --list-options` prints every flag with its default and description as JSON, which is the reliable way to check one rather than trusting a remembered default.

## Image caching: you do not need to manage it

The runner image is large enough that "am I re-downloading this every run?" is the natural worry. You are not, and the four flags that look like they control it mostly control something else.

**`--pull` defaults to true and that is fine.** It does not re-download; it asks the registry whether the local digest is still current. Under `--verbose` a warm run shows the whole exchange:

```text
docker pull image=catthehacker/ubuntu:full-latest platform=linux/arm64 forcePull=true
Status: Image is up to date for catthehacker/ubuntu:full-latest
```

That is one manifest request, and layers transfer only when the digest actually moved. So the recurring cost of the default is a round trip, not gigabytes, and the freshness comes free. Reach for `--pull=false` when you are offline or when you deliberately want the image held still while you debug something else — not as a routine optimization.

**`--rebuild` is about local actions, not the runner image.** It rebuilds Docker images for `Dockerfile`-based actions in the repository. The org's workflows use none, so it is inert here.

**`--reuse` keeps the container between runs**, which trades reproducibility for speed: a reused container carries the previous run's installed packages and caches, so a failure then has two candidate causes. This is the same argument this page makes for building lume clones from a baseline rather than reusing a guest. Fine for tight iteration on one step, wrong whenever the result matters.

**`--rm` is failure-path hygiene.** A successful run already tears down its container and volumes on its own; `--rm` extends that to failures, which is what stops dead containers accumulating across a debugging session.

**`--action-offline-mode` is the single "use what is on disk" switch.** It skips re-fetching action contents that are already cached and turns off force pull in one flag, which is the right shape for an air-gapped or repeat run.

To check whether the published image has moved without pulling anything, inspect the remote manifest. With Homebrew's `docker` formula the plugin is not wired into the `docker` CLI, so the binary is hyphenated:

```sh
brew install docker-buildx
docker-buildx imagetools inspect catthehacker/ubuntu:full-latest \
  --format '{{json (index .Image "linux/arm64")}}' |
  jq '{created, version: .config.Labels["org.opencontainers.image.version"]}'
```

Worth doing once, because the answer is not what you would guess: the arm64 `full-latest` lags GitHub's hosted runner image by months (`ubuntu24-runner-large-…-arm64`, built well before the Ubuntu 26 images the hosted runners moved to). Local arm64 runs therefore exercise an *older* userspace than CI does. That is an argument for leaving `--pull` at its default rather than pinning with `--pull=false`, and a reason to treat a green local run as evidence rather than proof.

**The Colima VM ages separately from the images inside it.** `colima update` updates the container runtime in place — note that this is the docker or containerd binary *inside* the Lima VM, per profile, and has nothing to do with `brew upgrade colima`, which updates the colima CLI on the host. Similar word, different layer. A newer base image, and so a newer kernel and userspace, comes only from recreating the VM (`colima delete` then `colima start`), which discards every image, container and volume it held — so the next act run re-pulls the runner image in full. `colima prune` clears cached downloaded assets without touching the VM. None of this is on a schedule; recreate when you have a reason.

## The `macos-latest` job (`spec.yml`)

Runs **directly on the host** — no container, no Colima, no image:

```sh
act --job spec --platform macos-latest=-self-hosted   # verified: job succeeded
```

The sentinel is the literal string `-self-hosted`; a bare `-` is read as an image reference and fails with `invalid reference format`. Running on the host exercises the real workflow around the suite — `Homebrew/actions/setup-ruby`, `brew install vale`, the Bundler cache — not just a bare `rspec`; the trade-off is that it *touches* the host (a real `brew install`, a real Ruby setup) and runs the suite in the current checkout. The M-series "specify container architecture" warning still prints and is harmless here; passing **any** `--container-architecture` value silences it — the value is ignored for a host job, so `darwin/arm64` or even a bogus string works — and `--quiet` trims the rest of the noise:

```sh
act --job spec --platform macos-latest=-self-hosted --container-architecture darwin/arm64 --quiet
```

### Isolating it in a VM (lume)

`-self-hosted` runs the job on your real Mac, so its `brew install` and Ruby setup touch the host. To isolate it, run the job inside a throwaway macOS VM with [lume](https://github.com/trycua/lume) (Apple's Virtualization.framework).

> **Status (2026-07-31, maintainer-run, lume 0.5.1): verified end to end, both halves.** The baseline build — create, unattended setup, key install, temporary sudo grant, Homebrew, revoke, `brew install act` — and then the run path against a clone of it: boot, share mount, `act version 0.2.89` inside the guest, and the checkout copied to the right path. Do not use lume 0.5.0: `lume create` traps there on every macOS install (see *When a lume command fails*). 0.5.1 fixes it.

Two one-time settings before anything else. Telemetry is on by default (pseudonymous install and usage metadata — no names, paths, or VM contents); the org opts out of dev-tool analytics uniformly, the same stance as `HOMEBREW_NO_ANALYTICS=1`:

```sh
brew install lume                    # jq ships with macOS (since Sequoia); no need to install it
lume config telemetry disable        # `lume config get` shows the current state
```

Also set `LUME_UPDATE_CHECK=false` in your shell profile. It disables the read-only GitHub Releases request behind `lume check-update`, `lume update`, *and* the MCP `check_for_update` tool. And never run `lume update` on a Homebrew install — it would put a non-brew binary where brew expects its own; upgrades come from `brew upgrade lume`.

#### Build the baseline once

A vanilla image has no Homebrew, and that install is the slow part — so do it once and keep the result as a template you never run jobs in. The whole sequence, in order, with nothing referenced before it is defined:

<!-- rumdl-disable MD013 -->

```sh
# --- Settings this block uses -------------------------------------------
# A dedicated VM key, named per the org's key schema (PURPOSE_SCOPE_YM_ALGO--ID,
# comment PURPOSE:SCOPE:ID). Generate once and reuse for every baseline.
YM=$(date +%Y-%m)
ID="user:<you>+${YM}@<example.com>"
VMKEY=~/.ssh/auth_lume_${YM}_ed25519--${ID}
[ -f "$VMKEY" ] || { ssh-keygen -t ed25519 -a 100 -N '' -q -f "$VMKEY" -C "auth:lume:${ID}"; chmod 600 "$VMKEY"; }

# --- 1. Create the VM ---------------------------------------------------
# `--ipsw latest` downloads the ~18 GB restore image into $TMPDIR and does NOT
# keep it. If you expect to rebuild baselines, fetch it once to a durable path
# and pass that instead:
#
#   IPSW_URL="$(lume ipsw | tail -n 1)"
#   curl -fL -o ~/Downloads/macos-tahoe.ipsw "$IPSW_URL"
#   lume create macos-baseline --ipsw ~/Downloads/macos-tahoe.ipsw --unattended tahoe
#
# The tahoe preset creates the lume user (login lume / lume) and enables SSH,
# autologin, and no-sleep/no-lock. It ends by STOPPING the VM, and it prints
# `CancellationError` while doing so -- benign, see the troubleshooting list.
lume create macos-baseline --ipsw latest --unattended tahoe

# --- 2. Start it, and wait until it is really up ------------------------
# `--display=none` suppresses the viewer, not the VM (0.5.x opens a native
# window by default). `--detach` returns a PID immediately -- which is NOT a
# success signal: the child can fail a second later and only the log says so.
# Poll for the address, then for SSH.
lume run macos-baseline --display=none --detach
ip=""
for _ in $(seq 60); do
  ip=$(lume get --format=json macos-baseline | jq --raw-output '.[0].ipAddress // empty')
  [ -n "$ip" ] && break
  sleep 5
done
[ -n "$ip" ] || { echo "VM never got an address; see ~/Library/Logs/lume/macos-baseline.log" >&2; exit 1; }

# An address is not sshd. Probe the PORT, not a login: the key is not installed
# yet, so an auth-based probe fails for the wrong reason and cannot distinguish
# "sshd is down" from "no key yet".
up=""
for _ in $(seq 60); do
  nc -z -G 2 "$ip" 22 2>/dev/null && { up=1; break; }
  sleep 5
done
[ -n "$up" ] || { echo "sshd never came up at $ip; see ~/Library/Logs/lume/macos-baseline.log" >&2; exit 1; }

sshvm() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o RequestTTY=force -o IdentitiesOnly=yes -i "$VMKEY" lume@"$ip" "$@"
}

# --- 3. Install the key so ssh stops prompting --------------------------
# -i names ONE key: without it, ssh-copy-id installs EVERY public key in the
# agent (two landed here on the first attempt).
ssh-copy-id -i "${VMKEY}.pub" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null lume@"$ip"

# --- 4. Grant root, install Homebrew, revoke -- ONE invocation ----------
# The three are one remote command so the revoke rides an EXIT trap: an
# install.sh that fails or is interrupted still takes the grant with it. Split
# across three ssh calls, an abort in the middle leaves a passwordless-root
# guest that every later clone inherits.
#
# The grant is written to a TEMP file and validated there, because `visudo -cf`
# on an already-installed file validates too late: a malformed file is in
# /etc/sudoers.d the moment it lands, and a bad file there can lock sudo out of
# the guest entirely. install(1) does the move with the right mode in one step,
# and only if validation passed.
#
# NOTE the installer executes remote code fetched at run time from a mutable ref
# (Homebrew's documented entry point is HEAD; there is no released installer tag
# to pin). Acceptable HERE and only here: a disposable guest, on a private NAT,
# whose root grant expires with this command. Do not lift that line into a
# context where any of those three stops being true.
sshvm 'set -eu
  trap 'sudo rm -f /etc/sudoers.d/baseline-build
    test ! -e /etc/sudoers.d/baseline-build ||
      echo "WARNING: could not remove the sudo grant; remove it before cloning" >&2' EXIT
  echo lume | sudo --stdin --validate
  printf "lume ALL=(ALL) NOPASSWD: ALL\n" > /tmp/baseline-build
  sudo visudo -cf /tmp/baseline-build
  sudo install -m 440 -o root -g wheel /tmp/baseline-build /etc/sudoers.d/baseline-build
  rm -f /tmp/baseline-build
  NONINTERACTIVE=1 /bin/bash -c "$(curl --fail --silent --show-error --location https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

# --- 5. Confirm the grant is gone ---------------------------------------
# The trap should have removed it; verify rather than assume, because a baseline
# cloned with the grant still in place propagates it to every run clone. If this
# prints nothing, remove it by hand before cloning.
sshvm '! test -e /etc/sudoers.d/baseline-build && echo "grant revoked"'

# --- 6. Toolchain --------------------------------------------------------
# Every brew call carries the inline shellenv: `ssh host command` is a
# non-login shell and reads neither ~/.zprofile nor /etc/paths.d.
sshvm 'mkdir -p ~/.homebrew && cat >> ~/.homebrew/brew.env <<EOF
HOMEBREW_NO_ANALYTICS=1
HOMEBREW_NO_ASK=1
HOMEBREW_NO_UPDATE_REPORT_NEW=1
HOMEBREW_DISPLAY_INSTALL_TIMES=1
EOF'
sshvm 'echo "eval \"\$(/opt/homebrew/bin/brew shellenv)\"" >> ~/.zprofile'
sshvm 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew install act'

# --- 7. Shut down gracefully --------------------------------------------
# `shutdown`, not `stop`: this is the copy that gets kept and cloned, and it
# has just written a Homebrew tree. `shutdown` powers the guest down over SSH;
# `stop` is the immediate process-level stop, right for throwaway clones.
lume shutdown macos-baseline
# `shutdown` returns before the VM is down, and the clone step needs it
# stopped, so wait rather than racing it.
for _ in $(seq 60); do
  [ "$(lume ls --format=json | jq -r '.[]|select(.name=="macos-baseline").status')" = stopped ] && break
  sleep 5
done
[ "$(lume ls --format=json | jq -r '.[]|select(.name=="macos-baseline").status')" = stopped ] ||
  { echo "baseline never stopped; see ~/Library/Logs/lume/macos-baseline.log" >&2; exit 1; }
```

<!-- rumdl-enable MD013 -->

**The block is deliberately resumable.** If a step fails, fix the cause and continue from that step — do not tear the VM down. The create alone costs an 18 GB download and several minutes, and a half-built baseline is exactly what you want to debug against. The one thing that must not be left behind is the sudo grant, which is why step 5 verifies it rather than trusting step 4.

Refresh the toolchain later with `brew update && brew upgrade` **in the baseline, deliberately** — never in a run clone. Per-run upgrades make every run slow and, worse, non-reproducible: a failure then has two candidate causes, your workflow and today's Homebrew, and you cannot tell them apart. Re-create and re-remove the sudo grant the same way if a refresh needs it.

#### Then one throwaway clone per run

The run phase needs none of the apparatus above — no key, no `sshvm`, no TTY, no sudo. Plain `lume ssh <name> <command>` resolves the guest by name, which sidesteps the address lookup entirely.

<!-- rumdl-disable MD013 -->

```sh
# Teardown has to branch on state, because the two halves fail in opposite
# directions: `lume stop` HANGS on a VM that is not running, and
# `lume delete --force` FAILS on one that is.
lume_teardown() {
  if [ "$(lume ls --format=json | jq -r ".[]|select(.name==\"$1\").status")" = running ]; then
    lume stop "$1" || return 1   # a failed stop must not fall through to delete
  fi
  lume delete "$1" --force
}

lume clone macos-baseline macos-run                       # lume clone <name> <new-name>
lume run macos-run --display=none --detach --shared-dir "${PWD}:ro"

# Poll the FILESYSTEM, not the mount point: the mount point exists before it is
# mounted. Bounded at ~5 minutes, then fail legibly.
ok=""
for _ in $(seq 60); do
  lume ssh macos-run 'mount | grep -q AppleVirtIOFS' && { ok=1; break; }
  sleep 5
done
[ -n "$ok" ] || { echo "share never mounted" >&2; lume_teardown macos-run; exit 1; }

# Two things about this line. It is DOUBLE-quoted so ${PWD##*/} expands on the
# HOST -- lume names the mount point after the shared directory, so the copy
# source is one level down. And `act` carries the brew shellenv, because
# `lume ssh <name> <command>` is a non-login shell: without it you get
# `command not found: act` even though act is installed.
lume ssh macos-run "mkdir -p ~/work && cp -R '/Volumes/My Shared Files/${PWD##*/}/.' ~/work/ && cd ~/work && eval \"\$(/opt/homebrew/bin/brew shellenv)\" && act --job spec --platform macos-latest=-self-hosted --container-architecture darwin/arm64 --quiet"

lume_teardown macos-run
```

<!-- rumdl-enable MD013 -->

Three deliberate choices there, since each obvious shortcut gives something away:

- **`:ro`, not `:rw`.** With `-self-hosted` the job runs *in* the directory it is given, and this job writes: `actions/checkout` copies, Bundler populates `vendor/bundle`, act writes its own cache. A read-write share sends all of that back into your working tree through the mount — relocating the mess rather than preventing it, and leaving the isolation half done. Read-only plus a copy inside the guest keeps the host tree untouched. lume supports the tag natively (`path:ro`; a bare path means read-write).
- **A share at all, rather than cloning from GitHub inside the VM.** The whole reason to preflight locally is to exercise a workflow edit that is *not pushed yet* — a VM that cloned from the remote could only run what CI would already run for you. The share is how uncommitted work reaches the guest; `:ro` is how it does so safely.
- **An ephemeral clone per run, from a baseline you keep.** `lume delete` removes the disk, so without a baseline every run pays for the Homebrew install again. For fast iteration a `git reset --hard` inside the guest and a re-run is fine; prefer delete-and-reclone whenever the result matters, since a reused guest carries the previous run's Homebrew state and caches.

#### Verifying the whole flow end to end

One command that exercises everything the isolated path depends on — clone, boot, share, toolchain, `act`, teardown — and reports a single verdict. Run it after building a baseline, and again after any `brew upgrade lume`:

<!-- rumdl-disable MD013 -->

```sh
set -eu
# 0.5.0 cannot create a VM at all, so refuse rather than fail later.
v=$(lume --version)
case "$v" in
0.[0-4].* | 0.5.0 | 0.5.0-*) echo "lume $v is too old; 0.5.1 or newer required" >&2; exit 1 ;;
*) ;;
esac
[ "$(lume ls --format=json | jq -r '.[]|select(.name=="macos-baseline").status')" = stopped ] ||
  { echo "baseline is not stopped; shut it down first" >&2; exit 1; }
lsof ~/.lume/macos-baseline/nvram.bin >/dev/null 2>&1 &&
  { echo "something still holds the baseline's auxiliary storage; see the troubleshooting list" >&2; exit 1; }

lume_teardown() {
  if [ "$(lume ls --format=json | jq -r ".[]|select(.name==\"$1\").status")" = running ]; then
    lume stop "$1" || return 1
  fi
  lume delete "$1" --force
}
# Reports its own failures rather than swallowing them: a teardown that fails
# silently leaves a VM holding the auxiliary-storage lock against the next run.
# It does not mask the exit status of whatever actually failed.
trap 'rc=$?; lume_teardown macos-e2e || { echo "TEARDOWN FAILED: macos-e2e may still hold its lock" >&2; [ "$rc" -ne 0 ] || rc=1; }; exit $rc' EXIT

lume clone macos-baseline macos-e2e
lume run macos-e2e --display=none --detach --shared-dir "${PWD}:ro"

ip=""
for _ in $(seq 60); do
  ip=$(lume get --format=json macos-e2e | jq --raw-output '.[0].ipAddress // empty')
  [ -n "$ip" ] && break
  sleep 5
done
[ -n "$ip" ] || { echo "FAIL: no address; see ~/Library/Logs/lume/macos-e2e.log" >&2; exit 1; }

ok=""
for _ in $(seq 60); do
  lume ssh macos-e2e 'mount | grep -q AppleVirtIOFS' && { ok=1; break; }
  sleep 5
done
[ -n "$ok" ] || { echo "FAIL: share never mounted" >&2; exit 1; }

lume ssh macos-e2e 'eval "$(/opt/homebrew/bin/brew shellenv)" && act --version' ||
  { echo "FAIL: act missing from the baseline" >&2; exit 1; }
lume ssh macos-e2e "cp -R '/Volumes/My Shared Files/${PWD##*/}/.' ~/e2e/ 2>/dev/null || { mkdir -p ~/e2e && cp -R '/Volumes/My Shared Files/${PWD##*/}/.' ~/e2e/; }"
lume ssh macos-e2e 'ls ~/e2e/.github/workflows >/dev/null' ||
  { echo "FAIL: share copied to the wrong path -- check the mount layout" >&2; exit 1; }

echo "PASS: clone, boot, share, toolchain, and copy all work at $ip"
```

<!-- rumdl-enable MD013 -->

The `trap` is the point: every failure path still deletes the clone, so a failed verification does not leave a VM running and holding the auxiliary-storage lock against the next attempt.

#### Where the share mounts

`--shared-dir "${PWD}:ro"` surfaces the directory at **`/Volumes/My Shared Files/<basename of the source>`**, not at the volume root. lume derives that name from the shared path's last component, so a checkout at `~/src/widget` mounts at `/Volumes/My Shared Files/widget`.

Two guest-visible details follow from how lume builds the share. Every share is a `VZMultipleDirectoryShare` keyed by name (`createDirectoryShare` in `VMVirtualizationService.swift`), even when you pass one directory — that is where the subdirectory comes from, and a second `--shared-dir` simply adds a sibling. And the volume carries a hidden read-only `.lume-live-share` entry pointing at the host's `/var/empty`, which keeps the automount device populated so the native viewer's **Share Folder** action can replace the share while the guest runs. It is inert here, but it means the volume root is never only your files — so copy from the named subdirectory, never from `/Volumes/My Shared Files/.`.

The mount is recognizable by filesystem type, which is what the poll keys on:

```console
$ mount | grep -i virtio
/dev/disk0 on /Volumes/My Shared Files (AppleVirtIOFS, local, nodev, nosuid, automounted)
```

#### Display, detach, and the two ways to stop

**`lume run` opens a viewer by default**, and the default is the native window (`--display=native`). Automation must suppress it with `--display=none`. `--no-display` survives as a compatibility alias — the CLI metadata labels it exactly that — but `--display=none` is the spelling to write. VNC stays available in every display mode, and `lume attach <name>` opens a viewer against an already-running guest, which is the civilized way to look inside a VM a script started headless.

**`--detach` replaces the trailing `&`, but its PID is not a success signal.** It re-executes lume under `nohup` with the original arguments minus the detach options, prints the child's PID, and exits 0 — *before* the child has started the VM. A child that fails a second later leaves the parent's exit status at 0 and reports only to `~/Library/Logs/lume/<name>.log` (`--log-file` overrides). Always poll `lume get` for an address afterwards, as the baseline block does; never treat the PID line as "it started". It also does not imply a display mode, so pass `--display=none` alongside it.

**`stop` and `shutdown` are different tools**, and which one is right is not the obvious answer:

- **Run clones keep `stop`.** The disk is deleted seconds later, so a graceful guest unmount buys nothing and costs an SSH round trip. That is what `lume_teardown` calls.
- **The baseline gets `shutdown`.** It is the copy that gets kept and cloned, and the last thing it did was write a Homebrew tree — the one place a clean power-down is worth its cost. `shutdown` reaches the guest over SSH (`--user`/`--password` default to `lume`/`lume`, `--timeout` to 30 seconds), so it needs a guest that is actually up.

Neither replaces the state check: `lume delete --force` still fails against a running VM, and `lume stop` still hangs against a stopped one.

#### Why the sudo grant is temporary, and what it is worth

Diagnosed across runs on 2026-07-27. Homebrew's installer needs `sudo` several times; under `NONINTERACTIVE=1` it runs every one of them with `-n`, which **fails instead of prompting** whenever the cached credential has expired — and the Xcode Command Line Tools install in the middle of the script is long enough to outlive the default five-minute `timestamp_timeout`, sometimes. One run died at `sudo /bin/mkdir -p /etc/paths.d` after the CLT install; a later run on a faster path completed end to end from the identical command. **A one-shot `sudo --stdin --validate` before the installer is therefore a race, and a step that passes or fails with download speed must not be the recorded procedure.**

Dead ends, each closed by an actual run rather than by argument:

- **Running the installer under `sudo`** (or `sudo --shell`): refused by design — `Don't run this as root!`.
- **`chmod 4755 install.sh`**: the kernel ignores the setuid bit on interpreted scripts, so this changes nothing (verified: identical behavior) — and had it worked, see the previous bullet.
- **`sudo --validate <<< password`**: reads the terminal, not stdin, unless given `--stdin`. Fails immediately.
- **A TTY (`-o RequestTTY=force`)**: converts the mid-install failure into a mid-install *prompt*. Survivable when a human is watching, still not unattended.

Be clear-eyed about what the grant costs **in this guest**: the password is published (`lume`/`lume`), so anything running as the user can warm the cache itself with `echo lume | sudo --stdin --validate`. Password-gated sudo protects nothing here, and a `Defaults:lume timestamp_timeout=60` entry would be security-equivalent to `NOPASSWD`. The revocation, and the VM boundary itself, are the controls doing real work. Either way the entry is deleted before shutdown, which is what answers "a machine with a user who is always root-capable": after the build, no such machine exists.

#### When a lume command fails

- **`Invalid virtual machine configuration. Failed to lock auxiliary storage.`** A live process still holds the VM's `nvram.bin`, and lume's own bookkeeping can say `stopped` while it does — so `lume ls` will not reveal this. Note there are up to three PIDs in play and they are not interchangeable: `lume run --detach` prints the PID of the *lume* process, the aux-storage holder is its child `com.apple.Virtualization.VirtualMachine` (one higher, in every observation so far), and `lume stop` reports the holder of the *config-file* lock, a third thing. `pgrep` is useful for surveying them, but pattern it carefully — a bare `pgrep -f lume` matches Safari, because its bundle path contains `/System/Volumes/`. Use `pgrep -fl /lume` and read the output. For "who holds this exact file", `lsof` is definitive:

  ```sh
  lsof ~/.lume/<name>/nvram.bin        # names the PID holding the lock
  kill -TERM <pid>                     # TERM, never -9: it also holds disk.img
  ```

  A `--detach` fired immediately after `lume create` races the create flow's own helper and fails this way while printing a PID and exiting 0. If the guest is genuinely running, stop it with `lume stop` instead; reach for `kill` only when `lume ls` says the VM is stopped and `lsof` still names a holder. Note also that the `Started … (PID n)` line goes to the parent's stdout and is never written to the log file, so a log that appears to lack it is complete, not truncated.
- **`CancellationError` during `lume create`.** Printed as `ERROR: Failed in VM.run … Swift.CancellationError`, immediately followed by `VM stopped successfully`. It is the unattended setup stopping the VM it started, twice, by design. Benign — the line to check is `Provisioning marker cleared`, which means the create completed.
- **`lume create` traps on 0.5.0 specifically.** Every macOS install died at `_dispatch_assert_queue_fail` inside `-[VZMacOSInstaller initWithVirtualMachine:restoreImageURL:]`: the 0.5.0 native-display work moved the VM onto a private serial queue but left `installMacOS` constructing the installer on the main actor, and Apple asserts the two match. Reported as [trycua/cua#2670](https://github.com/trycua/cua/issues/2670) and fixed in 0.5.1. The last log line before the trap names the hardware model, which is a red herring — the crash report in `~/Library/Logs/DiagnosticReports/lume-*.ips` names the real frame. Upgrade rather than working around it.
- **A trapped or interrupted create leaves scratch state.** `~/.lume/<UUID>/` directories, sparse and about 20 KB allocated, which `lume ls` reports as stopped VMs because listing enumerates directories under the storage root. `lume delete <UUID> --force` clears them when nothing is running; there is no separate index to fall out of step.
- **`command not found: act` (or `brew`) over ssh, on a guest where both are installed.** Expected, and not a broken install. `ssh host command` and `lume ssh <name> <command>` both run a **non-login, non-interactive** shell, which reads neither `~/.zprofile` nor `/etc/paths.d` — the two mechanisms Homebrew's installer uses to put `/opt/homebrew/bin` on `PATH`. So every remote command that needs brew or a brew-installed tool must carry `eval "$(/opt/homebrew/bin/brew shellenv)"` inline, which is why the blocks above all do. An interactive `ssh` into the guest gets a login shell and finds them normally, so the difference is easy to misread as "it works when I look, and breaks when I script it."
- **`lume shutdown` returns before the VM has stopped.** It prints `Graceful shutdown requested` and exits 0 immediately, so a chained `lume shutdown X && lume delete X --force` fails with `Cannot modify X: the VM is running. Stop it first.` Poll `lume ls` until the status reads `stopped`, or use `lume stop` when you do not need the graceful path — that is why `lume_teardown` calls `stop`. A related trap: `lume stop` logs `Found process N holding lock on config file`, and that PID is **not** the one holding the auxiliary storage — the config-file lock and the aux-storage lock are different locks held by different processes. `kill` on it can answer `no such process` if it has already exited between lume's report and your command. Do not treat it as the aux-storage holder; check `lume ls` for the state and `lsof` for the file.
- **`$ip` goes stale.** A deleted and re-created VM comes up on a new address, and the unattended setup stops the VM when it finishes — so an `ssh … Operation timed out` right after `lume create` usually means "not started, and your captured address belongs to the previous VM." Re-capture after every create, clone, or run.
- **The `.resize.guard` dotfiles are inert; leave them alone.** `~/.lume/.<name>.resize.guard` is an **flock target**, not a state marker (`VMDirectory.swift`: `tryAcquireResizeGuard` creates the file if missing, then takes a non-blocking `flock()`), and a running VM holds that lock for its lifetime. The lock dies with its holder, so the file legitimately persists between runs; a separate transaction marker (`hasResizeMarker`) records a real resize. Deleting a guard never helps, and while any lume process is live it defeats the lock outright: `flock` binds to the open file, so after an unlink the next operation recreates the guard as a new inode and locks *that*. Through 0.4.0 this surfaced as a misleading error — `lume delete --force` against a running VM reported `A previous disk resize … did not finish` even when no resize was ever requested. [trycua/cua#2491](https://github.com/trycua/cua/issues/2491), fixed in 0.5.0: a running VM now reads `Cannot modify <name>: the VM is running. Stop it first.`
- **"Warning: Permanently added … to the list of known hosts" on every `sshvm` call is expected.** `UserKnownHostsFile=/dev/null` means each connection starts with an empty database, accepts the key, and "permanently" records it in `/dev/null`. `-o LogLevel=ERROR` silences it without hiding real errors.
- **Chaining `sshvm` calls inside one single-quoted argument breaks in the host's shell.** A nested `'…'` closes the outer quote, so the middle section expands locally — which is how `zsh: no such file or directory: /home/linuxbrew/.linuxbrew/bin/brew` appeared. Where a command genuinely must be one unit, write it to a file and pipe it in rather than nesting quotes.
- **TCC blocks sshd from `~/Downloads`, `~/Documents`, `~/Desktop`.** `ls` over ssh returns `Operation not permitted` even under sudo, because the privacy prompt that would grant Full Disk Access has no way to appear. Work in `~` or `~/work`.
- **There is no quiet flag**; every command narrates at INFO. Filter with `grep -v '^\['` where it matters. `lume dump-docs --type=cli` emits every command, option, flag, default, and help string as JSON, which beats reading `--help` to confirm a flag exists. Commands that touch the native display also print a couple of `Connection invalid` / `com.apple.hiservices-xpcservice` lines on stderr, including under `--display=none`; they are noise.
- **Do not hand-clone with `cp -c` instead of `lume clone`.** The clone is already copy-on-write — 27 GB of allocated image cloned in about two seconds — and `lume clone` regenerates the VM's identity: the cloned `config.json` carries a fresh `macAddress` *and* `machineIdentifier`. A `clonefile(2)` copy would duplicate both onto the same NAT segment.
- **`--cpu`/`--memory` exist on `create`** (defaults 4 cores / 8 GB; clones inherit). The defaults are right for the baseline build and fine for run clones; trim a clone's memory only if the host is under pressure, not on principle.

#### Networking, and one loose end

Outbound HTTP works from the guest under the default NAT:

```console
$ curl --ipv4 --fail --silent --show-error --head https://example.com
HTTP/2 200
```

**`ping` is not a connectivity test here.** Apple's `vmnet` NAT does not forward ICMP echo, so 100% loss to `1.1.1.1` is expected and says nothing. Test TCP. The one unexplained observation is a `curl: (56) … 404` fetching `raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` at a moment when DNS was resolving normally; a 404 is an HTTP-layer answer, so the request reached *something*. It has not recurred. If it returns, `curl --ipv4 --verbose --silent --show-error --output /dev/null <url> 2>&1 | tail -30` shows which address answered.

**Bridged networking is unavailable on the Homebrew build**, which matters because it would sidestep the NAT stack entirely. [homebrew-core#269744](https://github.com/Homebrew/homebrew-core/pull/269744) added a signed bundle to the formula but not this capability — checked on the installed binary:

```console
$ codesign -d --entitlements - "$(brew --cellar lume)/0.5.1/libexec/lume"
[Dict]
	[Key] com.apple.security.virtualization
	[Value]
		[Bool] true
```

`com.apple.vm.networking` is absent. The formula signs with `resources/lume.local.entitlements` to "Avoid SIGKILL with ad-hoc signing", and `com.apple.vm.networking` is a **restricted** entitlement Apple honors only under a provisioning profile, which an ad-hoc signature cannot carry. Structural to Homebrew builds rather than an oversight a formula patch can close, consistent with [trycua/cua#1133](https://github.com/trycua/cua/issues/1133) remaining open. Reinstalling lume from the official installer stays the prerequisite for `--network bridged`.

#### Alternatives, weighed

[Tart](https://github.com/cirruslabs/tart) is the automation-native comparison (COW clones, registry images, built for macOS CI), but it has no equivalent of lume's offline unattended setup: its answer to "where does a ready guest come from" is prebuilt images pulled from a registry, trading the provenance of building locally from an Apple restore image for trust in a third party's image — and its Fair Source license needs reading besides. VirtualBuddy is GUI-first, the wrong shape for a scripted flow. lume's IPSW-plus-offline-preset path is the differentiator that fits here.

## The `ubuntu-latest` jobs

Structure validation always works, for any job:

```sh
act --job vale --dryrun
act --job vale --validate
```

The brew-install jobs also run — with **native arm64** and the **full** image:

```sh
act --job vale \
  --platform ubuntu-latest=catthehacker/ubuntu:full-latest \
  --container-architecture linux/arm64 \
  --container-daemon-socket=-
```

Verified: this pours Homebrew's `arm64_linux` bottle for vale and the job passes. Three things have to line up, and each was a failure mode along the way:

- **`full-latest`, not the default medium image.** `catthehacker/ubuntu:act-latest` has no Linuxbrew — `/home/linuxbrew/.linuxbrew/bin/brew: No such file or directory`. Override the actrc default on the command line.
- **`linux/arm64` (native), not `linux/amd64` (emulated).** Under emulated x86_64 the CPU lacks SSSE3, which Homebrew's x86_64-Linux bottles require (`Homebrew's x86_64 support on Linux requires a CPU with SSSE3 support!`). Native arm64 has `arm64_linux` bottles and no emulation, so it is correct and fast. (`linux/aarch64` is accepted as an alias.)
- **Disk.** `full-latest` is >18 GB compressed and much larger extracted, into the Colima VM's disk — a sparse file bounded by host free space. A near-full host fails mid-extract with `no space left on device` under `/var/lib/containerd/…` (the `.NET` file in that error is incidental; the image bundles the whole runner toolchain including a multi-GB .NET SDK). Inspect usage first with `docker system df`; keep several tens of GB free. `docker system prune -af` reclaims space but is **destructive** — it removes *all* unused images, containers, networks, and build cache in the **active** Docker context, so confirm the context (`docker context show`) and prefer targeted removal (`docker image rm catthehacker/ubuntu:full-latest`) when you only mean to drop the big image.

## Recommendation

- **Structure** — `--dryrun`/`--validate` on any workflow you edit; the fastest check.
- **The macOS `spec.yml` job** — `--platform macos-latest=-self-hosted`, run for real on the host.
- **The brew-heavy `ubuntu-latest` jobs** — they run, with native arm64 + `full-latest`; use this when you want the real workflow (setup, `brew install`, caching) exercised end to end. For a quick pass the native gates are lighter — the "Build, test, and lint" block in `AGENTS.md` is what those jobs run — so reach for `act` when the *workflow* is what you're verifying, not just the tools.
