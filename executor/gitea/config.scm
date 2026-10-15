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
(use-service-modules base networking ssh)

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

     ;; GitHub Actions container protocol: the runner's `docker create`
     ;; hard-codes --entrypoint "tail" (and its init runs sh/cat), so these
     ;; must exist in /bin.
     ;;
     ;; special-files-service-type, NOT activation-service-type: special-files
     ;; materialises the symlinks into the root file system AT BUILD TIME
     ;; (same mechanism gnu/system/images/wsl2.scm uses for /bin/sh), while an
     ;; activation script only runs at VM boot — which a docker container never
     ;; reaches, so /bin stayed empty and the runner died with
     ;; `exec: "tail": executable file not found in $PATH`.
     (service special-files-service-type
              (map (lambda (pair)
                     (cons (car pair)
                           (file-append (apply specification->package
                                               (list (cdr pair)))
                                        (string-append "/bin/" (car pair)))))
                   '(("sh" . "bash")
                     ("bash" . "bash")
                     ("tail" . "coreutils")
                     ("head" . "coreutils")
                     ("cat" . "coreutils")
                     ("ls" . "coreutils")
                     ("env" . "coreutils")
                     ("sleep" . "coreutils")
                     ("cut" . "coreutils")
                     ("sort" . "coreutils")
                     ("uniq" . "coreutils")
                     ("wc" . "coreutils")
                     ("tee" . "coreutils")
                     ("mkdir" . "coreutils")
                     ("rm" . "coreutils")
                     ("cp" . "coreutils")
                     ("mv" . "coreutils")
                     ("ln" . "coreutils")
                     ("chmod" . "coreutils")
                     ("chown" . "coreutils")
                     ("echo" . "coreutils")
                     ("printf" . "coreutils")
                     ("true" . "coreutils")
                     ("false" . "coreutils")
                     ("grep" . "grep")
                     ("sed" . "sed")
                     ("awk" . "gawk")
                     ("gawk" . "gawk")
                     ("find" . "findutils")
                     ("xargs" . "findutils")
                     ("tar" . "tar")
                     ("gzip" . "gzip")
                     ("gunzip" . "gzip")
                     ("which" . "which")))))
    %base-services)))
