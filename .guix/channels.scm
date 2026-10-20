;; .guix/channels.scm — explicit channel pin for CI image builds.
;;
;; Single source of truth for which channels (and their commit hashes) the
;; GitHub-hosted executor image build resolves against.  Without this file,
;; `guix time-machine` runs against the INSTALLER's default channels (the
;; stable tarball's %default-channels = stable's commit), and packages from
;; non-official channels fail with "unknown package".
;;
;; Why PIN A COMMIT instead of (branch "master"): bordeaux.guix.gnu.org is
;; the official Guix build farm and serves substitutes for exactly ONE
;; revision of master at a time.  Following the moving branch HEAD means our
;; derivation hashes are always from a different moment than bordeaux's, so
;; every .narinfo comes back empty (verified: 4 sources answered 200 with
;; zero hits) and guix falls back to rebuilding the bootstrap chain from
;; seed — a 2h+ stall per run.
;;
;; fc3d77383da1fd87e40a5e35a41786a095080aec is the revision the Guix QA
;; service (qa.guix.gnu.org/branch/master) reports as built, with 99.1%
;; substitute availability on x86_64-linux.  Verified directly: narinfo
;; lookups against bordeaux for packages from this revision return 200.
;; NOTE: release tags (v1.5.0 etc.) are NOT an option here — bordeaux
;; serves substitutes for branch revisions, not for release tags, and QA
;; has no tag/release view (endpoints 404).
;;
;; Single official channel only: nonguix used to live here for `dotnet`,
;; but the executor image is toolchain-agnostic now (project toolchains are
;; loaded by each project's own scm at CI runtime), and bordeaux does not
;; serve nonguix's derivations — keeping it would reintroduce cache misses.
;;
;; Why pin at all: reproducibility.  `guix time-machine -C <file>` resolves
;; this pin to a checkout under ~/.cache/guix; the checkout is what
;; actions/cache restores (key = hash of THIS file).
;;
;; Bump policy: EVENT-DRIVEN ONLY — when bordeaux moves to a new revision
;; and this one ages out, or upstream renames/removes something this
;; config's packages list needs.  To find the current revision, read the
;; revision hash from qa.guix.gnu.org/branch/master and confirm the
;; narinfo answers on bordeaux before changing it.  No schedule.

(list
 ;; Official Guix channel — provides guix, git, python, etc.
 ;;
 ;; INTRODUCTION: without it guix warns "channel 'guix' is not trusted" and
 ;; takes the keyring-clone path, which does not inherit the build step's
 ;; SSL_CERT_FILE — that is where `clone: Operation not permitted` came from.
 ;; Values below are copied verbatim from guix/channels.scm
 ;; (%guix-channel-introduction) in the checkout, not reconstructed: an
 ;; earlier attempt used a wrong hash and failed with
 ;;   Git error: object not found - no match for id (...)
 (channel
  (name 'guix)
  (url "https://git.guix.gnu.org/guix.git")
  (commit "fc3d77383da1fd87e40a5e35a41786a095080aec")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"   ;2020-05-26
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
