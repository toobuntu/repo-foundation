<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Preflighting workflows with act

[`act`](https://github.com/nektos/act) runs GitHub Actions workflows locally, before a push, so a workflow edit can be checked without burning a CI round-trip. It is a **developer preflight tool**, never part of CI itself. This page records what works for repo-foundation's workflows on an Apple-silicon Mac with Colima, verified by running them, and what each flag is for — because the flags are hard to discover.

## Setup

```sh
brew install act colima
colima start            # boots a Linux VM (Lima) that speaks the Docker API
```

`act` needs a Docker-API backend for `ubuntu-latest` jobs; Colima is the light, no-cost option (Docker Desktop also works). `colima start` makes Colima the active Docker context, so `act` picks up its socket from that context and runs work without `DOCKER_HOST` set. If a tool ever fails to find it (for example `act --bug-report` probes `/var/run/docker.sock` and errors), set it explicitly from whatever context is active — resolved with Docker's own `--format`, no `jq`:

```sh
ctx="$(docker context show)"
export DOCKER_HOST="$(docker context inspect "$ctx" --format '{{ .Endpoints.docker.Host }}')"
```

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

<!-- rumdl-disable MD013 -->

```sh
# Pull a vanilla macOS image and name the VM 'rf-preflight' (login: lume / lume).
# Get the exact image:tag from `lume images` or trycua's registry (ghcr.io/trycua).
lume pull <macos-image:tag> rf-preflight

# Start it headless with the checkout shared in read-write (VirtioFS; a macOS
# guest surfaces the share under /Volumes/My Shared Files/<name>). Backgrounded
# so the same terminal can drive it.
lume run rf-preflight --shared-dir "$PWD:rw" --no-display &

# A vanilla image has NO Homebrew, so install brew + act once. Bake the result
# into a saved image with `lume push` to skip this each run.
lume ssh rf-preflight '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && brew install act'

# Run the macOS job INSIDE the guest (lume ssh executes a command remotely):
lume ssh rf-preflight 'cd "/Volumes/My Shared Files/repo-foundation" && act --job spec --platform macos-latest=-self-hosted --container-architecture darwin/arm64 --quiet'

lume stop rf-preflight && lume delete rf-preflight   # tear down
```

<!-- rumdl-enable MD013 -->

The VM is the isolation boundary — the `brew install` and Ruby setup happen inside it, and your real Mac is untouched. (Confirm `<macos-image:tag>` against `lume images`, and the exact share path for your image.)

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
