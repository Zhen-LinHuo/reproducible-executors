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
(use-package-modules admin base bash compression gawk node)
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

           ;; === Python ===
           "python"
           "python-virtualenv"
           "python-pip"

           ;; === CI runner runtime (the GitHub runner itself) ===
           "bash"
           "node"
           "gcc"   ; libstdc++ / libgcc_s — 宿主 externals node 的动态依赖

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
     ;; The value is a quasiquote alist of (target-path . store-item) — the
     ;; EXACT shape Guix's own %base-services uses (gnu/services/base.scm
     ;; L4257). file-append must be evaluated at CONFIG time (Guile), not in
     ;; a runtime lambda/map: special-files' activate script is compiled from
     ;; this list, and a runtime-resolved package breaks it with
     ;; `activate-service.scm.drv failed with exit code 1`.
     (service special-files-service-type
              `(("/bin/sh" ,(file-append bash "/bin/sh"))
                ("/bin/bash" ,(file-append bash "/bin/bash"))
                ("/bin/tail" ,(file-append coreutils "/bin/tail"))
                ("/bin/head" ,(file-append coreutils "/bin/head"))
                ("/bin/cat" ,(file-append coreutils "/bin/cat"))
                ("/bin/ls" ,(file-append coreutils "/bin/ls"))
                ("/bin/env" ,(file-append coreutils "/bin/env"))
                ("/bin/sleep" ,(file-append coreutils "/bin/sleep"))
                ("/bin/cut" ,(file-append coreutils "/bin/cut"))
                ("/bin/sort" ,(file-append coreutils "/bin/sort"))
                ("/bin/uniq" ,(file-append coreutils "/bin/uniq"))
                ("/bin/wc" ,(file-append coreutils "/bin/wc"))
                ("/bin/tee" ,(file-append coreutils "/bin/tee"))
                ("/bin/mkdir" ,(file-append coreutils "/bin/mkdir"))
                ("/bin/rm" ,(file-append coreutils "/bin/rm"))
                ("/bin/cp" ,(file-append coreutils "/bin/cp"))
                ("/bin/mv" ,(file-append coreutils "/bin/mv"))
                ("/bin/ln" ,(file-append coreutils "/bin/ln"))
                ("/bin/chmod" ,(file-append coreutils "/bin/chmod"))
                ("/bin/chown" ,(file-append coreutils "/bin/chown"))
                ("/bin/echo" ,(file-append coreutils "/bin/echo"))
                ("/bin/printf" ,(file-append coreutils "/bin/printf"))
                ("/bin/true" ,(file-append coreutils "/bin/true"))
                ("/bin/false" ,(file-append coreutils "/bin/false"))
                ("/bin/grep" ,(file-append grep "/bin/grep"))
                ("/bin/sed" ,(file-append sed "/bin/sed"))
                ("/bin/awk" ,(file-append gawk "/bin/awk"))
                ("/bin/gawk" ,(file-append gawk "/bin/gawk"))
                ("/bin/find" ,(file-append findutils "/bin/find"))
                ("/bin/xargs" ,(file-append findutils "/bin/xargs"))
                ("/bin/tar" ,(file-append tar "/bin/tar"))
                ("/bin/gzip" ,(file-append gzip "/bin/gzip"))
                ("/bin/node" ,(file-append node "/bin/node"))
                ("/bin/which" ,(file-append which "/bin/which")))))
    %base-services)))
