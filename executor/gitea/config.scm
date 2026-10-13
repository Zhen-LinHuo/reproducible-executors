;; Minimal Guix System config — verified: builds via `guix system image -t docker`,
;; loads with podman, boots Shepherd (PID 1) + openssh + udevd.
;;
;; Build:
;;   guix system image -t docker guix/gitea-runner/config.scm > gitea-runner.tar.gz
;;   podman load < gitea-runner.tar.gz

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

  ;; specification->package avoids per-package module imports
  (packages (append (map specification->package
                         '("git" "node" "jq" "curl"))
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
