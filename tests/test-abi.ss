;;; (abi ...): raw kernel syscalls, spliced as inline asm, no libc.
;;; Oracles: getpid must agree with a second getpid (stable, positive)
;;; and write(2) to fd -1 must fail with EBADF (9) under the host's
;;; error convention -- a deterministic probe of the raw return path.
(import (chezscheme)
        (prefix (tests harness) t:)
        (prefix (sll) sll:)
        (prefix (llvm jit) jit:)
        (prefix (abi machine) abi:)
        (prefix (sll asm) asm:))

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

(t:section "abi: the @sys_* function layer (normalized -errno)")

(define fprog
  `(,@abi:sys-fn-items
     (define i64 (@fpid)
       (label %entry
         (= %r (call i64 (@sys_getpid)))
         (ret i64 %r)))
     (define i64 (@fbad)
       (label %entry
         (= %r (call i64 (@sys_write (i64 -1) (i64 0) (i64 0))))
         ,@(abi:errcheck '%failed '%r)
         (= %f64 (zext i1 %failed i64))
         (= %packed (shl i64 %f64 32))
         (= %lo (and i64 %r 4294967295))
         (= %out (or i64 %packed %lo))
         (ret i64 %out)))))

(let* ([j (sll:jit fprog)]
       [fpid (jit:function j "fpid")]
       [fbad (jit:function j "fbad")])
  (t:check "@sys_getpid agrees with the raw splice"
           (= (fpid) (pid)))
  (t:check "@sys_write to fd -1: -EBADF, and errcheck sees it"
           (let* ([out (fbad)]
                  [failed (bitwise-arithmetic-shift-right out 32)]
                  [lo (bitwise-and out 4294967295)])
             (and (= failed 1)
                  ;; low 32 bits of -9
                  (= lo 4294967287)))))

;; carry-flag plumbing, kernel-free: stc/clc set CF deterministically
(when (eq? abi:arch 'x86-64)
  (let* ([cfprog
          `((define i8 (@rd_stc)
              (label %entry
                (= %c (call i8 (,(asm:expr '((out "{@ccc}")) "stc"
                                           'sideeffect))))
                (ret i8 %c)))
            (define i8 (@rd_clc)
              (label %entry
                (= %c (call i8 (,(asm:expr '((out "{@ccc}")) "clc"
                                           'sideeffect))))
                (ret i8 %c)))
            ;; two outputs: value in rax + CF, the sys/cf shape
            (define i64 (@both)
              (label %entry
                (= %rs (call (struct i64 i8)
                             (,(asm:expr '((out (reg rax))
                                           (out "{@ccc}"))
                                         "movq $$42, %rax; stc"
                                         'sideeffect))))
                (= %v (extractvalue ((struct i64 i8) %rs) 0))
                (= %c (extractvalue ((struct i64 i8) %rs) 1))
                (= %c64 (zext i8 %c i64))
                (= %sum (add i64 %v %c64))
                (ret i64 %sum))))]
         [j2 (sll:jit cfprog)])
    (t:check "={@ccc} reads a set carry flag"
             (= 1 ((jit:function j2 "rd_stc"))))
    (t:check "={@ccc} reads a cleared carry flag"
             (= 0 ((jit:function j2 "rd_clc"))))
    (t:check "two-output asm: {rax, CF} as a struct"
             (= 43 ((jit:function j2 "both"))))))

;; the FreeBSD generator is importable and compilable ANYWHERE on
;; x86-64 (only its numbers and error convention are FreeBSD's):
;; verify its function layer builds and carries the ={@ccc} capture
(when (eq? abi:arch 'x86-64)
  (let ([txt (sll:dump
               (let ()
                 (import (prefix (abi a6fb) fb:))
                 fb:sys-fn-items))])
    (t:check "a6fb function layer builds; carry capture present"
             (let loop ([i 0])
               (and (<= (+ i 6) (string-length txt))
                    (or (string=? (substring txt i (+ i 6)) "={@ccc")
                        (loop (+ i 1))))))))
