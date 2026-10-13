# Agent Instructions

## Scope

This repository builds reproducible CI **job executor** images (NOT runners) using declarative system configuration (Guix System). The agent may:

- Edit `executor/*/config.scm`, `executor/*/manifest.scm`, `Dockerfile`, and workflow YAML files
- Build and test images locally (podman/docker)
- Push executor images to GHCR via CI
- Update package recipes and channel pins

The agent must NOT:

- Modify upstream Guix package definitions (contribute upstream instead)
- Bypass CI to push executor images directly to GHCR
- Hardcode credentials in configs (use GitHub Secrets)

## Working style

Concise, present-tense, forward-looking. State rules, not history.

## Principles

- **Declarative first** — All system configuration lives in `executor/*/config.scm` and `manifest.scm`; imperative steps belong in Dockerfiles or CI workflows only when unavoidable.
- **Reproducibility over convenience** — Pin channel commits, lock Nix flake inputs, verify builds are bit-identical across rebuilds.
- **Fat executor, stateless runner** — Executor contains .NET SDK, Python, Guix daemon, build tools. Runner stays thin (just the scheduler binary).
- **Verification: run the change, don't describe it** — Before declaring work done, build the executor image and run a test job inside it.

## Completion discipline

Before declaring work done:

- Check the change's blast radius (did it affect other runner types or OS images?)
- Update every affected project document — README, this file, VERSION/CHANGELOG, CONTRIBUTING
- Verify the image builds successfully (or explain why it can't be verified)
- For Guix changes: confirm `guix system image -t docker executor/*/config.scm` completes without errors
- For NixOS changes: confirm `nixos-rebuild build` produces a bootable closure
