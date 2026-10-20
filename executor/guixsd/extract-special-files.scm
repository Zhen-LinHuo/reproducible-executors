;;; Extract the special-files declaration from config.scm.
;;;
;;; config.scm is the SINGLE SOURCE of truth for which build-time symlinks the
;;; image needs. This script reads it and prints one line per unique target:
;;;
;;;     <target-path>\t<package-name>\t<file-append suffix>
;;;
;;; The CI Inject step consumes this to create the links programmatically, so
;;; the workflow never carries a hand-maintained copy of the list — which is
;;; what made Verify/Inject cross-file drift possible before.
;;;
;;; Usage:  guix repl executor/guixsd/extract-special-files.scm [path/to/config.scm]
;;; Output: tab-separated rows on stdout; progress/diagnostics on stderr.

(use-modules (gnu)
             (gnu services)
             (guix gexp)
             (guix packages)
             (srfi srfi-1)
             (ice-9 format))

;; Resolve config.scm RELATIVE TO THIS FILE so it works from any cwd. The
;; script path must be canonicalized first: a RELATIVE invocation
;; ("executor/guixsd/extract-...") makes dirname return a relative dir, which
;; load() then resolves against guix repl's own cwd (the script dir) and doubles
;; the prefix. Canonicalizing removes the cwd dependency entirely.
(define here (dirname (canonicalize-path (car (command-line)))))
(define config-path
  (let ((args (cdr (command-line))))
    (if (and (pair? args) (string? (car args)))
        (car args)
        (string-append here "/config.scm"))))

(define os (load config-path))

;; special-files services are composed with `concatenate`, so reading every
;; service of that type and appending their values yields the full merged alist
;; (config.scm's entries plus anything %base-services contributes).
(define special-files-services
  (filter (lambda (s)
            (eq? (service-kind s) special-files-service-type))
          (operating-system-services os)))

(define alist
  (apply append (map service-value special-files-services)))

;; Each value is a (list <file-append>) — the service's `extend append` shape.
(define (->file-append v)
  (cond ((record? v) v)
        ((and (list? v) (pair? v) (record? (car v))) (car v))
        (else #f)))

;; Dedupe by target: /bin/sh etc. appear once per contributing service.
(define seen (make-hash-table))
(define rows '())

(for-each
 (lambda (entry)
   (let* ((target (car entry))
          (fa (->file-append (cdr entry))))
     (cond
      ((not fa)
       (format (current-error-port)
               "warning: ~a has a non-file-append value; skipped~%" target))
      ((hash-ref seen target)
       (format (current-error-port)
               "note: duplicate target ~a; keeping first~%" target))
      (else
       (hash-set! seen target #t)
       (set! rows
             (cons (list target
                         (package-name (file-append-base fa))
                         (file-append-suffix fa))
                   rows))))))
 alist)

(set! rows (reverse rows))

(format (current-error-port) "extracted ~a unique special-files targets~%"
        (length rows))

(for-each
 (lambda (row)
   ;; suffix is written as (/bin/tar) — strip the parens so consumers get a
   ;; plain relative path inside the store item.
   (let ((suffix (caddr row)))
     (format #t "~a\t~a\t~a~%"
             (first row)
             (second row)
             (if (and (list? suffix) (= 1 (length suffix)))
                 (car suffix)
                 suffix))))
 rows)
