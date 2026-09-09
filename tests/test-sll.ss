;;; (sll): LLVM IR as s-expressions, end to end through the JIT.
[import
 (chezscheme)
 (prefix (tests harness) t:)
 (prefix (llvm ir) ir:)
 (prefix (llvm jit) jit:)
 (prefix (sll) sll:)]

[define
 (contains? s sub)
 [let
  ((n (string-length s)) (m (string-length sub)))
  [let
   loop
   ((i 0))
   [cond
    ((> (+ i m) n) #f)
    ((string=? (substring s i (+ i m)) sub) #t)
    (else (loop (+ i 1)))]]]]

(t:section "sll: @fact -- recursion, branches")

[define
 fact-prog
 '[[define
    i64
    (@fact (i64 %n))
    [label
     %entry
     (= %isbase (icmp slt i64 %n 2))
     (br i1 %isbase (label %base) (label %rec))]
    (label %base (ret i64 1))
    [label
     %rec
     (= %n1 (sub i64 %n 1))
     (= %f (call i64 (@fact (i64 %n1))))
     (= %r (mul i64 %n %f))
     (ret i64 %r)]]]]

(define fact (jit:function (sll:jit fact-prog) "fact"))
(t:check "fact 20" (= (fact 20) 2432902008176640000))
(t:check "fact 0" (= (fact 0) 1))
(t:check "fact 1" (= (fact 1) 1))

(t:section "sll: dump")

(define ir-text (sll:dump fact-prog))
(t:check "dump produces text" (string? ir-text))
(t:check "dump defines @fact" (contains? ir-text "define i64 @fact(i64 %n)"))
(t:check "dump keeps our value names" (contains? ir-text "%isbase"))

(t:section "sll: @sum -- phi with forward references, loop")

[define
 sum-prog
 '[[define
    i64
    (@sum (i64 %n))
    (label %entry (br (label %loop)))
    [label
     %loop
     (= %i (phi i64 (0 %entry) (%i1 %loop)))
     (= %acc (phi i64 (0 %entry) (%acc1 %loop)))
     (= %i1 (add i64 %i 1))
     (= %acc1 (add i64 %acc %i1))
     (= %done (icmp eq i64 %i1 %n))
     (br i1 %done (label %exit) (label %loop))]
    (label %exit (ret i64 %acc1))]]]

(define sum (jit:function (sll:jit sum-prog) "sum"))
(t:check "sum 10 = 55" (= (sum 10) 55))
(t:check "sum 1 = 1" (= (sum 1) 1))

(t:section "sll: memory -- alloca/store/load/gep, align attributes")

[define
 mem-prog
 '[[define
    i64
    (@roundtrip (i64 %x))
    [label
     %entry
     (= %p (alloca i64 (align 16)))
     (store (i64 %x) (ptr %p) (align 8))
     (= %v (load i64 (ptr %p) (align 8)))
     (ret i64 %v)]]
   [define
    i64
    (@via-gep (i64 %x))
    [label
     %entry
     (= %p (alloca i64))
     (store (i64 %x) (ptr %p))
     (= %q (getelementptr i64 (ptr %p) (i64 0)))
     (= %v (load i64 (ptr %q)))
     (ret i64 %v)]]]]

(define mem-jit (sll:jit mem-prog))
[t:check
 "alloca/store/load with align"
 (= ((jit:function mem-jit "roundtrip") 42) 42)]
(t:check "getelementptr" (= ((jit:function mem-jit "via-gep") 7) 7))
[t:check
 "align attribute lands in the IR"
 (contains? (sll:dump mem-prog) "align 16")]

(t:section "sll: the define's section deco")

;; (section "name") sits between the attributes and the alignment, as LLVM's
;; grammar has it; the build applies it and unbuild reads it back. (A function
;; naming its section is how an alignment below the target's preferred one
;; reaches the machine code: LLVM's printer keeps a smaller explicit alignment
;; only then.)
[define
 sect-prog
 '[[define
    i64
    (@packed (i64 %x))
    (attributes nounwind)
    (section ".text")
    (align 1)
    (label %entry (= %r (add i64 %x 1)) (ret i64 %r))]]]
