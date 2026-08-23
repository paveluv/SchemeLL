;;; The (llvm ir) builder layer by hand: blocks, a phi loop, and the
;;; printer -- everything sll:build does, spelled out.
(import (chezscheme) (prefix (llvm ir) ir:))

(define ctx (ir:make-context))
(define m (ir:make-module ctx "tour"))
(define b (ir:make-builder ctx))
(define i64 (ir:int64-type ctx))

(define f (ir:add-function m "count_down" (ir:function-type i64 (list i64))))
(define entry (ir:append-block ctx f "entry"))
(define loop (ir:append-block ctx f "loop"))
(define exit (ir:append-block ctx f "exit"))

(ir:position-at-end! b entry)
(ir:build-br b loop)

(ir:position-at-end! b loop)
(define n (ir:build-phi b i64 "n"))
(define steps (ir:build-phi b i64 "steps"))
(define n1 (ir:build-sub b n (ir:const-int i64 1) "n1"))
(define steps1 (ir:build-add b steps (ir:const-int i64 1) "steps1"))
(define done (ir:build-icmp b 'sle n1 (ir:const-int i64 0) "done"))
(ir:build-cond-br b done exit loop)

;; phi incoming are wired AFTER the blocks exist: (value . block) pairs
(ir:phi-add-incoming! n (list (cons (ir:function-param f 0) entry)
                              (cons n1 loop)))
(ir:phi-add-incoming! steps (list (cons (ir:const-int i64 0) entry)
                                  (cons steps1 loop)))

(ir:position-at-end! b exit)
(ir:build-ret b steps1)

(ir:verify-module m)
(display (ir:module->string m))
