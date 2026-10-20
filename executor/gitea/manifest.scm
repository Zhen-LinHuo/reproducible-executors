;;; Guix manifest for CI job executor toolchain.
;;;
;;; This defines what tools are available inside CI jobs when using
;;; this executor image. Loaded via `guix shell -m manifest.scm` or
;;; baked into the image at build time.
;;;
;;; Scope: .NET + Python + Guix essentials for MARL project CI.
;;; Add/remove packages based on project needs.

(use-modules (gnu packages)
             (gnu packages version-control)
             (gnu packages python)
             (gnu packages python-xyz)
             (gnu packages guile)
             (gnu packages bash)
             (gnu packages base)
             (gnu packages curl)
             (gnu packages wget)
             (gnu packages compression)
             (gnu packages linux)
             (gnu packages tls)
             (gnu packages pkg-config))

(specifications->manifest
 '(
   ;; === VCS ===
   "git"
   "git-lfs"


   ;; === Python (for data pipeline) ===
   "python"
   "python-virtualenv"
   "python-pip"

   ;; === CI runner runtime (the GitHub runner itself, NOT our code) =======
   ;; Exhaustive from the runner's own behaviour, verified against run
   ;; 38903972719 logs (its container probes are hard-coded):
   ;;   sh  - runner probes the OS via `docker exec ... sh -c "cat /etc/*release"`
   ;;       and executes every `run:` block through a shell. NOTE: there is
   ;;       no package called "sh" in Guix; bash supplies /bin/sh, so listing
   ;;       bash alone covers both roles (verified: guix show sh -> not a
   ;;       package, guix show bash -> 5.2.37).
   ;;   bash - GitHub's default shell for `run:` blocks is `bash -e {0}`.
   ;;   node - runs the JS actions (actions/checkout, actions/cache,
   ;;       docker/login-action); also the runner's own language.
   ;; Our own workflow commands (cat/cp/curl/grep/head/ls/readlink/sed/
   ;; seq/sleep/tail/tr/which + guix/podman/gzip) are all covered by
   ;; coreutils/grep/sed/gzip/guix already listed below — zero gap there.
   "bash"                   ; /bin/sh + runner default shell
   "node"                   ; Node.js 22 — JS actions + runner runtime

   ;; === Guix essentials (guix shell inside jobs) ===
   "guile"                  ; Guix's Guile (for guix repl/debug)
   "guix"                   ; guix CLI (for guix shell -m ...)

   ;; === Build tools ===
   "make"
   "pkg-config"
   "which"

   ;; === Networking (for downloads, NuGet, PyPI) ===
   "curl"
   "wget"
   "nss-certs"

   ;; === Compression ===
   "gzip"
   "tar"
   "xz"
   "zstd"

   ;; === Core utilities (usually in base, but explicit) ===
   "coreutils"
   "grep"
   "sed"
   "gawk"
   "findutils"

   ;; === Optional: Godot (uncomment if CI runs Godot tests) ===
   ;; "godot"                ; ~1.2 GB, enable only if needed
   ))
