;;; Minimal end-to-end demo: build IR, JIT it in memory, call it.
;;; Run with: scheme --libdirs . --script examples/jit-add.ss
;;;
;;; The `prefix` import modifier acts as a namespace: every export of
;;; (llvm ir) is visible here as ir:<name>. The (llvm jit) exports already
;;; carry a jit prefix in their names (make-jit, jit-function, ...), so they
;;; are imported unprefixed.
(import (chezscheme)
        (prefix (llvm ir) ir:)
        (llvm jit))

(define jc (make-jit-context))
(define ctx (jit-context-context jc))
(define mod (ir:make-module ctx "demo"))
(define b (ir:make-builder ctx))

(define i32 (ir:int32-type ctx))
(define f (ir:add-function mod "add" (ir:function-type i32 (list i32 i32))))
(ir:position-at-end! b (ir:append-block ctx f "entry"))
(ir:build-ret b (ir:build-add b (ir:function-param f 0) (ir:function-param f 1)))

(printf "generated IR:~%~a~%" (ir:module->string mod))
(ir:verify-module mod)
(ir:builder-dispose! b)

(define j (make-jit))
(jit-add-module! j jc mod)
(jit-context-dispose! jc)

(define add (jit-function j "add"))   ; a plain Scheme procedure
(printf "(add 3 4) => ~a~%" (add 3 4))
