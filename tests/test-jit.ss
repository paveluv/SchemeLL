;;; In-memory JIT: build IR, compile, call as Scheme procedures. No files.
[import
 (chezscheme)
 (prefix (tests harness) t:)
 (prefix (llvm ir) ir:)
 (prefix (llvm jit) jit:)]

(t:section "jit: add(i32,i32) end to end")

(define jc (jit:make-context))
(define ctx (jit:context-ir jc))
(define mod (ir:make-module ctx "jit_test"))
(define b (ir:make-builder ctx))

(define i32 (ir:int32-type ctx))
(define i64 (ir:int64-type ctx))
(define f64 (ir:double-type ctx))

;; add(x, y) = x + y
[define
 add-fn
 (ir:add-function mod "add" (ir:function-type i32 (list i32 i32)))]
(ir:position-at-end! b (ir:append-block ctx add-fn "entry"))
[ir:build-ret
 b
 (ir:build-add b (ir:function-param add-fn 0) (ir:function-param add-fn 1))]

;; fact(n) = n < 2 ? 1 : n * fact(n - 1) -- exercises call2/cond-br/recursion
(define fact-type (ir:function-type i64 (list i64)))
(define fact-fn (ir:add-function mod "fact" fact-type))
[let*
 [(entry (ir:append-block ctx fact-fn "entry"))
  (base (ir:append-block ctx fact-fn "base"))
  (rec (ir:append-block ctx fact-fn "rec"))
  (n (ir:function-param fact-fn 0))]
 (ir:position-at-end! b entry)
 (ir:build-cond-br b (ir:build-icmp b 'slt n (ir:const-int i64 2)) base rec)
 (ir:position-at-end! b base)
 (ir:build-ret b (ir:const-int i64 1))
 (ir:position-at-end! b rec)
 [let
  ((n-1 (ir:build-sub b n (ir:const-int i64 1))))
  [ir:build-ret
   b
   (ir:build-mul b n (ir:build-call b fact-type fact-fn (list n-1)))]]]

;; hypot2(x, y) = x*x + y*y -- doubles
[define
 hypot2-fn
 (ir:add-function mod "hypot2" (ir:function-type f64 (list f64 f64)))]
[let
 ((x (ir:function-param hypot2-fn 0)) (y (ir:function-param hypot2-fn 1)))
 (ir:position-at-end! b (ir:append-block ctx hypot2-fn "entry"))
 (ir:build-ret b (ir:build-fadd b (ir:build-fmul b x x) (ir:build-fmul b y y)))]

(ir:verify-module mod)
(ir:builder-dispose! b)

(define j (jit:make))
[t:check
 "JIT exposes its actual host triple and layout before any module"
 [and
  (string=? (jit:target-triple j) (target:default-triple))
  (positive? (string-length (jit:data-layout j)))
  (member '(non-integral 3) (dl:parse (jit:data-layout j '(3))))]]
(jit:add-module! j jc mod)

