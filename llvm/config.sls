;;; (llvm config) -- the only place that knows which LLVM we bind to.
;;; Version-specific facts (shared object name, version pin) live here so that
;;; moving to LLVM 20 touches this file and (llvm raw) only.
;;; Import as: (prefix (llvm config) config:)
(library (llvm config)
  (export major-version shared-object header-directory load!)
  (import (chezscheme))

  (define major-version 19)

  (define shared-object "libLLVM-19.so")

  ;; installed LLVM C API headers; the coverage oracle reads enums from
  ;; here. Locations vary by packaging: Debian's llvm-19-dev, generic
  ;; LLVM layouts, the FreeBSD llvm19 port. First hit wins; raises with
  ;; the full candidate list when none exists.
  (define header-candidates
    '("/usr/include/llvm-c-19/llvm-c"
      "/usr/lib/llvm-19/include/llvm-c"
      "/usr/local/llvm19/include/llvm-c"
      "/usr/local/include/llvm-c"
      "/usr/include/llvm-c"))

  ;; a string (consumers string-append onto it); when nothing matches,
  ;; the first candidate stands in so the eventual file error names a
  ;; real, installable path
  (define header-directory
    (let loop ([cands header-candidates])
      (cond
        [(null? cands) (car header-candidates)]
        [(file-exists? (string-append (car cands) "/Core.h")) (car cands)]
        [else (loop (cdr cands))])))

  (define loaded? #f)

  ;; Idempotent; must be called before any foreign-procedure in (llvm raw)
  ;; is evaluated. (llvm raw) calls it as its first definition.
  (define (load!)
    (unless loaded?
      (load-shared-object shared-object)
      (set! loaded? #t))))
