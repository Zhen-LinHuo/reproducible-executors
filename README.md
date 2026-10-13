[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/Zhen-LinHuo/reproducible-executors)](https://github.com/Zhen-LinHuo/reproducible-runners/stargazers)
[![GitHub last commit](https://img.shields.io/github/last-commit/Zhen-LinHuo/reproducible-runners)](https://github.com/Zhen-LinHuo/reproducible-runners/commits/main)
[![Star history](https://api.star-history.com/svg?repos=Zhen-LinHuo/reproducible-runners&type=Date)](https://star-history.com/#Zhen-LinHuo/reproducible-runners&Date)

# Reproducible CI Executors

Declarative **job executor** images (NOT runners) built with Guix System for reproducible, auditable CI build/test environments.

## Overview

CI workflows need two things:

1. **Runner** (scheduler) — polls job queue, creates job containers. **We don't build these.**
2. **Job executor** (execution environment) — runs `dotnet test`, `guix build`, `python pipeline.py`, etc. **This repository builds these.**

### Why Executors?

Executors guarantee:

- **Reproducibility** — Same `config.scm` + `manifest.scm` → bit-identical environment (Guix content-addressed store)
- **Auditability** — Full provenance: declarative config in git, build logs in CI, signed images in GHCR
- **Consistency** — Local dev (`guix shell`) = CI job (executor image) = production (same store paths)
- **Toolchain pre-installed** — No `guix shell` bootstrap delay per job; .NET/Python/Guix daemon ready at start

### Repository Contents:

- **Guix System executors** (`executor/`) — `operating-system` declarations built with `guix system image`
- **NixOS images** (`nix/`) — (planned) NixOS system closures built with `nixos-rebuild`
- **Container packaging** (`executor/*/Dockerfile`) — OCI packaging with entrypoint
- **CI workflows** (`.github/workflows/`) — Automated builds pushing to GHCR

## Design Principles

1. **Declarative OS, imperative job** — The executor image declares a complete OS (Guix System) with Shepherd services (sshd, guix-daemon). Job commands run inside via `container:` entrypoint.
2. **Fat executor, stateless runner** — Executor contains .NET SDK, Python, Guix daemon, build tools. Runner stays thin (just the scheduler binary).
3. **Reproducible** — Guix/Nix content-addressed store guarantees bit-identical rebuilds from the same config.
4. **Auditable** — Full provenance: `config.scm` in git, build logs in CI, signed images in GHCR with OCI labels (`org.opencontainers.image.*`).
5. **Cached** — Executor closure baked into fleet Guix substitute cache (cache01) for fast rebuilds on internal machines.

## Quick Start

```bash
# Build a Guix System docker image (requires Guix on the build host)
guix system image -t docker executor/gitea/config.scm > executor-gitea.tar.gz

# Load into podman/docker
podman load < executor-gitea.tar.gz

# Run
# Run a job in the executor
podman run --rm \
  -v $(pwd):/workspace \
  -w /workspace \
  localhost/guix:latest \
  guix shell -m manifest.scm -- dotnet test
```

## Repository Layout

```
reproducible-executors/
├── executor/                        # ← Core: job executor images
│   ├── gitea/                      # Gitea Actions executor
│   │   ├── config.scm              # Guix System operating-system declaration
│   │   ├── manifest.scm            # Job toolchain (dotnet, python, ...)
│   │   └── Dockerfile              # OCI packaging (FROM scratch + entrypoint)
│   ├── forgejo/                    # Forgejo Actions executor
│   │   ├── config.scm
│   │   ├── manifest.scm
│   │   └── Dockerfile
│   └── github/                     # GitHub Actions executor
│       ├── config.scm
│       ├── manifest.scm
│       └── Dockerfile
│
├── recipes/                         # Guix package recipes (upstream doesn't have them)
│   └── (reserved)
│
├── .github/
│   └── workflows/
│       ├── build-executors.yml     # Build all three executor images → GHCR
│       └── cache-closure.yml       # Bake executor closure into cache01 (Garage)
│
├── docs/
│   └── architecture.md             # Runner vs executor, design decisions
│
├── README.md                        # This file
├── AGENTS.md                        # AI agent instructions
└── LICENSE                          # Apache-2.0
```

## Building

### Prerequisites

- **Guix** 1.4+ (for `guix/` images)
- **podman** or **docker** (for OCI packaging)
- **act_runner** binary (or build from `guix/recipes/act-runner.scm`)

### Local Build

```bash
# 1. Build the Guix System image (produces tarball on stdout)
guix system image -t docker executor/gitea/config.scm > /tmp/executor-gitea.tar.gz

# 2. Load into podman
podman load < /tmp/executor-gitea.tar.gz

# 3. Test
podman run --rm localhost/guix:latest guix --version
podman run --rm localhost/guix:latest dotnet --version
```

### CI Build

Pushes to `main` trigger `.github/workflows/build-guix.yml`:

1. Install Guix on `ubuntu-latest`
2. Build `executor/*/config.scm` → OCI tarball (three parallel jobs)
3. Push to `ghcr.io/zhen-linhuo/reproducible-executors/{gitea,forgejo,github}:latest`

## Status

- [x] Guix System config verified (syntax, `guix system image` toolchain)
- [ ] `manifest.scm` with .NET + Python toolchain
- [ ] Dockerfile + entrypoint
- [ ] CI workflow (build → GHCR)
- [ ] Cache closure into Garage (cache01)
- [ ] Deploy to NAS (Container Manager) + SL00 (Quadlet Podman)
- [ ] Register as job label in Gitea/Forgejo/GitHub



## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Licence

Apache-2.0 — see [LICENSE](LICENSE).
