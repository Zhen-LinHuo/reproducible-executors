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

Its toolchain is declared in `executor/guixsd/config.scm` and nothing else:
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

`executor/guixsd/inject.py` therefore runs after `guix system image`. It
rewrites the image's layer tar directly, adding the activation-time files
(including the ten `guixbuild` users, the CA bundle and `/etc/services`) and
regenerating `config.json`. Both CI stages call the **same** script — that is
what guarantees the self-built image is never less complete than the original.

The injection deliberately happens at the tar level rather than through
`podman commit`: `guix system image` is already reproducible (its `created` is
1970-01-01, its file mtimes are the epoch), while `podman commit` stamps the
wall clock, merges `Env` in map order and rewrites mtimes — so every build used
to produce a different digest. `inject.py` keeps the archive deterministic: sorted
entries, fixed mtime, numeric root ownership and a fixed `Env` order.

## Reproducibility

The same `config.scm` built twice produces the **identical image archive**: the
script is deterministic given the same inputs, and its output does not depend on
the wall clock, the build user, or the host.

This covers the packaging the pipeline controls. It cannot make a Guix package
that is itself unreproducible, and a package substituted on one run but built
locally on another can still differ — pin the channels and keep the substitute
farms healthy if you need that guarantee.

## CI

Two workflows:

| Workflow | Trigger | Runs on | Produces |
|---|---|---|---|
| `build-executor-guixsd.yml` | push to `executor/**`, `.guix/**` or itself; after a bootstrap; manual | **inside the executor image** (`container:`, `--privileged`) | the image, rebuilt by itself — this is the regular path |
| `bootstrap-executor-guixsd.yml` | **manual only** | GitHub-hosted runner (`ubuntu-latest`), installing Guix from scratch | the image, pushed to GHCR — bootstrap and recovery only |

The regular build is the self-bootstrapping one: every change is built inside
the image that already exists, so the executor is exercised on every push.
`bootstrap-executor-guixsd.yml` is needed only for the first build (no image in GHCR
yet) or to recover from a broken image; a successful bootstrap chains
`build-executor-guixsd.yml`, which rebuilds the fresh image with itself.

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
guix system image -t docker executor/guixsd/config.scm > /tmp/executor.tar.gz

# 2. extract the special-files list from config.scm (single source)
guix repl executor/guixsd/extract-special-files.scm > /tmp/special-files.tsv

# 3. inject the activation-time files (deterministic; rewrites the layer tar)
python3 executor/guixsd/inject.py /tmp/executor.tar.gz /tmp/executor-injected.tar /tmp/special-files.tsv

# 4. load and probe it
podman load < /tmp/executor-injected.tar
podman run --rm --entrypoint /run/current-system/profile/bin/guix localhost/guix:latest --version
```

## Repository layout

```
reproducible-executors/
├── executor/guixsd/
│   ├── config.scm                  # the whole image, declaratively
│   ├── manifest.scm                # job toolchain for `guix shell -m`
│   ├── extract-special-files.scm   # config.scm → TSV (single source)
│   ├── inject.py                   # raw tarball → runnable image (deterministic)
│   └── VERSION                     # image version
├── .guix/channels.scm              # pinned Guix channel + introduction
├── .github/workflows/
│   ├── build-executor-guixsd.yml   # regular: build inside the image itself
│   └── bootstrap-executor.yml      # manual: first build / recovery
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
