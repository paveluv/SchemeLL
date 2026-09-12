;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; The verifier and error discipline: broken IR raises a Scheme condition with
;;; LLVM's diagnosis, instead of crashing.
(import (chezscheme) (prefix (llvm ir) ir:))

(define ctx (ir:make-context))
(define m (ir:make-module ctx "broken"))
(define b (ir:make-builder ctx))
(define i64 (ir:int64-type ctx))

;; a function whose block has no terminator: invalid IR
(define f (ir:add-function m "broken" (ir:function-type i64 '())))
(ir:position-at-end! b (ir:append-block ctx f "entry"))
(ir:build-add b (ir:const-int i64 1) (ir:const-int i64 2))

[guard
 (e (#t (printf "verifier said:~%~a~%" (condition-message e))))
 (ir:verify-module m)
 (printf "unexpectedly verified?!~%")]
