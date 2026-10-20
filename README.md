[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/Zhen-LinHuo/reproducible-executors)](https://github.com/Zhen-LinHuo/reproducible-executors/stargazers)
[![GitHub last commit](https://img.shields.io/github/last-commit/Zhen-LinHuo/reproducible-executors)](https://github.com/Zhen-LinHuo/reproducible-executors/commits/main)

# Reproducible CI Executors

A declarative **job executor** image (NOT a runner) built with Guix System, for
reproducible and auditable CI build environments.

## What this is

CI needs two things:

1. **Runner** (scheduler) — polls the job queue and starts job containers. *Not
   built here.*
2. **Job executor** (execution environment) — the container a job actually runs
   in. *This repository builds it.*

There is exactly **one image**: `executor-guixsd`.

```
ghcr.io/zhen-linhuo/reproducible-executors/executor-guixsd:latest
ghcr.io/zhen-linhuo/reproducible-executors/executor-guixsd:v0.2.0
ghcr.io/zhen-linhuo/reproducible-executors/executor-guixsd:sha-<commit>
```

Its toolchain is declared in `executor/gitea/config.scm` and nothing else:
`guix`, `podman`, `python3`, `git`, `git-lfs`, `node`, `bash`, `gcc`
(libstdc++/libgcc_s for host externals), `guile`, `pkg-config`, `which`,
`curl`, `wget`.

## Why it exists

- **Reproducible** — the same `config.scm` and pinned channel commit produce the
  same Guix store closure, bit for bit.
- **Auditable** — the whole environment is one declarative file in git; every
  build is a CI log; every image is content-addressed in GHCR.
- **Self-bootstrapping** — the second CI stage runs *inside this image* and
  rebuilds it, so the executor tracks upstream and produces new images without a
  hand-maintained build host.

## How the image is produced (important)

`guix system image -t docker` exports a **raw** docker tarball. The OS never
boots, so every activation-time artifact is missing: `/bin`, `/lib64`,
`/run/current-system`, `/root`, and the whole `/etc` (passwd/group/nsswitch,
the CA bundle, `/etc/services`). A CI runner starts the container with
`--entrypoint tail`, so those gaps never fill themselves.

`executor/gitea/inject.sh` therefore runs after `guix system image`: it loads the
raw tarball, injects the activation-time files (including the ten `guixbuild`
users, the CA bundle and `/etc/services`), and commits the result. Both CI
stages call the **same** script — that is what guarantees the self-built image
is never less complete than the original.

## CI

Two workflows, in order:

| Workflow | Runs on | Produces |
|---|---|---|
| `build-executor.yml` | GitHub-hosted runner (`ubuntu-latest`) | the image, pushed to GHCR |
| `build-executor-guixsd.yml` | **inside the executor image** (`container:`, `--privileged`) | the same image, rebuilt by itself (bootstrap) |

`build-executor-guixsd.yml` is chained on a successful `build-executor` run and
can also be dispatched manually.

## Usage

```bash
podman pull ghcr.io/zhen-linhuo/reproducible-executors/executor-guixsd:latest

podman run --rm -v "$PWD":/workspace -w /workspace \
  ghcr.io/zhen-linhuo/reproducible-executors/executor-guixsd:latest \
  /run/current-system/profile/bin/guix --version
```

Inside a CI job the image is used as the job's `container:`, so every `run:`
step executes in this environment.

## Building locally

```bash
# 1. raw Guix System image
guix system image -t docker executor/gitea/config.scm > /tmp/executor.tar.gz

# 2. extract the special-files list from config.scm (single source)
guix repl executor/gitea/extract-special-files.scm > /tmp/special-files.tsv

# 3. inject the activation-time files and commit localhost/guix:latest
PODMAN=podman bash executor/gitea/inject.sh
```

## Repository layout

```
reproducible-executors/
├── executor/gitea/
│   ├── config.scm                  # the whole image, declaratively
│   ├── manifest.scm                # job toolchain for `guix shell -m`
│   ├── extract-special-files.scm   # config.scm → TSV (single source)
│   ├── inject.sh                   # raw tarball → runnable image
│   └── VERSION                     # image version
├── .guix/channels.scm              # pinned Guix channel + introduction
├── .github/workflows/
│   ├── build-executor.yml          # stage 1: build on GitHub-hosted runners
│   └── build-executor-guixsd.yml   # stage 2: self-bootstrapping build
├── docs/substitute-sources.md      # substitute farms and their order
├── AGENTS.md
└── README.md
```

## Deployment

The image is meant to run as a persistent container on two kinds of host:

- **Rootless podman** — a Quadlet unit.
- **Synology NAS** — Container Manager (docker), a persistent container.

Runner registration lives elsewhere; this repository guarantees only that the
image builds reproducibly and that the containers run it.

## Contributing

Contributions welcome. Keep the environment declarative: system configuration
belongs in `config.scm`; imperative steps only in CI where unavoidable.

## Licence

Apache-2.0 — see [LICENSE](LICENSE).
