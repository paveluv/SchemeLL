;;; Minimal end-to-end demo: build IR, JIT it in memory, call it.
;;; Run with: scheme --libdirs . --script examples/jit-add.ss
;;;
;;; The `prefix` import modifier acts as a namespace: every export of
;;; (llvm ir) is visible here as ir:<name>, every export of (llvm jit) as
;;; jit:<name>. (llvm jit) exports carry no prefix of their own for exactly
;;; this reason.
(import (chezscheme)
        (prefix (llvm ir) ir:)
        (prefix (llvm jit) jit:))

(define jc (jit:make-context))
(define ctx (jit:context-ir jc))
(define mod (ir:make-module ctx "demo"))
(define b (ir:make-builder ctx))

(define i32 (ir:int32-type ctx))
(define f (ir:add-function mod "add" (ir:function-type i32 (list i32 i32))))
(ir:position-at-end! b (ir:append-block ctx f "entry"))
(ir:build-ret b (ir:build-add b (ir:function-param f 0) (ir:function-param f 1)))

(printf "generated IR:~%~a~%" (ir:module->string mod))
(ir:verify-module mod)
(ir:builder-dispose! b)

(define j (jit:make))
(jit:add-module! j jc mod)
(jit:context-dispose! jc)

(define add (jit:function j "add"))   ; a plain Scheme procedure
(printf "(add 3 4) => ~a~%" (add 3 4))
