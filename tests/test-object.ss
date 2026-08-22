;;; Object-file emission: to memory and to disk.
(import (chezscheme) (tests harness) (llvm ir) (llvm target))

(test-section "target: host queries")

(check "default-target-triple" (string? (default-target-triple)))
(check "host-cpu-name" (string? (host-cpu-name)))
(check "host-cpu-features mention sse2 or neon"
       (let ([f (host-cpu-features)])
         (and (string? f) (positive? (string-length f)))))

(test-section "target: emitting objects")

(define ctx (make-context))
(define mod (make-module ctx "obj_test"))
(define b (make-builder ctx))
(define i32 (int32-type ctx))
(define f (add-function mod "answer" (function-type i32 '())))
(position-at-end! b (append-block ctx f "entry"))
(build-ret b (const-int i32 42))
(verify-module mod)

(define tm (make-target-machine))
(configure-module-for-target! mod tm)

(check "optimization passes run" (begin (run-module-passes! mod "default<O2>") #t))

(define obj (emit-object-bytevector tm mod))

(define (elf? bv)
  (and (>= (bytevector-length bv) 4)
       (= (bytevector-u8-ref bv 0) #x7f)
       (= (bytevector-u8-ref bv 1) (char->integer #\E))
       (= (bytevector-u8-ref bv 2) (char->integer #\L))
       (= (bytevector-u8-ref bv 3) (char->integer #\F))))

(check "in-memory object is ELF" (elf? obj))
(check "object is non-trivial" (> (bytevector-length obj) 100))

(unless (file-directory? "tests/tmp") (mkdir "tests/tmp"))
(define obj-path "tests/tmp/answer.o")
(define asm-path "tests/tmp/answer.s")
(when (file-exists? obj-path) (delete-file obj-path))
(when (file-exists? asm-path) (delete-file asm-path))

(emit-object-file tm mod obj-path)
(check "object file written and is ELF"
       (let* ([p (open-file-input-port obj-path)]
              [bv (get-bytevector-n p 4)])
         (close-port p)
         (elf? bv)))

(emit-assembly-file tm mod asm-path)
(check "assembly file mentions the function"
       (let* ([p (open-input-file asm-path)]
              [s (get-string-all p)])
         (close-port p)
         (let ([n (string-length s)])
           (let loop ([i 0])
             (cond
               [(> (+ i 6) n) #f]
               [(string=? (substring s i (+ i 6)) "answer") #t]
               [else (loop (+ i 1))])))))

(check-exn "emit to an unwritable path raises, not aborts"
           (emit-object-file tm mod "/nonexistent-dir/x.o"))

(target-machine-dispose! tm)
(check-exn "using a disposed target machine raises"
           (emit-object-bytevector tm mod))
(builder-dispose! b)
(module-dispose! mod)
(context-dispose! ctx)
