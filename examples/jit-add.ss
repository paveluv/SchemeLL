;;; Minimal end-to-end demo: build IR, JIT it in memory, call it.
;;; Run with: scheme --libdirs . --script examples/jit-add.ss
(import (chezscheme) (llvm ir) (llvm jit))

(define jc (make-jit-context))
(define ctx (jit-context-context jc))
(define mod (make-module ctx "demo"))
(define b (make-builder ctx))

(define i32 (int32-type ctx))
(define f (add-function mod "add" (function-type i32 (list i32 i32))))
(position-at-end! b (append-block ctx f "entry"))
(build-ret b (build-add b (function-param f 0) (function-param f 1)))

(printf "generated IR:~%~a~%" (module->string mod))
(verify-module mod)
(builder-dispose! b)

(define j (make-jit))
(jit-add-module! j jc mod)
(jit-context-dispose! jc)

(define add (jit-function j "add"))   ; a plain Scheme procedure
(printf "(add 3 4) => ~a~%" (add 3 4))
