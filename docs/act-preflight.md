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

`act` needs a Docker-API backend for `ubuntu-latest` jobs; Colima is the light, no-cost option (Docker Desktop also works). `act` auto-discovers Colima's socket (`$HOME/.colima/docker.sock`) for runs. If it ever does not (for example `act --bug-report` probes `/var/run/docker.sock` and errors), set it explicitly:

```sh
export DOCKER_HOST="$(docker context inspect colima | jq -r '.[0].Endpoints.docker.Host')"
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
act --job spec -P macos-latest=-self-hosted   # verified: job succeeded
```

The sentinel is the literal string `-self-hosted`; a bare `-` is read as an image reference and fails with `invalid reference format`. Running on the host exercises the real workflow around the suite — `Homebrew/actions/setup-ruby`, `brew install vale`, the Bundler cache — not just a bare `rspec`; the trade-off is that it *touches* the host (a real `brew install`, a real Ruby setup) and runs the suite in the current checkout. The M-series "specify container architecture" warning still prints and is harmless here; passing **any** `--container-architecture` value silences it — the value is ignored for a host job, so `darwin/arm64` or even a bogus string works — and `--quiet` trims the rest of the noise:

```sh
act --job spec -P macos-latest=-self-hosted --container-architecture darwin/arm64 --quiet
```

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
- **Disk.** `full-latest` is >18 GB compressed and much larger extracted, into the Colima VM's disk — a sparse file bounded by host free space. A near-full host fails mid-extract with `no space left on device` under `/var/lib/containerd/…` (the `.NET` file in that error is incidental; the image bundles the whole runner toolchain including a multi-GB .NET SDK). `docker system prune -af` reclaims space; keep several tens of GB free.

## Recommendation

- **Structure** — `--dryrun`/`--validate` on any workflow you edit; the fastest check.
- **The macOS `spec.yml` job** — `-P macos-latest=-self-hosted`, run for real on the host.
- **The brew-heavy `ubuntu-latest` jobs** — they run, with native arm64 + `full-latest`; use this when you want the real workflow (setup, `brew install`, caching) exercised end to end. For a quick pass the native gates are lighter — the "Build, test, and lint" block in `AGENTS.md` is what those jobs run — so reach for `act` when the *workflow* is what you're verifying, not just the tools.
