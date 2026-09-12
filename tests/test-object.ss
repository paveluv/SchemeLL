;;; Object-file emission: to memory and to disk.
[import
 (chezscheme)
 (prefix (tests harness) t:)
 (prefix (llvm ir) ir:)
 (prefix (llvm target) target:)]

(t:section "target: host queries")

(t:check "default-triple" (string? (target:default-triple)))
(t:check "host-cpu-name" (string? (target:host-cpu-name)))
;; LLVM reports Apple Silicon's features through the CPU name (apple-m1 ...) and
;; returns an empty feature string there; x86 hosts list +sse2,... .
(t:check "host-cpu-features is a string" (string? (target:host-cpu-features)))

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

[t:check
 "optimization passes run"
 (begin (ir:run-module-passes! mod "default<O2>") #t)]

(define obj (target:emit-object-bytevector tm mod))

;; the host's relocatable object format (LLVM's default target machine follows
;; the host triple): ELF magic, Mach-O 64-bit magic, or COFF's machine field
;; (x86-64 or ARM64)
[define
 (host-object? bv)
 [and
  (>= (bytevector-length bv) 4)
  [case
   (target:native-object-format)
   ((elf) (= (bytevector-u32-ref bv 0 (endianness little)) #x464c457f))
   ((mach-o) (= (bytevector-u32-ref bv 0 (endianness little)) #xfeedfacf))
   [(coff)
    (memv (bytevector-u16-ref bv 0 (endianness little)) '(#x8664 #xaa64))]
   (else #f)]]]

(t:check "in-memory object is in the host's object format" (host-object? obj))
(t:check "object is non-trivial" (> (bytevector-length obj) 100))

(unless (file-directory? "tests/tmp") (mkdir "tests/tmp"))
(define obj-path "tests/tmp/answer.o")
(define asm-path "tests/tmp/answer.s")
(when (file-exists? obj-path) (delete-file obj-path))
(when (file-exists? asm-path) (delete-file asm-path))

(target:emit-object-file tm mod obj-path)
[t:check
 "object file written in the host's object format"
 [let*
  ((p (open-file-input-port obj-path)) (bv (get-bytevector-n p 4)))
  (close-port p)
  (host-object? bv)]]

(target:emit-assembly-file tm mod asm-path)
[t:check
 "assembly file mentions the function"
 [let*
  ((p (open-input-file asm-path)) (s (get-string-all p)))
  (close-port p)
  [let
   ((n (string-length s)))
   [let
    loop
    ((i 0))
    [cond
     ((> (+ i 6) n) #f)
     ((string=? (substring s i (+ i 6)) "answer") #t)
     (else (loop (+ i 1)))]]]]]

[t:check-exn
 "emit to an unwritable path raises, not aborts"
 (target:emit-object-file tm mod "/nonexistent-dir/x.o")]

(target:machine-dispose! tm)
[t:check-exn
 "using a disposed target machine raises"
 (target:emit-object-bytevector tm mod)]
(ir:builder-dispose! b)
(ir:module-dispose! mod)
(ir:context-dispose! ctx)

(t:section "target: non-integral datalayout + one-call pipelines")

(import (prefix (sll) sll:))

;; ni: appended by configure-module!; the parser accepts the layout
;; (verify-module passes) and the stamp is visible in the print
[let*
 [(xctx (ir:make-context))
  (m (sll:build xctx "ni" '((define void (@f) (label %e (ret void))))))
  (tm (target:make-machine))]
 (target:configure-module! m tm '(1))
 (ir:verify-module m)
 [let
  ((txt (ir:module->string m)))
  [t:check
   "configure-module! appends ni:1"
   [let
    loop
    ((i 0))
    [and
     (<= (+ i 5) (string-length txt))
     (or (string=? (substring txt i (+ i 5)) "-ni:1") (loop (+ i 1)))]]]]
 (t:check-exn "ni rejects address space 0" (target:configure-module! m tm '(0)))
 (target:machine-dispose! tm)
 (ir:module-dispose! m)
 (ir:context-dispose! xctx)]

;; sll:object / sll:assembly: build+configure+passes+verify+emit in one
[define
 pipeline-prog
 '[(declare i32 (@getpid))
   [define
    (ptr (addrspace 1))
    (@keep ((ptr (addrspace 1)) %a))
    (gc "statepoint-example")
    (label %entry (= %p (call i32 (@getpid))) (ret (ptr (addrspace 1)) %a))]]]

[let
 [[obj
   [sll:object
    pipeline-prog
    'passes
    "rewrite-statepoints-for-gc"
    'non-integral
    '(1)]]]
 (t:check "sll:object emits the host's object format" (host-object? obj))
 ;; the statepoint pass ran: the object carries a stackmap section
 ;; (.llvm_stackmaps on ELF, __LLVM_STACKMAPS,__llvm_stackmaps on Mach-O)
 [t:check
  "sll:object with statepoint passes carries a llvm_stackmaps section"
  [let*
   [(want (string->utf8 "llvm_stackmaps"))
    (wn (bytevector-length want))
    (n (bytevector-length obj))]
   [let
    loop
    ((i 0))
    [and
     (<= (+ i wn) n)
     [or
      [let
       sub
       ((k 0))
       [or
        (= k wn)
        [and
         (= (bytevector-u8-ref obj (+ i k)) (bytevector-u8-ref want k))
         (sub (+ k 1))]]]
      (loop (+ i 1))]]]]]]

[t:check
 "sll:assembly emits text containing the function"
 [let
  ((s (sll:assembly '((define i64 (@answer) (label %e (ret i64 42)))))))
  [and
   (string? s)
   [let
    loop
    ((i 0))
    [and
     (<= (+ i 6) (string-length s))
     (or (string=? (substring s i (+ i 6)) "answer") (loop (+ i 1)))]]]]]