[t:check
 "section deco lands in the IR, before the alignment"
 (contains? (sll:dump sect-prog) "section \".text\" align 1")]
[let* [(sc (jit:make-context))
       (m (sll:build (jit:context-ir sc) "sect" sect-prog))
       (back (sll:unbuild m))
       (f (car back))]
 [t:check
  "unbuild reads the section back, between the attributes and the alignment"
  (and (equal? (list-ref f 4) '(section ".text"))
       (equal? (list-ref f 5) '(align 1)))]
 [t:check
  "and the JIT runs the packed function"
  (= ((jit:function (sll:jit sect-prog) "packed") 41) 42)]]

(t:section "sll: casts, select, floats")

[define
 misc-prog
 '[[define
    i64
    (@lowbyte (i64 %x))
    [label
     %entry
     (= %t (trunc i64 %x i8))
     (= %z (zext i8 %t i64))
     (ret i64 %z)]]
   [define
    i64
    (@min (i64 %a) (i64 %b))
    [label
     %entry
     (= %c (icmp slt i64 %a %b))
     (= %m (select (i1 %c) (i64 %a) (i64 %b)))
     (ret i64 %m)]]
   [define
    double
    (@half (double %x))
    (label %entry (= %h (fdiv double %x 2.0)) (ret double %h))]
   [define
    double
    (@int->half (i64 %x))
    [label
     %entry
     (= %d (sitofp i64 %x double))
     (= %h (call double (@half (double %d))))
     (ret double %h)]]]]

(define misc-jit (sll:jit misc-prog))
(t:check "trunc/zext" (= ((jit:function misc-jit "lowbyte") 511) 255))
(t:check "icmp/select min" (= ((jit:function misc-jit "min") 9 3) 3))
(t:check "float arithmetic" (= ((jit:function misc-jit "half") 5.0) 2.5))
[t:check
 "sitofp + intra-module call"
 (= ((jit:function misc-jit "int->half") 5) 2.5)]

(t:section "sll: instruction flags")

[define
 flags-prog
 '[[define
    i64
    (@fsum (i64 %a) (i64 %b))
    [label
     %entry
     (= %v1 (add nsw i64 %a %b))
     (= %v2 (mul nuw nsw i64 %v1 2))
     (= %v3 (sdiv exact i64 %v2 2))
     (= %p (alloca i64))
     (store volatile (i64 %v3) (ptr %p))
     (= %v (load volatile i64 (ptr %p)))
     (= %g (getelementptr inbounds i64 (ptr %p) (i64 0)))
     (= %w (load i64 (ptr %g)))
     (= %r (add i64 %v %w))
     (ret i64 %r)]]]]

[t:check
 "flags: jit executes correctly"
 (= ((jit:function (sll:jit flags-prog) "fsum") 3 4) 14)]
[t:check
 "flags appear in dumped IR"
 [let
  ((s (sll:dump flags-prog)))
  [and
   (contains? s "add nsw")
   (contains? s "mul nuw nsw")
   (contains? s "sdiv exact")
   (contains? s "load volatile")
   (contains? s "getelementptr inbounds")]]]

(t:section "sll: step-3 instructions execute")

[define
 sw-prog
 '[[define
    i64
    (@classify (i64 %x))
    [label
     %entry
     [switch
      i64
      %x
      (label %other)
      ((i64 0) (label %zero))
      ((i64 1) (label %one))]]
    (label %zero (ret i64 100))
    (label %one (ret i64 200))
    (label %other (ret i64 300))]]]
(define classify (jit:function (sll:jit sw-prog) "classify"))
(t:check "switch: case 0" (= (classify 0) 100))
(t:check "switch: case 1" (= (classify 1) 200))
(t:check "switch: default" (= (classify 7) 300))

[define
 atomic-prog
 '[[define
    i64
    (@bump (i64 %v))
    [label
     %entry
     (= %p (alloca i64))
     (store (i64 %v) (ptr %p))
     (= %old (atomicrmw add (ptr %p) (i64 5) seq_cst))
     (= %new (load atomic i64 (ptr %p) acquire (align 8)))
     (= %r (add i64 %old %new))
     (ret i64 %r)]]]]
