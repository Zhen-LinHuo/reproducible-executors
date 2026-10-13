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
     (service dhcpcd-service-type))
    %base-services)))
