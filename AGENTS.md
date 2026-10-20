# Agent Instructions

## Scope

This repository builds one reproducible CI **job executor** image (NOT a runner) from a declarative Guix System configuration. The agent may:

- Edit `executor/gitea/config.scm`, `executor/gitea/manifest.scm`, `executor/gitea/inject.sh`, `.guix/channels.scm`, and workflow YAML files
- Build and test the image locally (podman or docker)
- Push the executor image to GHCR through CI
- Update the pinned channel commit

The agent must NOT:

- Modify upstream Guix package definitions (contribute upstream instead)
- Bypass CI to push the executor image directly to GHCR
- Hardcode credentials in configs (use GitHub Secrets)

## Working style

Concise, present-tense, forward-looking. State rules, not history.

## Principles

- **Declarative first** — All system configuration lives in `executor/gitea/config.scm` and `manifest.scm`. Imperative steps belong in CI workflow steps or in `inject.sh`, and only where unavoidable.
- **The image is produced in two stages** — `guix system image -t docker` exports a *raw* tarball; `inject.sh` then writes the activation-time files (`/bin`, `/lib64`, `/run/current-system`, `/root`, `/etc`) and commits. Never publish the raw tarball: without the injection it has no `/bin`, no `/etc` and no build users.
- **Reproducibility over convenience** — Pin the channel commit, keep the channel introduction verbatim from upstream, verify rebuilds are bit-identical.
- **Fat executor, stateless runner** — The executor carries `guix`, `podman`, `python3`, `git`, `node`, `bash` and build tools; the runner stays thin.
- **Verification: run the change, don't describe it** — Before declaring work done, build the image, run `inject.sh`, and boot the result to probe the toolchain, the build users, the CA bundle and `/etc/services`.

## Completion discipline

Before declaring work done:

- Check the change's blast radius (the image is used by both CI stages and by the deployment containers)
- Update every affected project document — README, this file, VERSION
- Verify the image builds successfully (or explain why it can't be verified)
- Confirm `guix system image -t docker executor/gitea/config.scm` completes without errors, and that `inject.sh` finishes cleanly
- Confirm the self-bootstrapping workflow still passes: the image must be able to rebuild itself
