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

   ;; === CI runner runtime (GitHub Actions needs node for JS actions) ===
   "node"                   ; Node.js 22 — required by actions/checkout etc.

   ;; === Guix essentials (guix shell inside jobs) ===
   "guile"                  ; Guix's Guile (for guix repl/debug)
   "guix"                   ; guix CLI (for guix shell -m ...)

   ;; === Build tools ===
   "make"
   "pkg-config"

   ;; === Networking (for downloads, NuGet, PyPI) ===
   "curl"
   "wget"
   "nss-certs"

   ;; === Compression ===
   "gzip"
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
