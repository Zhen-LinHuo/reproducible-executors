;; .guix/channels.scm — explicit channel pin for CI image builds.
;;
;; Single source of truth for which channels (and their commit hashes) the
;; GitHub-hosted executor image build resolves against.  Without this file,
;; `guix time-machine` runs against the INSTALLER's default channels (the
;; stable tarball's %default-channels = stable's commit), and packages from
;; non-official channels (e.g. `dotnet` from nonguix) fail with "unknown
;; package".
;;
;; Why an EXPLICIT master URL instead of %default-channels: bordeaux
;; .guix.gnu.org serves substitutes built from the Guix MASTER branch. The
;; 1.5.0 stable tarball's %default-channels resolves to stable's commit, a
;; different revision -> every derivation hash differs -> bordeaux 100%
;; miss -> full bootstrap chain rebuild from seed (2+ hour stall).
;; time-machine resolving this file against master hits bordeaux instead.
;;
;; Why pin at all: reproducibility.  `guix time-machine -C <file>` resolves
;; this pin to a checkout under ~/.cache/guix; the checkout is what
;; actions/cache restores (key = hash of THIS file).
;;
;; Bump policy: EVENT-DRIVEN ONLY — when upstream renames/removes something
;; this config's packages list needs, or a guix-daemon security advisory
;; (fixes land only in rolling).  No schedule.

(list
 ;; Official Guix channel — provides guix, git, python, etc.
 (channel
  (name 'guix)
  (url "https://git.guix.gnu.org/guix.git")
  (branch "master"))

 ;; nonguix — provides `dotnet` and other non-free packages.
 ;; The introduction is nonguix's PGP fingerprint for channel authentication.
 (channel
  (name 'nonguix)
  (url "https://gitlab.com/nonguix/nonguix")
  (introduction
   (make-channel-introduction
    "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
    (openpgp-fingerprint
     "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5")))))
