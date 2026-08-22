;;; (llvm config) -- the only place that knows which LLVM we bind to.
;;; Version-specific facts (shared object name, version pin) live here so that
;;; moving to LLVM 20 touches this file and (llvm raw) only.
;;; Import as: (prefix (llvm config) config:)
(library (llvm config)
  (export major-version shared-object header-directory load!)
  (import (chezscheme))

  (define major-version 19)

  (define shared-object "libLLVM-19.so")

  ;; installed LLVM C API headers; the coverage oracle reads enums from here
  (define header-directory "/usr/include/llvm-c-19/llvm-c")

  (define loaded? #f)

  ;; Idempotent; must be called before any foreign-procedure in (llvm raw)
  ;; is evaluated. (llvm raw) calls it as its first definition.
  (define (load!)
    (unless loaded?
      (load-shared-object shared-object)
      (set! loaded? #t))))