[t:check
 "atomicrmw + atomic load"
 (= ((jit:function (sll:jit atomic-prog) "bump") 10) 25)]

[define
 vec-prog
 '[[define
    i32
    (@splat3 (i32 %x))
    [label
     %entry
     (= %v (insertelement ((vector 4 i32) undef) (i32 %x) (i64 0)))
     [=
      %s
      (shufflevector ((vector 4 i32) %v) ((vector 4 i32) undef) (mask 0 0 0 0))]
     (= %e (extractelement ((vector 4 i32) %s) (i64 3)))
     (ret i32 %e)]]]]
[t:check
 "vector splat/extract"
 (= ((jit:function (sll:jit vec-prog) "splat3") 7) 7)]

[define
 agg-prog
 '[[define
    i64
    (@through (i64 %x))
    [label
     %entry
     (= %a (insertvalue ((struct i64 i1) undef) (i64 %x) 0))
     (= %f (extractvalue ((struct i64 i1) %a) 0))
     (ret i64 %f)]]]]
[t:check
 "aggregate insert/extract"
 (= ((jit:function (sll:jit agg-prog) "through") 42) 42)]

[t:check-exn
 "unknown atomic ordering"
 [sll:dump
  '[[define
     i64
     (@f (ptr %p))
     [label
      %entry
      (= %v (atomicrmw add (ptr %p) (i64 1) sequential))
      (ret i64 %v)]]]]]
[t:check-exn
 "unknown atomicrmw op"
 [sll:dump
  '[[define
     i64
     (@f (ptr %p))
     [label
      %entry
      (= %v (atomicrmw frob (ptr %p) (i64 1) seq_cst))
      (ret i64 %v)]]]]]
[t:check-exn
 "weak on non-cmpxchg"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (= %y (add weak i64 %x 1)) (ret i64 %y))]]]]
[t:check-exn
 "ordering without atomic flag"
 [sll:dump
  '[[define
     i64
     (@f (ptr %p))
     (label %entry (= %v (load i64 (ptr %p) seq_cst)) (ret i64 %v))]]]]
[t:check-exn
 "atomic flag without ordering"
 [sll:dump
  '[[define
     i64
     (@f (ptr %p))
     (label %entry (= %v (load atomic i64 (ptr %p) (align 8))) (ret i64 %v))]]]]
[t:check-exn
 "blockaddress of another function"
 [sll:dump
  '[[define
     i64
     (@g (i64 %x))
     (label %entry (ret i64 %x))
     (label %tgt (ret i64 0))]
    [define
     i64
     (@f (i64 %x))
     [label
      %entry
      (= %a (ptrtoint ptr (blockaddress @g %tgt) to i64))
      (ret i64 %a)]]]]]

(t:section "sll: exception handling")

[define
 inv-prog
 '[(define i32 (@pers) (label %entry (ret i32 0)))
   [define
    i64
    (@double-it (i64 %x))
    (label %entry (= %r (add i64 %x %x)) (ret i64 %r))]
   [define
    i64
    (@safe-double (i64 %x))
    (personality ptr @pers)
    [label
     %entry
     (= %r (invoke i64 (@double-it (i64 %x)) (label %ok) (label %lpad)))]
    (label %ok (ret i64 %r))
    (label %lpad (= %lp (landingpad (struct ptr i32) cleanup)) (ret i64 -1))]]]

[t:check
 "invoke: normal path through the jit"
 (= ((jit:function (sll:jit inv-prog) "safe-double") 21) 42)]
[t:check
 "personality lands in the IR"
 (contains? (sll:dump inv-prog) "personality ptr @pers")]

[t:check-exn
 "unbound personality"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (personality ptr @nope)
     (label %entry (ret i64 %x))]]]]
[t:check-exn
 "invoke without unwind"
 [sll:dump
  '[(declare void (@g))
    [define
     void
     (@f)
     (label %entry (invoke void (@g) (label %ok)))
     (label %ok (ret void))]]]]
[t:check-exn
 "callbr with a non-asm callee"
 [sll:dump
  '[(declare void (@g))
    [define
     void
     (@f)
     (label %entry (callbr void ((@g)) (label %ok) ()))
     (label %ok (ret void))]]]]
