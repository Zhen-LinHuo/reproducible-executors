;; .guix/channels.scm — explicit channel pin for CI image builds.
;;
;; Single source of truth for which channels (and their commit hashes) the
;; GitHub-hosted executor image build resolves against.  Without this file,
;; `guix system image` runs against the INSTALLER's default channels (official
;; only), and packages from non-official channels (e.g. `dotnet` from
;; nonguix) fail with "unknown package".
;;
;; Why pin: reproducibility + cache stability.  `guix time-machine -C <file>`
;; resolves this pin to a checkout under ~/.cache/guix; the checkout is what
;; actions/cache restores (key = hash of THIS file).  Pin drift = cache miss
;; + non-reproducible build.
;;
;; Bump policy: EVENT-DRIVEN ONLY — when upstream renames/removes something
;; this config's packages list needs, or a guix-daemon security advisory
;; (fixes land only in rolling).  No schedule.

;; Official Guix channel (the base — provides guix, git, python, etc.)
%default-channels

;; ... + nonguix (provides `dotnet` and other non-free packages).
;; The introduction is nonguix's PGP fingerprint for channel authentication.
(cons (channel
        (name 'nonguix)
        (url "https://gitlab.com/nonguix/nonguix")
        (introduction
          (make-channel-introduction
            "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
            (openpgp-fingerprint
              "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
      %default-channels)
