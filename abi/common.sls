#!chezscheme
;;; (abi common) -- the machine-independent half of the freestanding
;;; kernel ABI: splice generators for raw syscalls and traps, built
;;; on (sll asm). Per-machine-type modules (abi a6le) etc. supply the
;;; descriptors and tables; (abi machine) selects the compiling
;;; host's. No libc anywhere: the end state is Meik/Woof/SchemeLL on
;;; a bare kernel.
;;;
;;; Layering: this is raw.sls for the kernel -- numbers and splices,
;;; verbatim, no interpretation. Safe wrappers belong to higher
;;; layers (Woof stdlib, Meik runtime), not here.
(library (abi common)
  (export make-sys make-trap lookup)
  (import (chezscheme) (prefix (sll asm) asm:))

  ;; (make-sys instr nr-reg ret-reg arg-regs clobbers) -> sys
  ;; (sys res nr arg-group ...) -> sll insns for one raw syscall:
  ;;   res is %name to bind the raw return (an i64), or #f to drop it;
  ;;   nr is the syscall number (callers resolve names via sysno);
  ;;   arg-groups are ordinary sll operand groups, e.g. (i64 %len).
  ;; The return value is RAW: error conventions differ per OS (see
  ;; each module's error-convention) and are the caller's business.
  (define (make-sys instr nr-reg ret-reg arg-regs clobbers)
    (lambda (res nr . args)
      (unless (or (not res) (symbol? res))
        (assertion-violation 'sys "result must be a %name or #f" res))
      (unless (<= (length args) (length arg-regs))
        (assertion-violation 'sys "too many syscall arguments"
                             (length args)))
      (let ([callee (asm:expr
                      (list `(out (reg ,ret-reg))
                            `(in (reg ,nr-reg))
                            (map (lambda (r) `(in (reg ,r)))
                                 (list-head arg-regs (length args)))
                            `(clobber ,@clobbers memory))
                      instr
                      'sideeffect)])
        (if res
            `((= ,res (call i64 (,callee (i64 ,nr) ,@args))))
            `((call i64 (,callee (i64 ,nr) ,@args)))))))

  ;; (make-trap instr) -> insns that kill the process where they
  ;; execute (the freestanding abort: no signal machinery, just an
  ;; instruction the CPU refuses)
  (define (make-trap instr)
    `((call void ((asm ,instr "" sideeffect)))
      (unreachable)))

  (define (lookup who table name)
    (cond
      [(assq name table) => cdr]
      [else (assertion-violation who "unknown name" name)])))
