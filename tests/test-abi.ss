;;; (abi ...): raw kernel syscalls, spliced as inline asm, no libc.
;;; Oracles: getpid must agree with a second getpid (stable, positive)
;;; and write(2) to fd -1 must fail with EBADF (9) under the host's
;;; error convention -- a deterministic probe of the raw return path.
(import (chezscheme)
        (prefix (tests harness) t:)
        (prefix (sll) sll:)
        (prefix (llvm jit) jit:)
        (prefix (abi machine) abi:))

(t:section "abi: raw syscalls through the JIT")

(define prog
  `((define i64 (@pid)
      (label %entry
        ,@(abi:sys '%r (abi:sysno 'getpid))
        (ret i64 %r)))
    (define i64 (@bad_write)
      (label %entry
        ;; write(-1, NULL, 0): the fd is invalid before the buffer
        ;; or length are ever considered
        ,@(abi:sys '%r (abi:sysno 'write)
                   '(i64 -1) '(ptr null) '(i64 0))
        (ret i64 %r)))))

(define j (sll:jit prog))
(define pid (jit:function j "pid"))
(define bad-write (jit:function j "bad_write"))

(t:check "getpid returns a stable positive pid"
         (let ([a (pid)] [b (pid)])
           (and (positive? a) (= a b))))

(t:check "write to fd -1 fails with EBADF per the error convention"
         (case abi:error-convention
           [(neg-errno) (= (bad-write) -9)]      ; Linux: -EBADF
           [(carry-flag) (= (bad-write) 9)]      ; FreeBSD: errno in rax
           [else #f]))

(t:check "abi self-description is coherent"
         (and (memq abi:arch '(x86-64 arm64))
              (memq abi:os '(linux freebsd))
              (pair? abi:trap-insns)))

(t:check "constants: PROT flags are universal, MAP_ANONYMOUS is not"
         (and (= (abi:const 'prot-read) 1)
              (= (abi:const 'prot-write) 2)
              (memv (abi:const 'map-anonymous) '(#x20 #x1000))))
