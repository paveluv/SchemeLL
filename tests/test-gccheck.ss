;;; (llvm gccheck): the bit-leak checker. The rule -- addrspace(AS)
;;; ptrtoint may feed only and-masks within MASK -- and its key
;;; property: closure under CSE (the merged cast of two conforming
;;; tag tests still conforms; the probed miscompile shape is a
;;; syntactic violation wherever the optimizer moves it).
(import (chezscheme)
        (prefix (tests harness) t:)
        (prefix (llvm ir) ir:)
        (prefix (llvm target) target:)
        (prefix (sll) sll:)
        (prefix (llvm gccheck) gccheck:))

(t:section "gccheck: the bit-leak gate")

(define vt '(ptr (addrspace 1)))
(define (build prog) (sll:build (ir:make-context) "gcc" prog))

(t:check "tag test conforms"
         (begin
           (gccheck:assert-no-pointer-leaks!
             (build `((define i64 (@f (,vt %p))
                        (label %e
                          (= %a (ptrtoint ,vt %p i64))
                          (= %tag (and i64 %a 7))
                          (ret i64 %tag)))))
             1 7)
           #t))

(t:check-exn "full-address arithmetic is caught"
             (gccheck:assert-no-pointer-leaks!
               (build `((define i64 (@g (,vt %p))
                          (label %e
                            (= %a (ptrtoint ,vt %p i64))
                            (= %r (add i64 %a 1))
                            (ret i64 %r)))))
               1 7))

(t:check-exn "an over-wide mask is caught"
             (gccheck:assert-no-pointer-leaks!
               (build `((define i64 (@h (,vt %p))
                          (label %e
                            (= %a (ptrtoint ,vt %p i64))
                            (= %t (and i64 %a 255))
                            (ret i64 %t)))))
               1 7))

(t:check-exn "even a STORED full address is caught"
             (gccheck:assert-no-pointer-leaks!
               (build `((define void (@s (,vt %p) (ptr %out))
                          (label %e
                            (= %a (ptrtoint ,vt %p i64))
                            (store (i64 %a) (ptr %out))
                            (ret void)))))
               1 7))

(t:check "addrspace-0 ptrtoint is not the checker's business"
         (begin
           (gccheck:assert-no-pointer-leaks!
             (build '((define i64 (@k (ptr %p))
                        (label %e
                          (= %a (ptrtoint ptr %p i64))
                          (= %r (add i64 %a 1))
                          (ret i64 %r)))))
             1 7)
           #t))

;; PLACEMENT: the gate runs on frontend IR, BEFORE O2. Discovered
;; here: instcombine rewrites tag+tag into shl -- conforming code
;; becomes syntactically unrecognizable, so post-O2 checking is a
;; non-starter without demanded-bits analysis. Pre-O2 is sound:
;; semantic preservation carries frontend conformance through
;; optimization, CSE merges included.
(t:check "the gate's home: pre-O2 frontend IR with tag tests passes"
         (let* ([ctx (ir:make-context)]
                [m (sll:build ctx "cse"
                     `((declare void (@op))
                       (define i64 (@f (,vt %p))
                         (gc "statepoint-example")
                         (label %e
                           (= %a (ptrtoint ,vt %p i64))
                           (= %t1 (and i64 %a 7))
                           (call void (@op))
                           (= %b (ptrtoint ,vt %p i64))
                           (= %t2 (and i64 %b 7))
                           (= %r (add i64 %t1 %t2))
                           (ret i64 %r)))))]
                [tm (target:make-machine)])
           (target:configure-module! m tm '(1))
           (gccheck:assert-no-pointer-leaks! m 1 7)   ; BEFORE passes
           (ir:run-module-passes! m "default<O2>")    ; then optimize
           (target:machine-dispose! tm)
           #t))
