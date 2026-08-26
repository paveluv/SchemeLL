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
  (export make-sys make-sys/cf make-trap make-sys-fns
          default-syscall-fns errcheck lookup)
  (import (chezscheme)
          (prefix (sll) sll:)
          (prefix (sll asm) asm:))

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

  ;; Like make-sys, but the splice captures the CARRY FLAG as a
  ;; second output via LLVM's ={@ccc} flag-output constraint: the
  ;; result binds a (struct i64 i8) -- raw return and CF. This is
  ;; how carry-flag OSes (FreeBSD) report errors; the plumbing is
  ;; testable kernel-free with stc/clc (see tests/test-abi.ss).
  (define (make-sys/cf instr nr-reg ret-reg arg-regs clobbers)
    (lambda (res nr . args)
      (let ([callee (asm:expr
                      (list `(out (reg ,ret-reg))
                            '(out "{@ccc}")
                            `(in (reg ,nr-reg))
                            (map (lambda (r) `(in (reg ,r)))
                                 (list-head arg-regs (length args)))
                            `(clobber ,@clobbers memory))
                      instr
                      'sideeffect)])
        `((= ,res (call (struct i64 i8) (,callee (i64 ,nr) ,@args)))))))

  ;; (make-trap instr) -> insns that kill the process where they
  ;; execute (the freestanding abort: no signal machinery, just an
  ;; instruction the CPU refuses)
  (define (make-trap instr)
    `((call void ((asm ,instr "" sideeffect)))
      (unreachable)))

  ;; ---- the function layer -------------------------------------------
  ;; @sys_NAME sll functions mirroring libc's syscall wrappers:
  ;; uniform i64 arguments, i64 return NORMALIZED to the Linux
  ;; convention on every OS -- error iff the return is in [-4095,-1]
  ;; (-errno). On neg-errno OSes the body is the raw splice; on
  ;; carry-flag OSes it captures CF and selects -errno branchlessly.
  ;; A call wrapping a 50-500ns syscall costs nothing, and O2 inlines
  ;; it anyway; exit stays on the raw splicer (noreturn).

  (define default-syscall-fns   ; (name . arity)
    '((mmap . 6) (munmap . 2) (mprotect . 3)
      (read . 3) (write . 3) (close . 1)
      (getpid . 0) (kill . 2)))

  (define (make-sys-fns instr nr-reg ret-reg arg-regs clobbers
                        norm sysno fns)
    (let ([sys (make-sys instr nr-reg ret-reg arg-regs clobbers)]
          [sys/cf (make-sys/cf instr nr-reg ret-reg arg-regs clobbers)])
      (map
        (lambda (nf)
          (let* ([nm (car nf)] [arity (cdr nf)]
                 [params (map (lambda (i) (sll:name '%a i))
                              (iota arity))]
                 [groups (map (lambda (p) `(i64 ,p)) params)]
                 [fname (sll:name '@sys_ nm)])
            `(define i64 (,fname ,@groups)
               (label %entry
                 ,@(case norm
                     [(neg-errno)
                      (append (apply sys '%r (sysno nm) groups)
                              '((ret i64 %r)))]
                     [(carry-flag)
                      (append
                        (apply sys/cf '%rs (sysno nm) groups)
                        '((= %val (extractvalue ((struct i64 i8) %rs) 0))
                          (= %cf (extractvalue ((struct i64 i8) %rs) 1))
                          (= %err (icmp ne i8 %cf 0))
                          (= %neg (sub i64 0 %val))
                          (= %r (select (i1 %err) (i64 %neg) (i64 %val)))
                          (ret i64 %r)))]
                     [else (assertion-violation 'make-sys-fns
                             "unknown error convention" norm)])))))
        fns)))

  ;; the one-insn error test for the NORMALIZED convention:
  ;; (errcheck '%failed '%r) -- true iff %r is -errno
  (define (errcheck failed res)
    `((= ,failed (icmp ugt i64 ,res -4096))))

  (define (lookup who table name)
    (cond
      [(assq name table) => cdr]
      [else (assertion-violation who "unknown name" name)])))
