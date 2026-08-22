;;; In-memory JIT: build IR, compile, call as Scheme procedures. No files.
(import (chezscheme) (tests harness) (llvm ir) (llvm jit))

(test-section "jit: add(i32,i32) end to end")

(define jc (make-jit-context))
(define ctx (jit-context-context jc))
(define mod (make-module ctx "jit_test"))
(define b (make-builder ctx))

(define i32 (int32-type ctx))
(define i64 (int64-type ctx))
(define f64 (double-type ctx))

;; add(x, y) = x + y
(define add-fn (add-function mod "add" (function-type i32 (list i32 i32))))
(position-at-end! b (append-block ctx add-fn "entry"))
(build-ret b (build-add b (function-param add-fn 0) (function-param add-fn 1)))

;; fact(n) = n < 2 ? 1 : n * fact(n - 1)   -- exercises call2/cond-br/recursion
(define fact-type (function-type i64 (list i64)))
(define fact-fn (add-function mod "fact" fact-type))
(let* ([entry (append-block ctx fact-fn "entry")]
       [base (append-block ctx fact-fn "base")]
       [rec (append-block ctx fact-fn "rec")]
       [n (function-param fact-fn 0)])
  (position-at-end! b entry)
  (build-cond-br b (build-icmp b 'slt n (const-int i64 2)) base rec)
  (position-at-end! b base)
  (build-ret b (const-int i64 1))
  (position-at-end! b rec)
  (let ([n-1 (build-sub b n (const-int i64 1))])
    (build-ret b (build-mul b n (build-call b fact-type fact-fn (list n-1))))))

;; hypot2(x, y) = x*x + y*y  -- doubles
(define hypot2-fn (add-function mod "hypot2" (function-type f64 (list f64 f64))))
(let ([x (function-param hypot2-fn 0)]
      [y (function-param hypot2-fn 1)])
  (position-at-end! b (append-block ctx hypot2-fn "entry"))
  (build-ret b (build-fadd b (build-fmul b x x) (build-fmul b y y))))

(verify-module mod)
(builder-dispose! b)

(define j (make-jit))
(jit-add-module! j jc mod)

(check "module is consumed after jit-add-module!"
       (guard (e [#t #t]) (module->string mod) #f))

(define add (jit-function j "add"))
(check "add: (add 3 4) = 7" (= (add 3 4) 7))
(check "add: negative operands" (= (add -10 3) -7))
(check "add: i32 wraparound" (= (add #x7fffffff 1) (- #x80000000)))

(define fact (jit-function j "fact"))
(check "fact: recursion, (fact 20)" (= (fact 20) 2432902008176640000))
(check "fact: base case" (= (fact 0) 1))

(define hypot2 (jit-function j "hypot2"))
(check "hypot2: doubles" (= (hypot2 3.0 4.0) 25.0))

(test-section "jit: lookups and errors")

(check "jit-lookup-address returns a nonzero address"
       (positive? (jit-lookup-address j "add")))
(check-exn "jit-function raises for unknown name"
           (jit-function j "no_such_fn"))

(test-section "jit: two modules, one jit")

(define mod2 (make-module ctx "jit_test2"))
(define b2 (make-builder ctx))
;; add3(x) = add(x, 3) -- cross-module call into the first module
(define add-decl (add-function mod2 "add" (function-type i32 (list i32 i32))))
(define add3-fn (add-function mod2 "add3" (function-type i32 (list i32))))
(position-at-end! b2 (append-block ctx add3-fn "entry"))
(build-ret b2 (build-call b2 (function-type i32 (list i32 i32)) add-decl
                          (list (function-param add3-fn 0) (const-int i32 3))))
(verify-module mod2)
(builder-dispose! b2)
(jit-add-module! j jc mod2)

(check "cross-module call: (add3 39) = 42"
       (= ((jit-function j "add3") 39) 42))
(check "declarations don't shadow signatures"
       (= (add 1 1) 2))

(test-section "jit: disposal")

(jit-context-dispose! jc)
(check "explicit jit-dispose!" (begin (jit-dispose! j) #t))
(check-exn "calling a procedure from a disposed jit raises" (add 1 2))
(check-exn "lookup on a disposed jit raises" (jit-lookup-address j "add"))
