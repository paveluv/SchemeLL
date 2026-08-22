;;; Object-file emission: to memory and to disk.
(import (chezscheme)
        (prefix (tests harness) t:)
        (prefix (llvm ir) ir:)
        (prefix (llvm target) target:))

(t:section "target: host queries")

(t:check "default-triple" (string? (target:default-triple)))
(t:check "host-cpu-name" (string? (target:host-cpu-name)))
(t:check "host-cpu-features non-empty"
         (let ([f (target:host-cpu-features)])
           (and (string? f) (positive? (string-length f)))))

(t:section "target: emitting objects")

(define ctx (ir:make-context))
(define mod (ir:make-module ctx "obj_test"))
(define b (ir:make-builder ctx))
(define i32 (ir:int32-type ctx))
(define f (ir:add-function mod "answer" (ir:function-type i32 '())))
(ir:position-at-end! b (ir:append-block ctx f "entry"))
(ir:build-ret b (ir:const-int i32 42))
(ir:verify-module mod)

(define tm (target:make-machine))
(target:configure-module! mod tm)

(t:check "optimization passes run"
         (begin (ir:run-module-passes! mod "default<O2>") #t))

(define obj (target:emit-object-bytevector tm mod))

(define (elf? bv)
  (and (>= (bytevector-length bv) 4)
       (= (bytevector-u8-ref bv 0) #x7f)
       (= (bytevector-u8-ref bv 1) (char->integer #\E))
       (= (bytevector-u8-ref bv 2) (char->integer #\L))
       (= (bytevector-u8-ref bv 3) (char->integer #\F))))

(t:check "in-memory object is ELF" (elf? obj))
(t:check "object is non-trivial" (> (bytevector-length obj) 100))

(unless (file-directory? "tests/tmp") (mkdir "tests/tmp"))
(define obj-path "tests/tmp/answer.o")
(define asm-path "tests/tmp/answer.s")
(when (file-exists? obj-path) (delete-file obj-path))
(when (file-exists? asm-path) (delete-file asm-path))

(target:emit-object-file tm mod obj-path)
(t:check "object file written and is ELF"
         (let* ([p (open-file-input-port obj-path)]
                [bv (get-bytevector-n p 4)])
           (close-port p)
           (elf? bv)))

(target:emit-assembly-file tm mod asm-path)
(t:check "assembly file mentions the function"
         (let* ([p (open-input-file asm-path)]
                [s (get-string-all p)])
           (close-port p)
           (let ([n (string-length s)])
             (let loop ([i 0])
               (cond
                 [(> (+ i 6) n) #f]
                 [(string=? (substring s i (+ i 6)) "answer") #t]
                 [else (loop (+ i 1))])))))

(t:check-exn "emit to an unwritable path raises, not aborts"
             (target:emit-object-file tm mod "/nonexistent-dir/x.o"))

(target:machine-dispose! tm)
(t:check-exn "using a disposed target machine raises"
             (target:emit-object-bytevector tm mod))
(ir:builder-dispose! b)
(ir:module-dispose! mod)
(ir:context-dispose! ctx)