[t:check-exn
 "malformed catchret"
 [sll:dump
  '[[define
     void
     (@f)
     (label %entry (catchret from %cp to (label %ok)))
     (label %ok (ret void))]]]]

(t:section "sll: step 5.5 -- varargs, tail, alloca counts, forward refs")

[define
 va-prog
 '[(declare void (@llvm.va_start.p0 ptr))
   (declare void (@llvm.va_end.p0 ptr))
   [define
    i64
    (@sumva (i64 %n) variadic)
    [label
     %entry
     (= %ap (alloca (array 3 ptr) (align 16)))
     (call void (@llvm.va_start.p0 (ptr %ap)))
     (= %a (va_arg (ptr %ap) i64))
     (= %b (va_arg (ptr %ap) i64))
     (call void (@llvm.va_end.p0 (ptr %ap)))
     (= %r (add i64 %a %b))
     (ret i64 %r)]]
   [define
    i64
    (@use-va)
    [label
     %entry
     (= %r (call (fn i64 i64 variadic) (@sumva (i64 2) (i64 30) (i64 12))))
     (ret i64 %r)]]]]

[t:check
 "varargs end to end: va_start/va_arg through the jit"
 (= ((jit:function (sll:jit va-prog) "use-va")) 42)]
[t:check
 "vararg declare and call-site fn type print correctly"
 [let
  ((s (sll:dump va-prog)))
  [and
   (contains? s "define i64 @sumva(i64 %n, ...)")
   (contains? s "call i64 (i64, ...) @sumva(i64 2, i64 30, i64 12)")]]]

[define
 tail-prog
 '[[define
    i64
    (@leaf (i64 %x))
    (label %entry (= %r (mul i64 %x 3)) (ret i64 %r))]
   [define
    i64
    (@via-tail (i64 %x))
    (label %entry (= %r (call tail i64 (@leaf (i64 %x)))) (ret i64 %r))]]]
[t:check
 "tail call executes"
 (= ((jit:function (sll:jit tail-prog) "via-tail") 7) 21)]
[t:check
 "tail marker prints"
 (contains? (sll:dump tail-prog) "tail call i64 @leaf")]

[define
 count-prog
 '[[define
    i64
    (@third (i64 %x))
    [label
     %entry
     (= %buf (alloca i64 (i64 4) (align 8)))
     (= %slot (getelementptr i64 (ptr %buf) (i64 2)))
     (store (i64 %x) (ptr %slot))
     (= %v (load i64 (ptr %slot)))
     (ret i64 %v)]]]]
[t:check
 "alloca with element count"
 (= ((jit:function (sll:jit count-prog) "third") 9) 9)]
[t:check
 "alloca count prints"
 (contains? (sll:dump count-prog) "alloca i64, i64 4")]

[define
 rotated-prog
 '[[define
    i64
    (@rotated (i64 %x))
    (label %entry (br (label %compute)))
    (label %use (= %r (add i64 %v 1)) (ret i64 %r))
    (label %compute (= %v (mul i64 %x 2)) (br (label %use)))]]]
[t:check
 "forward reference across rotated blocks"
 (= ((jit:function (sll:jit rotated-prog) "rotated") 5) 11)]
[t:check
 "no scratch block leaks into the output"
 (not (contains? (sll:dump rotated-prog) "sll.fwd"))]
[t:check-exn
 "genuinely unbound local still raises"
 (sll:dump '((define i64 (@f (i64 %x)) (label %entry (ret i64 %nope)))))]

(t:section "sll: globals")

[define
 counter-prog
 '[(= @counter (global internal i64 100))
   (= @step (constant internal i64 7))
   [define
    i64
    (@tick)
    [label
     %entry
     (= %c (load i64 (ptr @counter)))
     (= %s (load i64 (ptr @step)))
     (= %n (add i64 %c %s))
     (store (i64 %n) (ptr @counter))
     (ret i64 %n)]]]]

(define tick (jit:function (sll:jit counter-prog) "tick"))
(t:check "global keeps state: first tick" (= (tick) 107))
(t:check "global keeps state: second tick" (= (tick) 114))

[define
 msg-prog
 '[(= @msg (constant private (array 3 i8) (cz "hi")))
   [define
    i8
    (@first-byte)
    (label %entry (= %b (load i8 (ptr @msg))) (ret i8 %b))]]]