[t:check
 "module is consumed after jit:add-module!"
 (guard (e (#t #t)) (ir:module->string mod) #f)]

(define add (jit:function j "add"))
(t:check "add: (add 3 4) = 7" (= (add 3 4) 7))
(t:check "add: negative operands" (= (add -10 3) -7))
(t:check "add: i32 wraparound" (= (add #x7fffffff 1) (- #x80000000)))

(define fact (jit:function j "fact"))
(t:check "fact: recursion, (fact 20)" (= (fact 20) 2432902008176640000))
(t:check "fact: base case" (= (fact 0) 1))

(define hypot2 (jit:function j "hypot2"))
(t:check "hypot2: doubles" (= (hypot2 3.0 4.0) 25.0))

(t:section "jit: i1 is a 0/1 byte")

;; Chez boolean would treat Scheme 0 as true and pass 1.
[let*
 [(jc1 (jit:make-context))
  (ctx1 (jit:context-ir jc1))
  (m1 (ir:make-module ctx1 "i1"))
  (b1 (ir:make-builder ctx1))
  (i1 (ir:int1-type ctx1))
  (i64 (ir:int64-type ctx1))
  (sel-ty (ir:function-type i64 (list i1 i64 i64)))
  (sel-fn (ir:add-function m1 "sel" sel-ty))]
 (ir:position-at-end! b1 (ir:append-block ctx1 sel-fn "entry"))
 [ir:build-ret
  b1
  [ir:build-select
   b1
   (ir:function-param sel-fn 0)
   (ir:function-param sel-fn 1)
   (ir:function-param sel-fn 2)]]
 (ir:verify-module m1)
 (ir:builder-dispose! b1)
 [let
  ((j1 (jit:make)))
  (jit:add-module! j1 jc1 m1)
  (jit:context-dispose! jc1)
  [let
   ((sel (jit:function j1 "sel")))
   (t:check "i1 0 selects the false operand" (= (sel 0 10 20) 20))
   (t:check "i1 1 selects the true operand" (= (sel 1 10 20) 10))]]]

;; an un-annotated i1 return only defines bit 0 (x86-64 promotes it with anyext,
;; so trunc i8 2 to i1 comes back as the byte 2); jit:function masks the result
;; to 0/1
[let*
 [(jc2 (jit:make-context))
  (ctx2 (jit:context-ir jc2))
  (m2 (ir:make-module ctx2 "i1ret"))
  (b2 (ir:make-builder ctx2))
  (i1 (ir:int1-type ctx2))
  (i8 (ir:int8-type ctx2))
  (low-fn (ir:add-function m2 "low" (ir:function-type i1 (list i8))))]
 (ir:position-at-end! b2 (ir:append-block ctx2 low-fn "entry"))
 (ir:build-ret b2 (ir:build-trunc b2 (ir:function-param low-fn 0) i1 ""))
 (ir:verify-module m2)
 (ir:builder-dispose! b2)
 [let
  ((j2 (jit:make)))
  (jit:add-module! j2 jc2 m2)
  (jit:context-dispose! jc2)
  [let
   ((low (jit:function j2 "low")))
   (t:check "i1 result is masked: trunc i8 2 is 0" (= (low 2) 0))
   (t:check "i1 result is masked: trunc i8 3 is 1" (= (low 3) 1))
   (t:check "i1 result is masked: trunc i8 255 is 1" (= (low 255) 1))]]]

(t:section "jit: lookups and errors")

[t:check
 "jit:lookup-address returns a nonzero address"
 (positive? (jit:lookup-address j "add"))]
[t:check-exn
 "jit:function raises for unknown name"
 (jit:function j "no_such_fn")]
(t:check "predicates" (and (jit:jit? j) (jit:context? jc)))

(t:section "jit: two modules, one jit")

(define mod2 (ir:make-module ctx "jit_test2"))
(define b2 (ir:make-builder ctx))
;; add3(x) = add(x, 3) -- cross-module call into the first module
[define
 add-decl
 (ir:add-function mod2 "add" (ir:function-type i32 (list i32 i32)))]
(define add3-fn (ir:add-function mod2 "add3" (ir:function-type i32 (list i32))))
(ir:position-at-end! b2 (ir:append-block ctx add3-fn "entry"))
[ir:build-ret
 b2
 [ir:build-call
  b2
  (ir:function-type i32 (list i32 i32))
  add-decl
  (list (ir:function-param add3-fn 0) (ir:const-int i32 3))]]
(ir:verify-module mod2)
(ir:builder-dispose! b2)
(jit:add-module! j jc mod2)

[t:check
 "cross-module call: (add3 39) = 42"
 (= ((jit:function j "add3") 39) 42)]
(t:check "declarations don't shadow signatures" (= (add 1 1) 2))

(t:section "jit: disposal")

(jit:context-dispose! jc)
(t:check "explicit jit:dispose!" (begin (jit:dispose! j) #t))
(t:check-exn "calling a procedure from a disposed jit raises" (add 1 2))
(t:check-exn "lookup on a disposed jit raises" (jit:lookup-address j "add"))

(t:section "jit: host-platform guard")

;; a module declaring a foreign target must be refused: the JIT compiles for
;; THIS machine. wasm32 is never a Chez host; aarch64-linux would be the host on
;; that platform and would not exercise the guard.
[let*
 [(jc (jit:make-context))
  (ctx (jit:context-ir jc))
  (m (ir:make-module ctx "foreign"))
  (j (jit:make))]
 (ir:set-module-target-triple! m "wasm32-unknown-wasi")
 (t:check-exn "jit refuses a foreign-triple module" (jit:add-module! j jc m))
 (jit:context-dispose! jc)]

[let*
 [(jc (jit:make-context))
  (ctx (jit:context-ir jc))
  (m (ir:make-module ctx "haiku"))
  (j (jit:make))
  (host (jit:target-triple j))
  [arch
   [let
    loop
    ((i 0))
    [cond
     ((= i (string-length host)) host)
     ((char=? (string-ref host i) #\-) (substring host 0 i))
     (else (loop (+ i 1)))]]]]
 (ir:set-module-target-triple! m (string-append arch "-unknown-haiku"))
 (t:check-exn "jit refuses an unknown-OS triple" (jit:add-module! j jc m))
 (jit:context-dispose! jc)]

;; the guard's predicate is exported for callers that restamp a module's triple
;; with the host's before add-module! (sllc --run --opt)
[let
 ((j (jit:make)))
 [t:check
  "host-triple-compatible?: the host, no triple, a foreign platform"
  [and
   (jit:host-triple-compatible? (jit:target-triple j))
   (jit:host-triple-compatible? "")
   (not (jit:host-triple-compatible? "wasm32-unknown-wasi"))]]]

[let*
 [(jc (jit:make-context))
  (ctx (jit:context-ir jc))
  (m (ir:make-module ctx "alias"))
  (j (jit:make))
  (host (jit:target-triple j))
  [aliased
   [cond
    [[let
      loop
      ((i 0))
      [and
       (<= (+ i 7) (string-length host))
       (or (string=? (substring host i (+ i 7)) "aarch64") (loop (+ i 1)))]]
     [let
      loop
      ((i 0))
      [cond
       ((> (+ i 7) (string-length host)) host)
       [(string=? (substring host i (+ i 7)) "aarch64")
        (string-append (substring host 0 i) "arm64" (substring host (+ i 7)))]
       (else (loop (+ i 1)))]]]
    [[let
      loop
      ((i 0))
      [and
       (<= (+ i 5) (string-length host))
       (or (string=? (substring host i (+ i 5)) "arm64") (loop (+ i 1)))]]
     [let
      loop
      ((i 0))
      [cond
       ((> (+ i 5) (string-length host)) host)
       [(string=? (substring host i (+ i 5)) "arm64")
        (string-append (substring host 0 i) "aarch64" (substring host (+ i 5)))]
       (else (loop (+ i 1)))]]]
    (else host)]]]
 (ir:set-module-target-triple! m aliased)
 [if
  (string=? aliased host)
  (t:check "no aarch64/arm64 alias to probe on this host" #t)
  [t:check
   "arm64 and aarch64 are the same JIT host"
   (begin (jit:add-module! j jc m) #t)]]
 (jit:context-dispose! jc)]

(t:section "jit: diagnostics")

;; inline-asm parse errors report SUCCESS plus an error-severity diagnostic; the
;; capture + post-materialization check must turn that into a raised condition
[let*
 [(jc (jit:make-context))
  (ctx (jit:context-ir jc))
  [m
   [ir:parse-ir
    ctx
    "badasm"
    "define void @f() {\nentry:\n  call void asm sideeffect \"sycall\", \"\"()\n  ret void\n}"]]
  (j (jit:make))]
 (jit:add-module! j jc m)
 (jit:context-dispose! jc)
 [t:check-exn
  "bad asm mnemonic raises at materialization"
  (jit:function j "f")]]

(t:section "jit: stack-map access (GC statepoints)")

;; the section symbol is local, so access goes through sll's keeper items;
;; version byte 3 proves the pointer lands on the map
[let*
 [(jc (jit:make-context))
  (ctx (jit:context-ir jc))
  [m
   [ir:parse-ir
    ctx
    "sm"
    "declare i32 @getpid()
define ptr addrspace(1) @keep(ptr addrspace(1) %a) gc \"statepoint-example\" {
entry:
  %p = call i32 @getpid()
  ret ptr addrspace(1) %a
}
@\"\\01__LLVM_StackMaps\" = external global i8
@sll_stackmaps_keeper = constant ptr @\"\\01__LLVM_StackMaps\""]]
  (j (jit:make))]
 (ir:run-module-passes! m "rewrite-statepoints-for-gc")
 (jit:add-module! j jc m)
 (jit:context-dispose! jc)
 (jit:lookup-address j "keep")  ; materialize
 [let
  ((sm (jit:stackmap-address j)))
  (t:check "stackmap-address finds the section via the keeper" (positive? sm))
  (t:check "stackmap version byte is 3" (= 3 (foreign-ref 'unsigned-8 sm 0)))]]

;; without the keeper the failure must be a clear raised error
[let*
 [(jc (jit:make-context))
  (ctx (jit:context-ir jc))
  (m (ir:parse-ir ctx "nosm" "define void @g() {\nentry:\n  ret void\n}"))
  (j (jit:make))]
 (jit:add-module! j jc m)
 (jit:context-dispose! jc)
 (jit:lookup-address j "g")
 [t:check-exn
  "stackmap-address without the keeper raises"
  (jit:stackmap-address j)]]

;; multi-module: one keeper NAME per module (a dylib holds one definition per
;; symbol -- probed: same-name keepers collide); each module's map is read back
;; by its keeper's name
[let*
 [(jc (jit:make-context))
  [mk
   [lambda
    (name fname keeper)
    [let
     [[m
       [ir:parse-ir
        (jit:context-ir jc)
        name
        [format
         "declare i32 @getpid()
define ptr addrspace(1) @~a(ptr addrspace(1) %a) gc \"statepoint-example\" {
entry:
  %p = call i32 @getpid()
  ret ptr addrspace(1) %a
}
@\"\\01__LLVM_StackMaps\" = external global i8
@~a = constant ptr @\"\\01__LLVM_StackMaps\""
         fname
         keeper]]]]
     (ir:run-module-passes! m "rewrite-statepoints-for-gc")
     m]]]
  (j (jit:make))]
 (jit:add-module! j jc (mk "mm1" "mf1" "keeper_one"))
 (jit:add-module! j jc (mk "mm2" "mf2" "keeper_two"))
 (jit:context-dispose! jc)
 (jit:lookup-address j "mf1")
 (jit:lookup-address j "mf2")
 [let
  [(sm1 (jit:stackmap-address j "keeper_one"))
   (sm2 (jit:stackmap-address j "keeper_two"))]
  [t:check
   "two modules, two named keepers, two maps"
   [and
    (not (= sm1 sm2))
    (= 3 (foreign-ref 'unsigned-8 sm1 0))
    (= 3 (foreign-ref 'unsigned-8 sm2 0))]]]]
