;;; Coverage harness, levels 1+2 of project/coverage-plan.md.
;;;
;;; Level 2: every corpus entry is an (name ll-program golden-IR) pair;
;;; both sides go through LLVM's canonical printer and must match exactly.
;;; While comparing, every emitted instruction is observed via
;;; LLVMGetInstructionOpcode (and icmp/fcmp predicates via their getters).
;;;
;;; Level 1: the observed sets must equal the enums extracted from the
;;; installed headers minus the exclusions ledger -- no overlap, no gaps,
;;; no stale exclusions. Coverage is measured on emitted IR, not claimed.
(import (chezscheme)
        (prefix (tests harness) t:)
        (prefix (tests oracle) o:)
        (prefix (llvm ir) ir:)
        (prefix (llscheme ll) ll:))

;; ---- the oracle and the ledger ------------------------------------------

(define opcode-oracle (o:enum-alist "Core.h" "LLVMOpcode"))
(define int-pred-oracle (o:enum-alist "Core.h" "LLVMIntPredicate"))
(define real-pred-oracle (o:enum-alist "Core.h" "LLVMRealPredicate"))

(define exclusions
  (call-with-input-file "project/coverage-exclusions.ss" read))

(define (exclusions-for axis)
  (map cadr (filter (lambda (e) (eq? (car e) axis)) exclusions)))

