;;; Guix System executor image — single-layer (option A).
;;;
;;; OS base + job toolchain baked into ONE image via `guix system image`.
;;; The toolchain list mirrors manifest.scm (kept as reference + local
;;; `guix shell -m` use); edit BOTH when changing the toolchain.
;;;
;;; Build:
;;;   guix system image -t docker executor/gitea/config.scm > executor.tar.gz
;;;   podman load < executor.tar.gz

(use-modules (gnu) (gnu packages))
(use-service-modules networking ssh)

(operating-system
  (host-name "executor")
  (timezone "UTC")
  (locale "en_US.utf8")

  ;; bootloader REQUIRED (never #f) — docker-image type doesn't look it up
  ;; but the operating-system record demands a value.
  (bootloader (bootloader-configuration
               (bootloader grub-bootloader)
               (targets '())))

  ;; No (kernel ...) field — default is %base-kernel (linux-libre).

  (file-systems (cons (file-system
                        (mount-point "/")
                        (device "/dev/sda1")
                        (type "ext4"))
                      %base-file-systems))

  (users (cons (user-account
                (name "executor")
                (group "users")
                (supplementary-groups '("wheel" "netdev"))
                (home-directory "/home/executor"))
               %base-user-accounts))

  ;; Job toolchain (mirrors manifest.scm — keep both in sync).
  ;; specification->package avoids per-package module imports.
  (packages
   (append
    (map specification->package
         '(;; === VCS ===
           "git"
           "git-lfs"

           ;; === .NET SDK ===
           "dotnet"

           ;; === Python ===
           "python"
           "python-virtualenv"
           "python-pip"

           ;; === Guix essentials (guix shell inside jobs) ===
           "guile"
           "guix"

           ;; === Build tools ===
           "pkg-config"

           ;; === Networking ===
           "curl"
           "wget"
           ;; nss-certs, make, gzip, xz, zstd, coreutils, grep, sed, gawk,
           ;; findutils omitted — already in %base-packages (conflict if listed).
           ))
    %base-packages))

  (services
   (append
    (list
     (service openssh-service-type
              (openssh-configuration
               (permit-root-login #f)
               (password-authentication? #f)))
     (service dhcpcd-service-type)

     ;; GitHub Actions container protocol: runner expects /bin/sh, /bin/tail
     ;; etc. Guix System keeps everything in /gnu/store + profile bin/ but
     ;; /bin itself is empty — link the POSIX toolchain there.
     ;; simple-service takes the gexp DIRECTLY as its value — no lambda wrapper.
     (simple-service
      'link-bin-to-posix-tools activation-service-type
      #~(system* "/bin/sh" "-c"
                 (string-append
                  "mkdir -p /bin; "
                  "for t in sh bash tail head cat ls grep sed awk gawk find "
                  "mkdir rm cp mv ln chmod chown echo printf env which true "
                  "false sleep cut sort uniq wc tee xargs tar gzip gunzip; do "
                  "src=/run/current-system/profile/bin/$t; "
                  "[ -e $src ] && [ ! -e /bin/$t ] && ln -s $src /bin/$t; "
                  "done"))))
     %base-services)))
