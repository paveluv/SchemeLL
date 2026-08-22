;;; IR construction, printing, verification, type introspection, lifetimes.
(import (chezscheme)
        (prefix (tests harness) t:)
        (prefix (llvm ir) ir:))

(t:section "ir: building and verifying a module")

(define ctx (ir:make-context))
(define mod (ir:make-module ctx "test_ir"))
(define b (ir:make-builder ctx))

(define i32 (ir:int32-type ctx))
(define add-fn-type (ir:function-type i32 (list i32 i32)))
(define add-fn (ir:add-function mod "add" add-fn-type))

(ir:position-at-end! b (ir:append-block ctx add-fn "entry"))
(ir:build-ret b (ir:build-add b (ir:function-param add-fn 0)
                              (ir:function-param add-fn 1) "sum"))

(t:check "verify-module passes on valid IR"
         (begin (ir:verify-module mod) #t))

(t:check "module->string prints the function"
         (let ([ir-text (ir:module->string mod)])
           (and (string? ir-text)
                (let ([n (string-length ir-text)])
                  (let loop ([i 0])   ; contains "define"?
                    (cond
                      [(> (+ i 6) n) #f]
                      [(string=? (substring ir-text i (+ i 6)) "define") #t]
                      [else (loop (+ i 1))]))))))

(t:section "ir: type introspection")

(t:check "type-kind of i32 is integer" (eq? (ir:type-kind i32) 'integer))
(t:check "type-int-width of i32 is 32" (= (ir:type-int-width i32) 32))
(t:check "type-kind of function type" (eq? (ir:type-kind add-fn-type) 'function))
(t:check "return type round-trips" (eqv? (ir:type-return-type add-fn-type) i32))
(t:check "param types round-trip"
         (equal? (ir:type-param-types add-fn-type) (list i32 i32)))
(t:check "function-type-of recovers the fn type (opaque ptrs)"
         (eqv? (ir:function-type-of add-fn) add-fn-type))
(t:check "value-name" (string=? (ir:value-name add-fn) "add"))
(t:check "named-function finds it" (eqv? (ir:named-function mod "add") add-fn))
(t:check "named-function returns #f for missing" (not (ir:named-function mod "nope")))
(t:check "type->string" (string=? (ir:type->string i32) "i32"))

(t:section "ir: verify catches invalid IR")

(define bad-mod (ir:make-module ctx "bad"))
(define bad-fn (ir:add-function bad-mod "no_terminator" (ir:function-type i32 '())))
(ir:append-block ctx bad-fn "entry")  ; block with no terminator: invalid
(t:check-exn "verify-module raises on invalid IR" (ir:verify-module bad-mod))
(ir:module-dispose! bad-mod)

(t:section "ir: lifetime discipline")

(ir:builder-dispose! b)
(t:check-exn "using a disposed builder raises"
             (ir:build-ret-void b))
(ir:module-dispose! mod)
(t:check-exn "using a disposed module raises"
             (ir:module->string mod))
(t:check "double dispose is a no-op" (begin (ir:module-dispose! mod) #t))
(ir:context-dispose! ctx)
(t:check-exn "using a disposed context raises"
             (ir:int32-type ctx))