(define (oracle-name alist value)
  (let loop ([a alist])
    (cond
      [(null? a) #f]
      [(= (cdar a) value) (caar a)]
      [else (loop (cdr a))])))

(define icmp-opcode (cdr (assq 'LLVMICmp opcode-oracle)))
(define fcmp-opcode (cdr (assq 'LLVMFCmp opcode-oracle)))

;; ---- observation ------------------------------------------------------------

(define observed-opcodes (make-eqv-hashtable))
(define observed-int-preds (make-eqv-hashtable))
(define observed-real-preds (make-eqv-hashtable))

(define (observe-module! m)
  (for-each
    (lambda (f)
      (for-each
        (lambda (bb)
          (for-each
            (lambda (ins)
              (let ([op (ir:instruction-opcode ins)])
                (hashtable-set! observed-opcodes op #t)
                (when (= op icmp-opcode)
                  (hashtable-set! observed-int-preds (ir:icmp-predicate ins) #t))
                (when (= op fcmp-opcode)
                  (hashtable-set! observed-real-preds (ir:fcmp-predicate ins) #t))))
            (ir:block-instructions bb)))
        (ir:function-blocks f)))
    (ir:module-functions m)))

;; ---- golden comparison ---------------------------------------------------------

;; drop the module identity header lines; everything else must match
(define (ir-body s)
  (let ([p (open-string-input-port s)] [out (open-output-string)])
    (let loop ()
      (let ([l (get-line p)])
        (unless (eof-object? l)
          (unless (or (and (> (string-length l) 0) (char=? (string-ref l 0) #\;))
                      (and (>= (string-length l) 15)
                           (string=? (substring l 0 15) "source_filename")))
            (put-string out l)
            (put-char out #\newline))
          (loop))))
    (get-output-string out)))

(define ctx (ir:make-context))

(define (check-entry! name prog golden)
  (let* ([built (ll:build ctx name prog)]
         [parsed (ir:parse-ir ctx name golden)]
         [built-text (ir-body (ir:module->string built))]
         [golden-text (ir-body (ir:module->string parsed))])
    (ir:verify-module built)
    (observe-module! built)
    (unless (string=? built-text golden-text)
      (printf "~%--- built (~a) ---~%~a--- golden ---~%~a---~%"
              name built-text golden-text))
    (t:check (string-append "golden round-trip: " name)
             (string=? built-text golden-text))
    (ir:module-dispose! built)
    (ir:module-dispose! parsed)))

;; ---- the corpus ------------------------------------------------------------------

(t:section "coverage: golden round-trips (level 2)")

(check-entry! "intops"
  '((define i64 (@intops (i64 %a) (i64 %b))
      (label %entry
        (= %v1 (add i64 %a %b))
        (= %v2 (sub i64 %v1 %b))
        (= %v3 (mul i64 %v2 %b))
        (= %v4 (udiv i64 %v3 %b))
        (= %v5 (sdiv i64 %v4 %b))
        (= %v6 (urem i64 %v5 %b))
        (= %v7 (srem i64 %v6 %b))
        (= %v8 (shl i64 %v7 %b))
        (= %v9 (lshr i64 %v8 %b))
        (= %v10 (ashr i64 %v9 %b))
        (= %v11 (and i64 %v10 %b))
        (= %v12 (or i64 %v11 %b))
        (= %v13 (xor i64 %v12 %b))
        (ret i64 %v13))))
  "define i64 @intops(i64 %a, i64 %b) {
entry:
  %v1 = add i64 %a, %b
  %v2 = sub i64 %v1, %b
  %v3 = mul i64 %v2, %b
  %v4 = udiv i64 %v3, %b
  %v5 = sdiv i64 %v4, %b
  %v6 = urem i64 %v5, %b
  %v7 = srem i64 %v6, %b
  %v8 = shl i64 %v7, %b
  %v9 = lshr i64 %v8, %b
  %v10 = ashr i64 %v9, %b
  %v11 = and i64 %v10, %b
  %v12 = or i64 %v11, %b
  %v13 = xor i64 %v12, %b
  ret i64 %v13
}
")

(check-entry! "fltops"
  '((define double (@fltops (double %a) (double %b))
      (label %entry
        (= %v1 (fadd double %a %b))
        (= %v2 (fsub double %v1 %b))
        (= %v3 (fmul double %v2 %b))
        (= %v4 (fdiv double %v3 %b))
        (= %v5 (frem double %v4 %b))
        (= %v6 (fneg double %v5))
        (ret double %v6))))
  "define double @fltops(double %a, double %b) {
entry:
  %v1 = fadd double %a, %b
  %v2 = fsub double %v1, %b
  %v3 = fmul double %v2, %b
  %v4 = fdiv double %v3, %b
  %v5 = frem double %v4, %b
  %v6 = fneg double %v5
  ret double %v6
}
")

(check-entry! "casts"
  '((define i64 (@casts (i64 %x) (double %d) (ptr %p))
      (label %entry
        (= %t (trunc i64 %x to i32))
        (= %zx (zext i32 %t to i64))
        (= %sx (sext i32 %t to i64))
        (= %fui (fptoui double %d to i64))
        (= %fsi (fptosi double %d to i64))
        (= %uf (uitofp i64 %x to double))
        (= %sf (sitofp i64 %x to double))
        (= %ft (fptrunc double %d to float))
        (= %fe (fpext float %ft to double))
        (= %pi (ptrtoint ptr %p to i64))
        (= %ip (inttoptr i64 %x to ptr))
        (= %bc (bitcast double %d to i64))
        (ret i64 %bc))))
  "define i64 @casts(i64 %x, double %d, ptr %p) {
entry:
  %t = trunc i64 %x to i32
  %zx = zext i32 %t to i64
  %sx = sext i32 %t to i64
  %fui = fptoui double %d to i64
  %fsi = fptosi double %d to i64
  %uf = uitofp i64 %x to double
  %sf = sitofp i64 %x to double
  %ft = fptrunc double %d to float
  %fe = fpext float %ft to double
  %pi = ptrtoint ptr %p to i64
  %ip = inttoptr i64 %x to ptr
  %bc = bitcast double %d to i64
  ret i64 %bc
}
")

(check-entry! "memory"
  '((define i64 (@mem (i64 %x))
      (label %entry
        (= %p (alloca i64 (align 8)))
        (store (i64 %x) (ptr %p) (align 8))
        (= %q (getelementptr i64 (ptr %p) (i64 0)))
        (= %v (load i64 (ptr %q) (align 8)))
        (ret i64 %v))))
  "define i64 @mem(i64 %x) {
entry:
  %p = alloca i64, align 8
  store i64 %x, ptr %p, align 8
  %q = getelementptr i64, ptr %p, i64 0
  %v = load i64, ptr %q, align 8
  ret i64 %v
}
")

(check-entry! "icmps"
  '((define i64 (@icmps (i64 %a) (i64 %b))
      (label %entry
        (= %c1 (icmp eq i64 %a %b))
        (= %c2 (icmp ne i64 %a %b))
        (= %c3 (icmp ugt i64 %a %b))
        (= %c4 (icmp uge i64 %a %b))
        (= %c5 (icmp ult i64 %a %b))
        (= %c6 (icmp ule i64 %a %b))
        (= %c7 (icmp sgt i64 %a %b))
        (= %c8 (icmp sge i64 %a %b))
        (= %c9 (icmp slt i64 %a %b))
        (= %c10 (icmp sle i64 %a %b))
        (= %s (select (i1 %c1) (i64 %a) (i64 %b)))
        (br i1 %c10 (label %then) (label %else)))
      (label %then
        (br (label %join)))
      (label %else
        (br (label %join)))
      (label %join
        (= %ph (phi i64 (%a %then) (%s %else)))
        (ret i64 %ph))))
  "define i64 @icmps(i64 %a, i64 %b) {
entry:
  %c1 = icmp eq i64 %a, %b
  %c2 = icmp ne i64 %a, %b
  %c3 = icmp ugt i64 %a, %b
  %c4 = icmp uge i64 %a, %b
  %c5 = icmp ult i64 %a, %b
  %c6 = icmp ule i64 %a, %b
  %c7 = icmp sgt i64 %a, %b
  %c8 = icmp sge i64 %a, %b
  %c9 = icmp slt i64 %a, %b
  %c10 = icmp sle i64 %a, %b
  %s = select i1 %c1, i64 %a, i64 %b
  br i1 %c10, label %then, label %else

then:
  br label %join

else:
  br label %join

join:
  %ph = phi i64 [ %a, %then ], [ %s, %else ]
  ret i64 %ph
}
")

(check-entry! "fcmps"
  '((define i1 (@fcmps (double %a) (double %b))
      (label %entry
        (= %c0 (fcmp false double %a %b))
        (= %c1 (fcmp oeq double %a %b))
        (= %c2 (fcmp ogt double %a %b))
        (= %c3 (fcmp oge double %a %b))
        (= %c4 (fcmp olt double %a %b))
        (= %c5 (fcmp ole double %a %b))
        (= %c6 (fcmp one double %a %b))
        (= %c7 (fcmp ord double %a %b))
        (= %c8 (fcmp uno double %a %b))
        (= %c9 (fcmp ueq double %a %b))
        (= %c10 (fcmp ugt double %a %b))
        (= %c11 (fcmp uge double %a %b))
        (= %c12 (fcmp ult double %a %b))
        (= %c13 (fcmp ule double %a %b))
        (= %c14 (fcmp une double %a %b))
        (= %c15 (fcmp true double %a %b))
        (= %r (and i1 %c0 %c15))
        (ret i1 %r))))
  "define i1 @fcmps(double %a, double %b) {
entry:
  %c0 = fcmp false double %a, %b
  %c1 = fcmp oeq double %a, %b
  %c2 = fcmp ogt double %a, %b
  %c3 = fcmp oge double %a, %b
  %c4 = fcmp olt double %a, %b
  %c5 = fcmp ole double %a, %b
  %c6 = fcmp one double %a, %b
  %c7 = fcmp ord double %a, %b
  %c8 = fcmp uno double %a, %b
  %c9 = fcmp ueq double %a, %b
  %c10 = fcmp ugt double %a, %b
  %c11 = fcmp uge double %a, %b
  %c12 = fcmp ult double %a, %b
  %c13 = fcmp ule double %a, %b
  %c14 = fcmp une double %a, %b
  %c15 = fcmp true double %a, %b
  %r = and i1 %c0, %c15
  ret i1 %r
}
")

(check-entry! "calls"
  '((define void (@nop)
      (label %entry
        (ret void)))
    (define i64 (@caller (i64 %x))
      (label %entry
        (call void @nop)
        (= %r (call i64 @callee (i64 %x)))
        (ret i64 %r)))
    (define i64 (@callee (i64 %x))
      (label %entry
        (ret i64 %x))))
  "define void @nop() {
entry:
  ret void
}

define i64 @caller(i64 %x) {
entry:
  call void @nop()
  %r = call i64 @callee(i64 %x)
  ret i64 %r
}

define i64 @callee(i64 %x) {
entry:
  ret i64 %x
}
")

;; ---- the ledger check (level 1) -----------------------------------------------------

(t:section "coverage: observed + excluded = oracle (level 1)")

;; -> (values missing-names overlap-names stale-names implemented-count excluded-count)
(define (audit-axis axis oracle observed)
  (let ([excluded (exclusions-for axis)])
    (let loop ([entries oracle] [missing '()] [overlap '()] [count 0])
      (if (null? entries)
          (values (reverse missing) (reverse overlap)
                  (filter (lambda (x) (not (assq x oracle))) excluded)
                  count (length excluded))
          (let* ([name (caar entries)] [value (cdar entries)]
                 [obs? (hashtable-ref observed value #f)]
                 [exc? (memq name excluded)])
            (loop (cdr entries)
                  (if (or obs? exc?) missing (cons name missing))
                  (if (and obs? exc?) (cons name overlap) overlap)
                  (if obs? (+ count 1) count)))))))

(define (check-axis! label axis oracle observed)
  (let-values ([(missing overlap stale count excluded) (audit-axis axis oracle observed)])
    (printf "  ~a: ~a implemented + ~a excluded = ~a/~a~%"
            label count excluded (+ count excluded) (length oracle))
    (unless (null? missing)
      (printf "    NOT implemented and NOT excluded: ~a~%" missing))
    (unless (null? overlap)
      (printf "    implemented but still excluded: ~a~%" overlap))
    (unless (null? stale)
      (printf "    excluded but not in the oracle: ~a~%" stale))
    (t:check (string-append label ": observed + excluded = oracle")
             (and (null? missing) (null? overlap) (null? stale)))))

(check-axis! "opcodes" 'opcode opcode-oracle observed-opcodes)
(check-axis! "icmp predicates" 'int-predicate int-pred-oracle observed-int-preds)
(check-axis! "fcmp predicates" 'real-predicate real-pred-oracle observed-real-preds)

(t:check "oracle extraction sane: LLVMRet = 1"
         (= (cdr (assq 'LLVMRet opcode-oracle)) 1))
(t:check "oracle extraction sane: LLVMIntEQ = 32"
         (= (cdr (assq 'LLVMIntEQ int-pred-oracle)) 32))

(ir:context-dispose! ctx)
