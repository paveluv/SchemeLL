;;; (llscheme ll): LLVM IR as s-expressions, end to end through the JIT.
(import (chezscheme)
        (prefix (tests harness) t:)
        (prefix (llvm ir) ir:)
        (prefix (llvm jit) jit:)
        (prefix (llscheme ll) ll:))

(define (contains? s sub)
  (let ([n (string-length s)] [m (string-length sub)])
    (let loop ([i 0])
      (cond
        [(> (+ i m) n) #f]
        [(string=? (substring s i (+ i m)) sub) #t]
        [else (loop (+ i 1))]))))

(t:section "ll: @fact -- recursion, branches, implicit entry")

(define fact-prog
  '((define i64 (@fact (i64 %n))
      (= %isbase (icmp slt i64 %n 2))
      (br i1 %isbase (label %base) (label %rec))
      (label %base)
      (ret i64 1)
      (label %rec)
      (= %n1 (sub i64 %n 1))
      (= %f (call i64 @fact (i64 %n1)))
      (= %r (mul i64 %n %f))
      (ret i64 %r))))

(define fact (jit:function (ll:jit fact-prog) "fact"))
(t:check "fact 20" (= (fact 20) 2432902008176640000))
(t:check "fact 0" (= (fact 0) 1))
(t:check "fact 1" (= (fact 1) 1))

(t:section "ll: dump")

(define ir-text (ll:dump fact-prog))
(t:check "dump produces text" (string? ir-text))
(t:check "dump defines @fact" (contains? ir-text "define i64 @fact(i64 %n)"))
(t:check "dump keeps our value names" (contains? ir-text "%isbase"))

(t:section "ll: @sum -- phi with forward references, loop")

(define sum-prog
  '((define i64 (@sum (i64 %n))
      (br (label %loop))
      (label %loop)
      (= %i (phi i64 (0 %entry) (%i1 %loop)))
      (= %acc (phi i64 (0 %entry) (%acc1 %loop)))
      (= %i1 (add i64 %i 1))
      (= %acc1 (add i64 %acc %i1))
      (= %done (icmp eq i64 %i1 %n))
      (br i1 %done (label %exit) (label %loop))
      (label %exit)
      (ret i64 %acc1))))

(define sum (jit:function (ll:jit sum-prog) "sum"))
(t:check "sum 10 = 55" (= (sum 10) 55))
(t:check "sum 1 = 1" (= (sum 1) 1))

(t:section "ll: memory -- alloca/store/load/gep, align attributes")

(define mem-prog
  '((define i64 (@roundtrip (i64 %x))
      (= %p (alloca i64 (align 16)))
      (store (i64 %x) (ptr %p) (align 8))
      (= %v (load i64 (ptr %p) (align 8)))
      (ret i64 %v))
    (define i64 (@via-gep (i64 %x))
      (= %p (alloca i64))
      (store (i64 %x) (ptr %p))
      (= %q (getelementptr i64 (ptr %p) (i64 0)))
      (= %v (load i64 (ptr %q)))
      (ret i64 %v))))

(define mem-jit (ll:jit mem-prog))
(t:check "alloca/store/load with align"
         (= ((jit:function mem-jit "roundtrip") 42) 42))
(t:check "getelementptr" (= ((jit:function mem-jit "via-gep") 7) 7))
(t:check "align attribute lands in the IR"
         (contains? (ll:dump mem-prog) "align 16"))

(t:section "ll: casts, select, floats")

(define misc-prog
  '((define i64 (@lowbyte (i64 %x))
      (= %t (trunc i64 %x to i8))
      (= %z (zext i8 %t to i64))
      (ret i64 %z))
    (define i64 (@min (i64 %a) (i64 %b))
      (= %c (icmp slt i64 %a %b))
      (= %m (select (i1 %c) (i64 %a) (i64 %b)))
      (ret i64 %m))
    (define double (@half (double %x))
      (= %h (fdiv double %x 2.0))
      (ret double %h))
    (define double (@int->half (i64 %x))
      (= %d (sitofp i64 %x to double))
      (= %h (call double @half (double %d)))
      (ret double %h))))

(define misc-jit (ll:jit misc-prog))
(t:check "trunc/zext" (= ((jit:function misc-jit "lowbyte") 511) 255))
(t:check "icmp/select min" (= ((jit:function misc-jit "min") 9 3) 3))
(t:check "float arithmetic" (= ((jit:function misc-jit "half") 5.0) 2.5))
(t:check "sitofp + intra-module call"
         (= ((jit:function misc-jit "int->half") 5) 2.5))

(t:section "ll: declare -- cross-module calls in one jit")

(define jc (jit:make-context))
(define m1 (ll:build (jit:context-ir jc) "m1"
                     '((define i64 (@inc (i64 %x))
                         (= %r (add i64 %x 1))
                         (ret i64 %r)))))
(define m2 (ll:build (jit:context-ir jc) "m2"
                     '((declare i64 (@inc i64))
                       (define i64 (@inc2 (i64 %x))
                         (= %a (call i64 @inc (i64 %x)))
                         (= %b (call i64 @inc (i64 %a)))
                         (ret i64 %b)))))
(ir:verify-module m1)
(ir:verify-module m2)
(define xj (jit:make))
(jit:add-module! xj jc m1)
(jit:add-module! xj jc m2)
(jit:context-dispose! jc)
(t:check "declare + cross-module call" (= ((jit:function xj "inc2") 40) 42))

(t:section "ll: errors")

(t:check-exn "unbound local"
             (ll:dump '((define i64 (@f (i64 %x)) (ret i64 %nope)))))
(t:check-exn "unknown opcode"
             (ll:dump '((define i64 (@f (i64 %x))
                          (= %y (frob i64 %x))
                          (ret i64 %y)))))
(t:check-exn "duplicate local name"
             (ll:dump '((define i64 (@f (i64 %x))
                          (= %x (add i64 %x 1))
                          (ret i64 %x)))))
(t:check-exn "unknown label"
             (ll:dump '((define i64 (@f (i64 %x)) (br (label %nowhere))))))
(t:check-exn "binding a result-less instruction"
             (ll:dump '((define i64 (@f (i64 %x))
                          (= %p (alloca i64))
                          (= %s (store (i64 %x) (ptr %p)))
                          (ret i64 %x)))))
(t:check-exn "unsupported flag rejected"
             (ll:dump '((define i64 (@f (i64 %x))
                          (= %y (add nsw i64 %x 1))
                          (ret i64 %y)))))
(t:check-exn "unknown type"
             (ll:dump '((define i64 (@f (i37x %x)) (ret i64 0)))))
(t:check-exn "untyped literal"
             (ll:dump '((define i64 (@f (i64 %x))
                          (= %p (alloca i64))
                          (store 5 (ptr %p))
                          (ret i64 %x)))))