[t:check
 "string constant readable"
 (= ((jit:function (sll:jit msg-prog) "first-byte")) (char->integer #\h))]

[t:check-exn
 "global definition needs an initializer"
 (sll:dump '((= @x (global i64))))]
[t:check-exn
 "aggregate initializer on scalar global"
 (sll:dump '((= @x (global i64 ((i64 1) (i64 2))))))]
[t:check-exn
 "unbound global in initializer"
 (sll:dump '((= @x (global ptr @nope))))]
[t:check-exn
 "duplicate global name"
 [sll:dump
  '[(= @x (global i64 0))
    (= @x (global i64 1))]]]

(t:section "sll: declare -- cross-module calls in one jit")

(define jc (jit:make-context))
[define
 m1
 [sll:build
  (jit:context-ir jc)
  "m1"
  '[[define
     i64
     (@inc (i64 %x))
     (label %entry (= %r (add i64 %x 1)) (ret i64 %r))]]]]
[define
 m2
 [sll:build
  (jit:context-ir jc)
  "m2"
  '[(declare i64 (@inc i64))
    [define
     i64
     (@inc2 (i64 %x))
     [label
      %entry
      (= %a (call i64 (@inc (i64 %x))))
      (= %b (call i64 (@inc (i64 %a))))
      (ret i64 %b)]]]]]
(ir:verify-module m1)
(ir:verify-module m2)
(define xj (jit:make))
(jit:add-module! xj jc m1)
(jit:add-module! xj jc m2)
(jit:context-dispose! jc)
(t:check "declare + cross-module call" (= ((jit:function xj "inc2") 40) 42))

(t:section "sll: errors")

[t:check-exn
 "instruction outside a block"
 (sll:dump '((define i64 (@f (i64 %x)) (ret i64 %x))))]
[t:check-exn
 "block without terminator"
 (sll:dump '((define i64 (@f (i64 %x)) (label %entry (= %y (add i64 %x 1))))))]
[t:check-exn
 "empty block"
 (sll:dump '((define i64 (@f (i64 %x)) (label %entry))))]
[t:check-exn
 "nested block"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (label %inner (ret i64 %x)) (ret i64 %x))]]]]
[t:check-exn
 "unbound local"
 (sll:dump '((define i64 (@f (i64 %x)) (label %entry (ret i64 %nope)))))]
[t:check-exn
 "unknown opcode"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (= %y (frob i64 %x)) (ret i64 %y))]]]]
[t:check-exn
 "duplicate local name"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (= %x (add i64 %x 1)) (ret i64 %x))]]]]
[t:check-exn
 "unknown label"
 (sll:dump '((define i64 (@f (i64 %x)) (label %entry (br (label %nowhere))))))]
[t:check-exn
 "binding a result-less instruction"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     [label
      %entry
      (= %p (alloca i64))
      (= %s (store (i64 %x) (ptr %p)))
      (ret i64 %x)]]]]]
[t:check-exn
 "flag invalid for opcode: udiv nsw"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (= %y (udiv nsw i64 %x 1)) (ret i64 %y))]]]]
[t:check-exn
 "fast-math flag on integer op"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (= %y (add fast i64 %x 1)) (ret i64 %y))]]]]
[t:check-exn
 "gep flag on non-gep"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (= %y (add inbounds i64 %x 1)) (ret i64 %y))]]]]
[t:check-exn
 "tail flag on a non-call"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (= %y (add tail i64 %x 1)) (ret i64 %y))]]]]
[t:check-exn
 "unknown type"
 (sll:dump '((define i64 (@f (i37x %x)) (label %entry (ret i64 0)))))]
[t:check-exn
 "untyped literal"
 [sll:dump
  '[[define
     i64
     (@f (i64 %x))
     (label %entry (= %p (alloca i64)) (store 5 (ptr %p)) (ret i64 %x))]]]]

