;;; IR construction, printing, verification, type introspection, lifetimes.
(import (chezscheme) (tests harness) (llvm ir))

(test-section "ir: building and verifying a module")

(define ctx (make-context))
(define mod (make-module ctx "test_ir"))
(define b (make-builder ctx))

(define i32 (int32-type ctx))
(define add-fn-type (function-type i32 (list i32 i32)))
(define add-fn (add-function mod "add" add-fn-type))

(position-at-end! b (append-block ctx add-fn "entry"))
(build-ret b (build-add b (function-param add-fn 0) (function-param add-fn 1) "sum"))

(check "verify-module passes on valid IR"
       (begin (verify-module mod) #t))

(check "module->string prints the function"
       (let ([ir (module->string mod)])
         (and (string? ir)
              (let ([n (string-length ir)])
                (let loop ([i 0])   ; contains "define"?
                  (cond
                    [(> (+ i 6) n) #f]
                    [(string=? (substring ir i (+ i 6)) "define") #t]
                    [else (loop (+ i 1))]))))))

(test-section "ir: type introspection")

(check "type-kind of i32 is integer" (eq? (type-kind i32) 'integer))
(check "type-int-width of i32 is 32" (= (type-int-width i32) 32))
(check "type-kind of function type" (eq? (type-kind add-fn-type) 'function))
(check "return type round-trips" (eqv? (type-return-type add-fn-type) i32))
(check "param types round-trip"
       (equal? (type-param-types add-fn-type) (list i32 i32)))
(check "function-type-of recovers the fn type (opaque ptrs)"
       (eqv? (function-type-of add-fn) add-fn-type))
(check "value-name" (string=? (value-name add-fn) "add"))
(check "named-function finds it" (eqv? (named-function mod "add") add-fn))
(check "named-function returns #f for missing" (not (named-function mod "nope")))
(check "type->string" (string=? (type->string i32) "i32"))

(test-section "ir: verify catches invalid IR")

(define bad-mod (make-module ctx "bad"))
(define bad-fn (add-function bad-mod "no_terminator" (function-type i32 '())))
(append-block ctx bad-fn "entry")  ; block with no terminator: invalid
(check-exn "verify-module raises on invalid IR" (verify-module bad-mod))
(module-dispose! bad-mod)

(test-section "ir: lifetime discipline")

(builder-dispose! b)
(check-exn "using a disposed builder raises"
           (build-ret-void b))
(module-dispose! mod)
(check-exn "using a disposed module raises"
           (module->string mod))
(check "double dispose is a no-op" (begin (module-dispose! mod) #t))
(context-dispose! ctx)
(check-exn "using a disposed context raises"
           (int32-type ctx))
