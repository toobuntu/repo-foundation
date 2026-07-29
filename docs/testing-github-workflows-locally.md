<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Testing GitHub workflows locally

[`act`](https://github.com/nektos/act) runs GitHub Actions workflows locally, before a push, so a workflow edit can be checked without burning a CI round-trip. It is a developer tool, never part of CI itself. This page records what works for this organization's workflows on an Apple-silicon Mac with Colima, verified by running them, and what each flag is for — because the flags are hard to discover. The page is canonical, synced from repo-foundation: the job names in the examples are the synced org workflows, present in every consumer unless marked otherwise, and the transcripts were recorded in repo-foundation, the hub.

## Quick reference

Copy-paste forms for the common cases. Everything below is explained in the sections that follow.

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

**The `macos-latest` job (`spec.yml`)** needs no Docker and no Colima at all — it runs on the host. That means a real `brew install` and Ruby setup against your actual Mac, so the isolated form runs it inside a throwaway lume VM instead:

```sh
# On the host — fast, and the only form verified end to end. It touches the
# host: a real brew install, a real Ruby setup, and the suite runs in this
# checkout.
act --job spec --platform macos-latest=-self-hosted \
  --container-architecture darwin/arm64 --quiet

# Isolated in a lume VM — the host stays untouched. Needs a prepared,
# STOPPED baseline; building that is the one-time part, in the lume section.
# Plain `lume ssh` here, no options: the run phase needs no sudo and no key.
# The last command is DOUBLE-quoted so ${PWD##*/} expands on the host: lume
# names the share's mount point after the shared directory. See below.
lume_teardown() {   # defined inline so this block is self-contained
  if [ "$(lume ls --format=json | jq -r ".[]|select(.name==\"$1\").status")" = running ]; then
    lume stop "$1" || return 1   # a failed stop must not fall through to delete
  fi
  lume delete "$1" --force
}

lume clone macos-baseline macos-run                    # lume clone <name> <new-name>
lume run macos-run --display=none --detach --shared-dir "${PWD}:ro"
ok=""; for _ in $(seq 60); do   # bounded: ~5 min, then fail legibly
  lume ssh macos-run 'mount | grep -q AppleVirtIOFS' && { ok=1; break; }; sleep 5
done
[ -n "$ok" ] || { echo "share never mounted" >&2; lume_teardown macos-run; exit 1; }
lume ssh macos-run "mkdir -p ~/work && cp -R '/Volumes/My Shared Files/${PWD##*/}/.' ~/work/ && \
  cd ~/work && act --job spec --platform macos-latest=-self-hosted \
    --container-architecture darwin/arm64 --quiet"
lume_teardown macos-run                                # stop-if-running, then delete
```

**Leaving Colima up** between runs is fine and saves the boot; `colima stop` is for reclaiming the VM's memory. `--pull=false` after the first run skips the image check.

`NOASSERTION` in the validate and dryrun forms is deliberate, not a placeholder: any non-empty `--container-architecture` value silences the M-series warning, and the value is unused when no container starts. A real run needs a real platform — `linux/arm64` here.

## Setup

```sh
brew install act colima docker      # core: everything except the lume VM path
colima start                        # boots a Linux VM (Lima) that speaks the Docker API

brew install lume jq                # only for "Isolating it in a VM (lume)" below
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
| `--pull=false` | Reuse an already-pulled image. | After the first (slow) pull. |

A `~/.actrc` (or `~/Library/Application Support/act/actrc`) holds machine defaults; act ships one mapping `ubuntu-latest` to the medium `act-latest` image. This repo commits no `.actrc` — the useful flags describe your Colima and arch, not the project.

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

`-self-hosted` runs the job on your real Mac, so its `brew install` and Ruby setup touch the host. To isolate it, run the job inside a throwaway macOS VM with [lume](https://github.com/trycua/lume) (Apple's Virtualization.framework). lume's telemetry is on by default (pseudonymous install/usage metadata only — no names, paths, or VM contents); turn it off once with `lume config telemetry disable`.

> **Status: `lume create` is broken in lume 0.5.0 — you cannot build a baseline on it today.** Every macOS create from an IPSW traps in Apple's `VZMacOSInstaller`; the diagnosis is under *Baseline blocker: `lume create` traps on 0.5.0* below, along with what still works. The rest of this section is written for 0.5.0's syntax and is correct for an existing VM.
>
> The **baseline build** was verified end to end on 2026-07-27 (maintainer-run, lume 0.4.0): create, run, key install, build-time sudo grant, Homebrew install, revoke, `brew install act` executed top to bottom. The commands below are 0.5.0's, which renamed one flag, added another, and **changed where a shared directory lands in the guest**; the share path and the two flags are read from the 0.5.0 source and CLI metadata, so the first run that gets that far should check the guest layout before trusting the `cp`. Every non-lume section on this page is unaffected.

**Build the baseline once.** A vanilla image has no Homebrew, so the toolchain install is the slow part; do it once and keep the result as a template you never run jobs in.

<!-- rumdl-disable MD013 -->

```sh
# Create a vanilla macOS VM. `--ipsw latest` downloads the ~18 GB restore image.
# If you'll recreate VMs repeatedly, download the image once and reuse it instead.
#
#  IPSW_URL="$(lume ipsw | tail -n 1)"
#  curl -fL -o ~/Downloads/macos-tahoe.ipsw "$IPSW_URL"
#
# Then replace `--ipsw latest` below with:
#
#  --ipsw ~/Downloads/macos-tahoe.ipsw
#
# The tahoe preset creates the lume user (login lume / lume) and enables SSH,
# autologin, and no-sleep/no-lock.
lume create macos-baseline --ipsw latest --unattended tahoe

# `--display=none` suppresses the viewer, not the VM: lume 0.5.0 opens a native
# window by default, and VNC stays available in every display mode. `--detach`
# returns immediately with a PID and logs to ~/Library/Logs/lume/<name>.log.
# The unattended setup STOPS the VM when it finishes, so run it before trying
# to reach it. (Options may go on either side of the name.)
lume run macos-baseline --display=none --detach
```

<!-- rumdl-enable MD013 -->

The install sequence itself — key, temporary sudo grant, Homebrew, act, revoke — is under *Baseline blocker: `sudo`, resolved* below, with the reasoning; it is the part that took three runs to get right, and the shape matters more than any single line.

Each `sshvm` is its own invocation on purpose. Chaining them inside one single-quoted argument is what produced this, in the *host's* shell rather than the guest's:

```text
zsh: no such file or directory: /home/linuxbrew/.linuxbrew/bin/brew
```

A nested `'…'` inside a single-quoted string closes the outer quote, so the middle section is expanded locally before `lume ssh` ever runs. Where a command genuinely must be one unit, write it to a file and pipe it in rather than nesting quotes.

Homebrew's environment file is worth seeding in the baseline too — it is read by every later `brew` call:

<!-- rumdl-disable MD013 -->

```sh
sshvm 'mkdir -p ~/.homebrew && cat >> ~/.homebrew/brew.env <<EOF
HOMEBREW_NO_ANALYTICS=1
HOMEBREW_NO_ASK=1
HOMEBREW_NO_UPDATE_REPORT_NEW=1
HOMEBREW_DISPLAY_INSTALL_TIMES=1
EOF'
```

**Then one ephemeral clone per run**, sharing the checkout **read-only**:

```sh
lume_teardown() {   # defined inline so this block is self-contained
  if [ "$(lume ls --format=json | jq -r ".[]|select(.name==\"$1\").status")" = running ]; then
    lume stop "$1" || return 1   # a failed stop must not fall through to delete
  fi
  lume delete "$1" --force
}

lume clone macos-baseline macos-run                       # lume clone <name> <new-name>
lume run macos-run --display=none --detach --shared-dir "${PWD}:ro"

# Copy the read-only share to a writable path INSIDE the guest, then run there.
# Poll the FILESYSTEM, not the mount point, and bounded -- see below.
ok=""; for _ in $(seq 60); do   # bounded: ~5 min, then fail legibly
  lume ssh macos-run 'mount | grep -q AppleVirtIOFS' && { ok=1; break; }; sleep 5
done
[ -n "$ok" ] || { echo "share never mounted" >&2; lume_teardown macos-run; exit 1; }
lume ssh macos-run "mkdir -p ~/work && cp -R '/Volumes/My Shared Files/${PWD##*/}/.' ~/work/ && cd ~/work && act --job spec --platform macos-latest=-self-hosted --container-architecture darwin/arm64 --quiet"

lume_teardown macos-run                                   # stop-if-running, then delete
```

<!-- rumdl-enable MD013 -->

**Ordinary act runs need none of the ssh apparatus above.** `sshvm`, the dedicated key, `RequestTTY`, and the sudo grant are all *baseline-build* machinery. The run phase uses plain `lume ssh <name> <command>` with no options at all, because nothing in `cp -R && act` needs `sudo` — so the missing TTY never bites — and `lume ssh` resolves the guest by name, which sidesteps an address lookup entirely.

That last point is a trap worth naming, since the helper invites it: **`sshvm` is pinned to `$ip`, which holds the *baseline's* address.** Reusing it against `macos-run` reaches the wrong VM, or times out when the baseline is stopped. If you do want the system client for a run — to pass `-o` options, say — re-capture first:

```sh
ip=$(lume get --format=json macos-run | jq --raw-output '.[0].ipAddress')
```

Three deliberate choices in the run block, since the obvious shortcuts each give something away:

- **`:ro`, not `:rw`.** With `-self-hosted` the job runs *in* the directory it is given, and this job writes: `actions/checkout` copies, Bundler populates `vendor/bundle`, act writes its own cache. A read-write share sends all of that back into your working tree through the mount — which relocates the mess rather than preventing it, and leaves the VM's only real job half done. Read-only plus a copy inside the guest keeps the host tree untouched. lume supports the tag natively (`path:ro`; a bare path means read-write).
- **A share at all, rather than cloning from GitHub inside the VM.** The whole reason to preflight locally is to exercise a workflow edit that is *not pushed yet* — if the VM cloned from the remote it could only run what CI would already run for you, and you may as well push. The share is how uncommitted work reaches the guest; `:ro` is how it does so safely.
- **An ephemeral clone per run, from a baseline you keep.** `lume delete` removes the disk, so without a baseline every run pays for the Homebrew install again.

On updating the toolchain: do `brew update && brew upgrade` **in the baseline, deliberately**, not in each ephemeral clone. Per-run upgrades make every run slow and, worse, non-reproducible — a failure then has two candidate causes, your workflow and today's Homebrew, and you cannot tell them apart. Refresh the baseline when you mean to, and note when you did.

For fast iteration a `git reset --hard` in the guest and a re-run is fine; prefer the delete-and-reclone cycle whenever the result matters, since a re-used guest carries the previous run's Homebrew state and caches.

The VM is the isolation boundary — the `brew install` and Ruby setup happen inside it, and your real Mac is untouched. (The share mounts one level down, under a directory named for the source — see below.)

### The share mounts under a directory named for the source

`--shared-dir "${PWD}:ro"` surfaces the directory at **`/Volumes/My Shared Files/<basename of the source>`**, not at the volume root. lume derives that name from the shared path's last component, so a checkout at `~/src/widget` mounts at `/Volumes/My Shared Files/widget`:

```sh
mkdir -p ~/work && cp -R "/Volumes/My Shared Files/${PWD##*/}/." ~/work/
```

That is why the guest command in the run block is double-quoted: `${PWD##*/}` has to expand on the *host*, which knows the source path, before `lume ssh` hands the rest to the guest.

Two guest-visible details follow from how lume builds the share, and both are easier to recognize than to rediscover. Every share is a `VZMultipleDirectoryShare` keyed by name (`createDirectoryShare` in `VMVirtualizationService.swift`), even when you pass one directory — that is where the subdirectory comes from, and passing a second `--shared-dir` simply adds a sibling. And the volume also carries a hidden read-only `.lume-live-share` entry pointing at the host's `/var/empty`: it keeps the automount device populated so the native viewer's **Share Folder** action can replace the share while the guest runs. It is inert for this flow, but it means the volume root is never empty and is never only your files — so copy from the named subdirectory, not from `/Volumes/My Shared Files/.`.

Poll for the filesystem rather than the directory, since the mount point exists before it is mounted. (Plain stop-then-delete on failure here, not `lume_teardown`: this snippet stands alone, and the VM is known to be running at this point, which is the one state where a bare `lume stop` is safe.)

```sh
ok=""; for _ in $(seq 60); do   # bounded: ~5 min, then fail legibly
  lume ssh macos-run 'mount | grep -q AppleVirtIOFS' && { ok=1; break; }; sleep 5
done
[ -n "$ok" ] || { echo "share never mounted" >&2; lume stop macos-run; lume delete macos-run --force; exit 1; }
```

The mount itself is recognizable by filesystem type, which is what the poll keys on:

```console
$ mount | grep -i virtio
/dev/disk0 on /Volumes/My Shared Files (AppleVirtIOFS, local, nodev, nosuid, automounted)
```

### Baseline blocker: `lume create` traps on 0.5.0

Reproduced twice on 2026-07-28, lume 0.5.0 (Homebrew), macOS 26.5.2 (25F84). `lume create … --ipsw latest --unattended tahoe` downloads the restore image, then dies:

```console
[…] INFO: Pre-VZMacHardwareModel: hardwareModel=132 bytes
zsh: trace trap  lume create macos-baseline --ipsw latest --unattended tahoe
```

**That last log line is a red herring.** Both `VZMacHardwareModel(dataRepresentation:)` call sites use `guard let … else { throw }`, so a bad hardware model would surface as a clean error. The crash report names the real frame — `EXC_BREAKPOINT`, in `~/Library/Logs/DiagnosticReports/lume-*.ips`:

```text
_dispatch_assert_queue_fail
dispatch_assert_queue
-[VZMacOSInstaller initWithVirtualMachine:restoreImageURL:]
closure #1 in closure #1 in DarwinVirtualizationService.installMacOS(imagePath:progressHandler:)
```

Apple requires every call against a `VZVirtualMachine` to run on the queue passed at construction. The 0.5.0 native-display work moved the Darwin VM off the main queue onto a private serial queue and added a `VirtualMachineHandle` so that `start`, `stop`, and the state reads all go through `handle.queue`. `installMacOS` is the one call site that was not converted: it still builds `VZMacOSInstaller` inside a bare `Task`, which inherits the service's `@MainActor` and therefore runs on the main queue. The installer's initializer asserts otherwise, and a failed dispatch assertion is a trap, not a catchable error. Before that change the VM was created with `VZVirtualMachine(configuration:)`, whose queue *defaults* to the main queue — which is why the identical code worked on 0.4.0.

So the blast radius is exactly the install path. Running, stopping, cloning, sharing, and deleting an already-built VM are unaffected, because those were converted. Until it is fixed upstream, the options are to stay on lume 0.4.0, to build lume from source with the installer wrapped in `handle.queue.async`, or to `lume pull` a prebuilt image from the registry — which works, but trades the provenance of building locally from an Apple restore image for trust in a third party's image, the same trade this page declines when it weighs Tart.

Two practical notes from the failed runs. `--ipsw latest` re-downloads all ~18 GB every time and leaves it in `$TMPDIR` (`/var/folders/…/T/latest.ipsw`), where macOS's tmp reaper will eventually take it: move that file somewhere durable and pass it by path, which is what the create block already recommends. And a trapped create leaves its scratch VM directory behind under `~/.lume/<UUID>/` — sparse, about 20 KB allocated, but it accumulates and `lume ls` reports each one as a VM.

### Baseline blocker: `sudo`, resolved

Diagnosed across runs on 2026-07-27, lume 0.4.0 (Homebrew), `tahoe` preset, NAT. The short version: Homebrew's installer needs `sudo` several times; under `NONINTERACTIVE=1` it runs every one of them with `-n`, which **fails instead of prompting** whenever the cached credential has expired; and the Xcode Command Line Tools install in the middle of the script is long enough to outlive the default five-minute `timestamp_timeout` — sometimes. One run died at `sudo /bin/mkdir -p /etc/paths.d` after the CLT install; a later run on a faster path completed end to end from the identical command. **A one-shot `sudo --stdin --validate` before the installer is therefore a race, and a step that passes or fails with download speed must not be the recorded procedure.**

Dead ends, each closed by an actual run rather than by argument:

- **Running the installer under `sudo` (or `sudo --shell`)**: refused by design — `Don't run this as root!`.
- **`chmod 4755 install.sh`**: the kernel ignores the setuid bit on interpreted scripts, so this changes nothing (verified: identical behavior) — and had it worked, see previous bullet.
- **`sudo --validate <<< password`**: reads the terminal, not stdin, unless given `--stdin`. Fails immediately.
- **A TTY (`-o RequestTTY=force`)** only converts the mid-install failure into a mid-install *prompt* — survivable when a human is watching, still not unattended.

**The resolution: a temporary sudoers entry that exists only while the baseline is being built, removed before the VM is ever cloned.** This also answers the standing-root concern directly — `act` itself never needs `sudo`, so the run clones carry **no** grant at all, and the window in which the guest account is passwordless-root is the same window in which the only thing running is Homebrew's installer:

<!-- rumdl-disable MD013 -->

```sh
ip=$(lume get --format=json macos-baseline | jq --raw-output '.[0].ipAddress')
sshvm() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o RequestTTY=force -o IdentitiesOnly=yes -i "$VMKEY" lume@"$ip" "$@"; }

# A dedicated VM key, named per the org's key schema
# (PURPOSE_SCOPE_YM_ALGO--ID, comment PURPOSE:SCOPE:ID). Generate once and
# reuse for every baseline; -N '' is deliberate, see below.
YM=$(date +%Y-%m)
ID="user:<you>+${YM}@<example.com>"
VMKEY=~/.ssh/auth_lume_${YM}_ed25519--${ID}
ssh-keygen -t ed25519 -a 100 -N '' -q -f "$VMKEY" -C "auth:lume:${ID}"
chmod 600 "$VMKEY"

# Install it so ssh itself stops prompting. -i names ONE key: without it,
# ssh-copy-id installs EVERY public key currently in the agent (ssh-add -L).
ssh-copy-id -i "${VMKEY}.pub" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null lume@"$ip"

# Temporary build-time grant. Written to a TEMP file and validated there,
# because visudo -cf on an already-installed file validates too late: a
# malformed entry is in /etc/sudoers.d the moment tee returns, and a bad file
# there can lock sudo out of the guest entirely. install(1) does the move
# with the right mode in one step, and only if validation passed.
sshvm 'set -eu; echo lume | sudo --stdin --validate
  printf "lume ALL=(ALL) NOPASSWD: ALL\n" > /tmp/baseline-build
  sudo visudo -cf /tmp/baseline-build
  sudo install -m 440 -o root -g wheel /tmp/baseline-build /etc/sudoers.d/baseline-build
  rm -f /tmp/baseline-build'

# The slow install, now raceless: no credential cache to expire. NOTE this
# executes remote code fetched at run time from a mutable ref (Homebrew's
# documented entry point is HEAD; there is no released installer tag to pin).
# That is acceptable HERE and only here: a disposable guest, on a private NAT,
# whose root grant is revoked in the next command. Do not lift this line into
# a context where any of those three stops being true.
sshvm 'NONINTERACTIVE=1 /bin/bash -c "$(curl --fail --silent --show-error --location https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

# Revoke IMMEDIATELY: the grant existed strictly for install.sh. Everything
# after this point is sudo-free -- pouring a bottle needs no root (verified:
# `brew install act` ran clean after the revoke). Confirm the removal rather
# than assuming it: a baseline cloned with the grant still in place would
# propagate it to every run clone.
sshvm 'sudo rm -f /etc/sudoers.d/baseline-build; ! test -e /etc/sudoers.d/baseline-build && echo "grant revoked"'

sshvm 'echo "eval \"\$(/opt/homebrew/bin/brew shellenv)\"" >> ~/.zprofile'
sshvm 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew install act'

# `shutdown`, not `stop`: this is the copy that gets kept and cloned, and it
# has just written a Homebrew tree. `shutdown` powers the guest down over SSH;
# `stop` is the immediate process-level stop, which is right for the throwaway
# run clones and wrong here.
lume shutdown macos-baseline
```

<!-- rumdl-enable MD013 -->

Three behaviors of that helper worth knowing rather than rediscovering:

- **"Warning: Permanently added … to the list of known hosts" on every call is expected**, not a fault: `UserKnownHostsFile=/dev/null` means each connection starts with an empty database, accepts the key, and "permanently" records it in `/dev/null`. `-o LogLevel=ERROR` (now in the helper) silences it without hiding real errors.
- **`brew` is "not found" in `sshvm` commands even after the `.zprofile` line — by design.** `ssh host command` runs a non-login, non-interactive shell, which reads neither `~/.zprofile` nor `/etc/paths.d` (both are login-shell mechanisms). That is why every `brew` call here carries the inline `eval "$(/opt/homebrew/bin/brew shellenv)"`. An interactive `ssh` gets a login shell and finds `brew` on `PATH` normally.
- **Use a dedicated per-VM key**, installed with `ssh-copy-id -i`: without `-i` it installs **every** public key in the agent (two landed here on the first attempt). `-o IdentitiesOnly=yes` stops the client offering agent keys in the other direction. Three notes on the generation above: the empty passphrase (`-N ''`) is deliberate and confined — the key opens only disposable guests on a private NAT, is never added to the agent, and a passphrase would reintroduce exactly the interactive prompt this section exists to remove; `-a 100` is kept for consistency with the schema even though it only affects passphrase encryption and is therefore inert here; and the memorable-suffix iteration the schema describes is skipped, since that ritual serves keys whose fingerprint you eyeball when pasting into a web UI, and this one is only ever named by path.

The alternative shape — a `Defaults:lume timestamp_timeout=60` entry instead of `NOPASSWD` — trades "no password needed" for "one password entry whose grace covers the install," and is equally valid; it matters only if something else could run in the guest during the build window, which nothing does. Be clear-eyed about what either buys **in this guest**: the password is published (`lume`/`lume`), so anything running as the user can warm the cache itself with `echo lume | sudo --stdin --validate` — password-gated sudo protects nothing here, and the two shapes are security-equivalent. The revocation, and the VM boundary itself, are the controls doing real work; the timeout variant is genuinely tighter only where the password is secret. Either way the entry is deleted before `lume stop`, which is the part that answers "a machine with essentially a user who is always root-capable": after the build, no machine like that exists. Later baseline refreshes (`brew update && brew upgrade` in the baseline, deliberately, never in clones) re-create and re-remove the entry the same way.

Incidental findings from the same runs, each of which costs real time to rediscover:

- **Teardown has to branch on state, because both halves fail in opposite directions.** `lume stop` on a VM that is *not* running can hang — it reports `Found process N holding lock on config file` and blocks indefinitely, taking the rest of a `;`-chained command with it. It is not idempotent either: repeated stops each "find" a fresh PID (its own probe) and hang again. `stopVM` has no running-state guard in 0.5.0, so this is current, not historical. And `lume delete --force` on a VM that *is* running fails — see the guard bullet below. So check first:

  ```sh
  lume_teardown() {
    if [ "$(lume ls --format=json | jq -r ".[]|select(.name==\"$1\").status")" = running ]; then
      lume stop "$1" || return 1   # a failed stop must not fall through to delete
    fi
    lume delete "$1" --force
  }
  ```

- **The `.resize.guard` dotfiles are inert; leave them alone.** `~/.lume/.<name>.resize.guard` is an **flock target**, not a state marker (`VMDirectory.swift`: `tryAcquireResizeGuard` creates the file if missing, then takes a non-blocking `flock()`), and a running VM holds that lock for its lifetime. The lock dies with its holder, so the file legitimately persists between runs; a separate transaction marker (`hasResizeMarker`) is what records a real resize. Deleting a guard never helps, and while any lume process is live it defeats the lock outright: `flock` binds to the open file, so after an unlink the next operation recreates the guard as a new inode and locks *that*, and two processes can then each hold "the" lock. Through 0.4.0 this surfaced as a genuinely misleading error — `lume delete --force` against a running VM reported `A previous disk resize … did not finish. Re-run the same command to roll it back…` even when no resize was ever requested, because guard contention raised `DiskResizeError.resizeInProgress` rather than the `.vmRunning` case that already existed. [trycua/cua#2491](https://github.com/trycua/cua/issues/2491), fixed in 0.5.0: contention is now classified by the transaction marker, so a running VM reads `Cannot modify <name>: the VM is running. Stop it first.` The operation still fails either way, which is why `lume_teardown` branches on state. The disk itself is a sparse image at the configured size — 100 GiB apparent, a fraction allocated — and lume's resize is increase-only and requires a stopped VM.
- **`$ip` goes stale.** A deleted and re-created VM comes up on a new address (`…64.3` → `…64.4` here), and the unattended setup **stops the VM when it finishes** — so an `ssh … Operation timed out` right after `lume create` usually means "not started, and your captured address is last VM's." `lume run` first, then re-capture `ip=` after every create, clone, or run.
- **`ssh-copy-id` with no `-i` installs every key in the agent** — two landed here. Public halves only, so nothing secret reaches the guest; still, name one key explicitly, or keep a dedicated throwaway pair for VMs.
- **TCC blocks sshd from `~/Downloads`, `~/Documents`, `~/Desktop`** — `ls` over ssh returns `Operation not permitted` even under sudo, because the privacy prompt that would grant Full Disk Access has no way to appear. Work in `~` or `~/work` over ssh.
- **`--ipsw latest` downloads the restore image itself** (~18 GB), so the separate `curl` is optional: keep the local `.ipsw` when you expect to rebuild baselines, use `latest` when you do not.
- **Telemetry defaults to ON — disable it once** (`lume config telemetry disable`; `lume config get` shows the current state). Same stance as `HOMEBREW_NO_ANALYTICS=1` in the org's `brew.env`: pseudonymous or not, analytics from dev tooling is opted out uniformly.
- **Never `lume update` on a Homebrew install, and gate the update check.** Applying an update through lume itself would put a non-brew binary where brew expects its own; upgrades come from `brew upgrade lume`. `LUME_UPDATE_CHECK=false` in the shell profile disables the read-only GitHub Releases request behind `lume check-update`, `lume update`, *and* the MCP `check_for_update` tool — worth setting so no scripted or MCP path phones out either. Telemetry has both forms: `lume config telemetry disable|enable|status|reset-id` persists the preference, and `LUME_TELEMETRY_ENABLED` overrides it per process.
- **`--cpu`/`--memory` exist on `create` (defaults 4 cores / 8 GB; clones inherit).** The defaults are right for the baseline build — the CLT install and Homebrew benefit — and fine for run clones too; trim a clone's memory only if the host is under pressure, not on principle.
- **Do not hand-clone with `cp -c` instead of `lume clone`.** The clone is already copy-on-write — 27 GB of allocated image cloned in about two seconds — and, more importantly, `lume clone` regenerates the VM's identity: the cloned `config.json` carries a fresh `macAddress` *and* `machineIdentifier`. A `clonefile(2)` copy would duplicate both onto the same NAT segment, and fixing that by hand-editing `config.json` is just reimplementing `lume clone` badly.
- **There is no quiet flag**; every command narrates at INFO. Filter with `grep -v '^\['` where it matters. `lume dump-docs --type=cli` emits every command, option, flag, default, and help string as JSON, which beats reading `--help` when you want to confirm a flag exists — `jq` over it is how the 0.5.0 spellings on this page were checked. Commands that touch the native display also print a couple of `Connection invalid` / `com.apple.hiservices-xpcservice` lines on stderr, including under `--display=none` and including when the command then fails for an unrelated reason; they are noise.
- **Alternatives were weighed, and lume stays.** [Tart](https://github.com/cirruslabs/tart) is the automation-native comparison (COW clones, registry images, built for macOS CI), but it has no equivalent of lume's offline unattended setup: its answer to "where does a ready guest come from" is prebuilt images pulled from a registry, trading the provenance of building locally from an Apple restore image for trust in a third party's image — and its Fair Source license needs reading besides. VirtualBuddy is GUI-first, the wrong shape for a scripted flow. lume's IPSW-plus-offline-preset path is the differentiator that fits here.
- **Pre-installing the CLT by hand** (replicating the installer's `softwareupdate` block) is possible but unnecessary once the grant removes the race — and the transcribed attempt is a caution: a multi-line quoted `softwareupdate` pipeline with an unbalanced `if` and a variable borrowed from the installer's internals is exactly the kind of command the quoting rules above exist to prevent.

### Networking: working, with one loose end

An earlier reading of this page said the guest had no usable outbound HTTP. **It does.** From the guest:

```console
$ curl --ipv4 --fail --silent --show-error --head https://example.com
HTTP/2 200
```

So IPv4 DNS, TCP, and TLS all work under the default NAT. Two corrections to how the earlier failure was read:

- **`ping` is not a connectivity test here.** Apple's `vmnet` NAT does not forward ICMP echo, so 100% loss to `1.1.1.1` is expected and says nothing. Test TCP.
- **The one unexplained observation** is a `curl: (56) … 404` fetching `raw.githubusercontent.com/Homebrew/install/HEAD/install.sh`, at a moment when DNS was resolving normally. A 404 is an HTTP-layer answer, so the request reached *something*. It has not recurred and may have been transient. If it returns, `curl --ipv4 --verbose --silent --show-error --output /dev/null <url> 2>&1 | tail -30` shows which address answered, and `curl -6` versus `curl -4` separates a stalled ULA IPv6 path from anything else.

**Bridged networking is still unavailable on the Homebrew build**, which matters because it would sidestep the NAT stack entirely. [homebrew-core#269744](https://github.com/Homebrew/homebrew-core/pull/269744) (merged 2026-02-27) did add a signed bundle to the formula, but not this capability — checked on the installed binary:

```console
$ codesign -d --entitlements - "$(brew --cellar lume)/0.5.0/libexec/lume"
[Dict]
	[Key] com.apple.security.virtualization
	[Value]
		[Bool] true
```

That is the only entitlement present; `com.apple.vm.networking` is absent. The formula's own comment says why — it signs with `resources/lume.local.entitlements` to "Avoid SIGKILL with ad-hoc signing." `com.apple.vm.networking` is a **restricted** entitlement that Apple honors only under a provisioning profile, which an ad-hoc signature of a source build cannot carry. So this is structural to Homebrew builds rather than an oversight a formula patch can close, which is consistent with [trycua/cua#1133](https://github.com/trycua/cua/issues/1133) remaining open. Reinstalling lume from the official installer stays the prerequisite for `--network bridged`.

([trycua/cua#483](https://github.com/trycua/cua/issues/483) — NAT DNS at `192.168.64.1` not resolving, workaround an external resolver — did not reproduce here; this guest resolves through a link-local IPv6 server without intervention.)

### Display, detach, and the two ways to stop

Three 0.5.0 behaviors that a headless flow has to get right, gathered here because each is easy to get wrong in a way that looks like something else.

**`lume run` opens a viewer by default**, and the default is the native window (`--display=native`). Automation must suppress it explicitly with `--display=none`. `--no-display` survives as a compatibility alias — the CLI metadata labels it exactly that — so old scripts keep working, but `--display=none` is the spelling to write. The VNC server stays available in every display mode, and `lume attach <name>` opens a viewer against an already-running guest, which is the civilized way to look inside a VM that a script started headless.

**`--detach` replaces the trailing `&`.** It returns immediately, prints the child PID, and appends output to `~/Library/Logs/lume/<name>.log` (`--log-file` overrides). A background job with a PID and a log file beats a shell job whose output interleaves with everything else. One thing to know: it re-executes lume under `nohup` with the original arguments *minus* the detach options, so it does not imply a display mode — pass `--display=none` alongside it.

**`stop` and `shutdown` are different tools**, and which one is right here is not the obvious answer:

- **Run clones keep `stop`.** The disk is deleted seconds later, so a graceful guest unmount buys nothing and costs an SSH round trip. That is what `lume_teardown` calls.
- **The baseline gets `shutdown`.** It is the copy that gets kept and cloned, and the last thing it did was write a Homebrew tree — the one place a clean power-down is worth its cost. `shutdown` reaches the guest over SSH (`--user`/`--password` default to `lume`/`lume`, `--timeout` to 30 seconds), so it needs a guest that is actually up.

Neither replaces the state check: `lume delete --force` still fails against a running VM, and `lume stop` still hangs against a stopped one.

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