(t:section "sll: load-sll (the inverted format)")

;; a .sll file is one quasiquote body: (scheme ...) defines, ,@ splices
[let
 ((path "/tmp/sll-load-test.sll"))
 [call-with-output-file
  path
  [lambda
   (p)
   (put-string p "(scheme (import (prefix (sll) sll:))\n")
   (put-string p "        (define (pair-of x) (list x x)))\n")
   (put-string p "(define i64 (@f (i64 %x))\n")
   (put-string p "  (label %e (= %r (add i64 %x ,(* 6 7))) (ret i64 %r)))\n")
   (put-string p ",@(map (lambda (n)\n")
   (put-string p "         `(= ,(sll:name '@g n)\n")
   (put-string p "             (global i64 ,n)))\n")
   (put-string p "       (pair-of 5))\n")]
  'replace]
 [let
  ((prog (sll:load-sll path)))
  [t:check
   "escapes evaluated inside items"
   [equal?
    (car prog)
    '(define i64 (@f (i64 %x)) (label %e (= %r (add i64 %x 42)) (ret i64 %r)))]]
  (t:check "top-level splices produce items" (= 3 (length prog)))]]

(t:section "sll: asm arity guard")

;; LLVM segfaults on constraint/type mismatches; sll must refuse first
[t:check-exn
 "constraint operand count must match the call-site type"
 [sll:build
  (ir:make-context)
  "x"
  '[[define
     void
     (@f)
     [label
      %e
      (call void ((asm "nop" "={rax},{rdi}" sideeffect)))
      (ret void)]]]]]

(t:section "sll: bug-hunt regressions")

;; empty constraint strings and empty items are arity-checked too
[t:check-exn
 "empty constraint string vs non-void call"
 [sll:build
  (ir:make-context)
  "x"
  '[[define
     i64
     (@f (i64 %a))
     [label
      %e
      (= %r (call i64 ((asm "mov $1, $0" "") (i64 %a))))
      (ret i64 %r)]]]]]
[t:check-exn
 "trailing comma in constraints"
 [sll:build
  (ir:make-context)
  "x"
  '[[define
     i64
     (@f (i64 %a))
     [label
      %e
      (= %r (call i64 ((asm "mov $1, $0" "=r,r,") (i64 %a))))
      (ret i64 %r)]]]]]

;; load-sll: escape side effects observe strict file order
[let
 ((path "/tmp/sll-order-test.sll"))
 [call-with-output-file
  path
  [lambda
   (p)
   (put-string p "(scheme (define n 0) (define (next!) (set! n (+ n 1)) n))\n")
   (put-string p "(a ,(next!)) (b ,(next!)) (c ,(next!))\n")]
  'replace]
 [t:check
  "escapes evaluate top to bottom"
  [equal?
   (sll:load-sll path)
   '[(a 1)
     (b 2)
     (c 3)]]]]

(t:section "sll: name construction")

(t:check "name concatenates symbol pieces" (eq? (sll:name '%p 1) '%p1))
[t:check
 "name takes strings and integers"
 (eq? (sll:name '@h "x" 2 '_tail) '@hx2_tail)]
[t:check
 "name keeps the sigil only from the head"
 (eq? (sll:name '% 'acc2_ 3) '%acc2_3)]
(t:check-exn "name requires a sigil on the first piece" (sll:name 'p 1))
(t:check-exn "name rejects an empty result" (sll:name '%))
(t:check-exn "name rejects inexact and other piece types" (sll:name '%x 1.5))
[t:check-exn
 "constructed all-digit names raise (anonymity rule)"
 (sll:name '% 4 2)]

;; end to end: generator-built names flow through build + jit
[t:check
 "generated names build and run"
 [=
  55
  [[sll:procedure
    `[[define
       i64
       (@sum10)
       [label
        %entry
        ,@[let
           loop
           ((i 1) (prev 0) (acc '()))
           [if
            (> i 10)
            (reverse (cons `(ret i64 ,prev) acc))
            [let
             ((next (sll:name '%s i)))
             (loop (+ i 1) next (cons `(= ,next (add i64 ,prev ,i)) acc))]]]]]]
    "sum10"]]]]
