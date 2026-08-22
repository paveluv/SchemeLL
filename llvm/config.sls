;;; (llvm config) -- the only place that knows which LLVM we bind to.
;;; Version-specific facts (shared object name, version pin) live here so that
;;; moving to LLVM 20 touches this file and (llvm raw) only.
(library (llvm config)
  (export llvm-major-version llvm-shared-object load-llvm!)
  (import (chezscheme))

  (define llvm-major-version 19)

  (define llvm-shared-object "libLLVM-19.so")

  (define loaded? #f)

  ;; Idempotent; must be called before any foreign-procedure in (llvm raw)
  ;; is evaluated. (llvm raw) calls it as its first definition.
  (define (load-llvm!)
    (unless loaded?
      (load-shared-object llvm-shared-object)
      (set! loaded? #t))))
