;;; Coverage harness, levels 1+2 of project/coverage-plan.md.
;;;
;;; Level 2: every corpus entry is an (name sll-program golden-IR) pair; both
;;; sides go through LLVM's canonical printer and must match exactly. While
;;; comparing, every emitted instruction is observed via
;;; LLVMGetInstructionOpcode (and icmp/fcmp predicates via their getters).
;;;
;;; Level 1: the observed sets must equal the enums extracted from the installed
;;; headers minus the exclusions ledger -- no overlap, no gaps, no stale
;;; exclusions. Coverage is measured on emitted IR, not claimed.
[import
 (chezscheme)
 (prefix (tests harness) t:)
 (prefix (tests oracle) o:)
 (prefix (tests normalize) n:)
 (prefix (llvm ir) ir:)
 (prefix (llvm config) config:)
 (prefix (sll) sll:)
 (prefix (sll render) render:)]

;; ---- the oracle and the ledger ------------------------------------------

(define opcode-oracle (o:enum-alist "Core.h" "LLVMOpcode"))
(define int-pred-oracle (o:enum-alist "Core.h" "LLVMIntPredicate"))
(define real-pred-oracle (o:enum-alist "Core.h" "LLVMRealPredicate"))
(define fmf-oracle (o:bitmask-alist "Core.h" "LLVMFastMath"))
(define gep-flag-oracle (o:bitmask-alist "Core.h" "LLVMGEPFlag"))
(define ordering-oracle (o:enum-alist "Core.h" "LLVMAtomicOrdering"))
(define rmw-oracle (o:enum-alist "Core.h" "LLVMAtomicRMWBinOp"))
(define linkage-oracle (o:enum-alist "Core.h" "LLVMLinkage"))
(define tailkind-oracle (o:enum-alist "Core.h" "LLVMTailCallKind"))

(define exclusions (call-with-input-file "project/coverage-exclusions.ss" read))

[define
 (exclusions-for axis)
 (map cadr (filter (lambda (e) (eq? (car e) axis)) exclusions))]

[define
 (oracle-name alist value)
 [let
  loop
  ((a alist))
  (cond ((null? a) #f) ((= (cdar a) value) (caar a)) (else (loop (cdr a))))]]

(define icmp-opcode (cdr (assq 'LLVMICmp opcode-oracle)))
(define fcmp-opcode (cdr (assq 'LLVMFCmp opcode-oracle)))
(define gep-opcode (cdr (assq 'LLVMGetElementPtr opcode-oracle)))
(define load-opcode (cdr (assq 'LLVMLoad opcode-oracle)))
(define store-opcode (cdr (assq 'LLVMStore opcode-oracle)))
(define rmw-opcode (cdr (assq 'LLVMAtomicRMW opcode-oracle)))
(define call-opcode (cdr (assq 'LLVMCall opcode-oracle)))
(define cmpxchg-opcode (cdr (assq 'LLVMAtomicCmpXchg opcode-oracle)))

;; ---- observation ------------------------------------------------------------

(define observed-opcodes (make-eqv-hashtable))
(define observed-int-preds (make-eqv-hashtable))
(define observed-real-preds (make-eqv-hashtable))
(define observed-fmf (make-eqv-hashtable))
(define observed-gep-flags (make-eqv-hashtable))
(define observed-orderings (make-eqv-hashtable))
(define observed-rmw-ops (make-eqv-hashtable))
(define observed-linkages (make-eqv-hashtable))
(define observed-tail-kinds (make-eqv-hashtable))

[define
 (observe-bits! table mask)
 [for-each
  [lambda
   (bit)
   (unless (zero? (bitwise-and mask bit)) (hashtable-set! table bit #t))]
  '(1 2 4 8 16 32 64)]]

[define
 (observe-module! m)
 [for-each
  (lambda (g) (hashtable-set! observed-linkages (ir:linkage g) #t))
  (ir:module-globals m)]
 [for-each
  [lambda
   (f)
   (hashtable-set! observed-linkages (ir:linkage f) #t)
   [for-each
    [lambda
     (bb)
     [for-each
      [lambda
       (ins)
       [let
        ((op (ir:instruction-opcode ins)))
        (hashtable-set! observed-opcodes op #t)
        [when
         (= op icmp-opcode)
         (hashtable-set! observed-int-preds (ir:icmp-predicate ins) #t)]
        [when
         (= op fcmp-opcode)
         (hashtable-set! observed-real-preds (ir:fcmp-predicate ins) #t)]
        [when
         (= op gep-opcode)
         (observe-bits! observed-gep-flags (ir:gep-no-wrap-flags ins))]
        [when
         (or (= op load-opcode) (= op store-opcode))
         [let
          ((o (ir:instruction-ordering ins)))
          (unless (zero? o) (hashtable-set! observed-orderings o #t))]]
        [when
         (= op call-opcode)
         (hashtable-set! observed-tail-kinds (ir:tail-call-kind ins) #t)]
        [when
         (= op rmw-opcode)
         (hashtable-set! observed-rmw-ops (ir:atomicrmw-binop ins) #t)]
        [when
         (= op cmpxchg-opcode)
         [hashtable-set!
          observed-orderings
          (ir:cmpxchg-success-ordering ins)
          #t]
         [hashtable-set!
          observed-orderings
          (ir:cmpxchg-failure-ordering ins)
          #t]]
        [when
         (ir:can-use-fast-math-flags? ins)
         (observe-bits! observed-fmf (ir:fast-math-flags ins))]]]
      (ir:block-instructions bb)]]
    (ir:function-blocks f)]]
  (ir:module-functions m)]]

;; ---- golden comparison
;; ---------------------------------------------------------

;; drop the module identity header lines; everything else must match
[define
 (ir-body s)
 [let
  ((p (open-string-input-port s)) (out (open-output-string)))
  [let
   loop
   ()
   [let
    ((l (get-line p)))
    [unless
     (eof-object? l)
     [unless
      [or
       (and (> (string-length l) 0) (char=? (string-ref l 0) #\;))
       [and
        (>= (string-length l) 15)
        (string=? (substring l 0 15) "source_filename")]]
      (put-string out l)
      (put-char out #\newline)]
     (loop)]]]
  (get-output-string out)]]

(define ctx (ir:make-context))  ; for the strictness probes below

;; named struct types are registered per context, so each module gets a fresh
;; context to keep names collision-free across entries
[define
 (check-entry! name prog golden)
 [let*
  [(bctx (ir:make-context))
   (pctx (ir:make-context))
   (rctx (ir:make-context))
   (built (sll:build bctx name prog))
   (parsed (ir:parse-ir pctx name golden))
   (built-text (ir-body (ir:module->string built)))
   (golden-text (ir-body (ir:module->string parsed)))]
  (ir:verify-module built)
  (observe-module! built)
  [unless
   (string=? built-text golden-text)
   [printf
    "~%--- built (~a) ---~%~a--- golden ---~%~a---~%"
    name
    built-text
    golden-text]]
  [t:check
   (string-append "golden round-trip: " name)
   (string=? built-text golden-text)]
  ;; unbuild self-test: parse the golden, unbuild it back to sll data, rebuild,
  ;; and demand the same canonical print
  [let*
   [(prog (sll:unbuild parsed))
    (rebuilt (sll:build rctx (string-append name "-u") prog))
    (rebuilt-text (ir-body (ir:module->string rebuilt)))]
   [unless
    (string=? rebuilt-text golden-text)
    [printf
     "~%--- unbuilt+rebuilt (~a) ---~%~a--- golden ---~%~a---~%"
     name
     rebuilt-text
     golden-text]]
   [t:check
    (string-append "unbuild round-trip: " name)
    (string=? rebuilt-text golden-text)]
   (ir:module-dispose! rebuilt)
   ;; render self-test: the same sll data rendered to text in pure Scheme and
   ;; re-parsed by LLVM must print identically
   [let*
    [(xctx (ir:make-context))
     (reparsed (ir:parse-ir xctx name (render:sll->ll prog)))
     (reparsed-text (ir-body (ir:module->string reparsed)))]
    [unless
     (string=? reparsed-text golden-text)
     [printf
      "~%--- rendered+reparsed (~a) ---~%~a--- golden ---~%~a---~%"
      name
      reparsed-text
      golden-text]]
    [t:check
     (string-append "render round-trip: " name)
     (string=? reparsed-text golden-text)]
    (ir:module-dispose! reparsed)
    (ir:context-dispose! xctx)]]
  (ir:module-dispose! built)
  (ir:module-dispose! parsed)
  (ir:context-dispose! bctx)
  (ir:context-dispose! pctx)
  (ir:context-dispose! rctx)]]

;; ---- the corpus
;; ------------------------------------------------------------------

(t:section "coverage: golden round-trips (level 2)")

[check-entry!
 "intops"
 '[[define
    i64
    (@intops (i64 %a) (i64 %b))
    [label
     %entry
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
     (ret i64 %v13)]]]
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
"]

[check-entry!
 "fltops"
 '[[define
    double
    (@fltops (double %a) (double %b))
    [label
     %entry
     (= %v1 (fadd double %a %b))
     (= %v2 (fsub double %v1 %b))
     (= %v3 (fmul double %v2 %b))
     (= %v4 (fdiv double %v3 %b))
     (= %v5 (frem double %v4 %b))
     (= %v6 (fneg double %v5))
     (ret double %v6)]]]
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
"]

[check-entry!
 "casts"
 '[[define
    i64
    (@casts (i64 %x) (double %d) (ptr %p))
    [label
     %entry
     (= %t (trunc i64 %x i32))
     (= %zx (zext i32 %t i64))
     (= %sx (sext i32 %t i64))
     (= %fui (fptoui double %d i64))
     (= %fsi (fptosi double %d i64))
     (= %uf (uitofp i64 %x double))
     (= %sf (sitofp i64 %x double))
     (= %ft (fptrunc double %d float))
     (= %fe (fpext float %ft double))
     (= %pi (ptrtoint ptr %p i64))
     (= %ip (inttoptr i64 %x ptr))
     (= %bc (bitcast double %d i64))
     (ret i64 %bc)]]]
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
"]

[check-entry!
 "memory"
 '[[define
    i64
    (@mem (i64 %x))
    [label
     %entry
     (= %p (alloca i64 (align 8)))
     (= %arr (alloca i64 (i64 4) (align 8)))
     (store (i64 %x) (ptr %p) (align 8))
     (= %q (getelementptr i64 (ptr %p) (i64 0)))
     (= %v (load i64 (ptr %q) (align 8)))
     (ret i64 %v)]]]
 "define i64 @mem(i64 %x) {
entry:
  %p = alloca i64, align 8
  %arr = alloca i64, i64 4, align 8
  store i64 %x, ptr %p, align 8
  %q = getelementptr i64, ptr %p, i64 0
  %v = load i64, ptr %q, align 8
  ret i64 %v
}
"]

[check-entry!
 "icmps"
 '[[define
    i64
    (@icmps (i64 %a) (i64 %b))
    [label
     %entry
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
     (br i1 %c10 (label %then) (label %else))]
    (label %then (br (label %join)))
    (label %else (br (label %join)))
    (label %join (= %ph (phi i64 (%a %then) (%s %else))) (ret i64 %ph))]]
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
"]

[check-entry!
 "fcmps"
 '[[define
    i1
    (@fcmps (double %a) (double %b))
    [label
     %entry
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
     (ret i1 %r)]]]
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
"]

[check-entry!
 "calls"
 '[(define void (@nop) (label %entry (ret void)))
   [define
    i64
    (@caller (i64 %x))
    [label
     %entry
     (call void (@nop))
     (= %r (call i64 (@callee (i64 %x))))
     (ret i64 %r)]]
   (define i64 (@callee (i64 %x)) (label %entry (ret i64 %x)))]
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
"]

[check-entry!
 "call-site-attributes"
 '[(define void (@leafcallee) (label %entry (ret void)))
   [define
    void
    (@site)
    [label
     %entry
     (call void (@leafcallee) (attributes ("gc-leaf-function")))
     (call void (@leafcallee) (attributes nounwind ("k" "v")))
     (ret void)]]]
 "define void @leafcallee() {
entry:
  ret void
}

define void @site() {
entry:
  call void @leafcallee() #0
  call void @leafcallee() #1
  ret void
}

attributes #0 = { \"gc-leaf-function\" }
attributes #1 = { nounwind \"k\"=\"v\" }
"]

[check-entry!
 "flags"
 '[[define
    i64
    (@flags (i64 %a) (i64 %b))
    [label
     %entry
     (= %v1 (add nsw i64 %a %b))
     (= %v2 (sub nuw i64 %v1 %b))
     (= %v3 (mul nuw nsw i64 %v2 %b))
     (= %v4 (shl nsw i64 %v3 1))
     (= %v5 (udiv exact i64 %v4 2))
     (= %v6 (sdiv exact i64 %v5 2))
     (= %v7 (lshr exact i64 %v6 1))
     (= %v8 (ashr exact i64 %v7 1))
     (= %v9 (or disjoint i64 %v8 %b))
     (= %t (trunc i64 %v9 i32))
     (= %z (zext nneg i32 %t i64))
     (= %p (alloca i64 (align 8)))
     (store volatile (i64 %z) (ptr %p) (align 8))
     (= %v (load volatile i64 (ptr %p) (align 8)))
     (= %g1 (getelementptr inbounds i64 (ptr %p) (i64 0)))
     (= %g2 (getelementptr nusw i64 (ptr %p) (i64 0)))
     (= %g3 (getelementptr nuw i64 (ptr %p) (i64 0)))
     (= %i1 (ptrtoint ptr %g1 i64))
     (= %i2 (ptrtoint ptr %g2 i64))
     (= %i3 (ptrtoint ptr %g3 i64))
     (= %s1 (add i64 %i1 %i2))
     (= %s2 (add i64 %s1 %i3))
     (= %r (add i64 %v %s2))
     (ret i64 %r)]]]
 "define i64 @flags(i64 %a, i64 %b) {
entry:
  %v1 = add nsw i64 %a, %b
  %v2 = sub nuw i64 %v1, %b
  %v3 = mul nuw nsw i64 %v2, %b
  %v4 = shl nsw i64 %v3, 1
  %v5 = udiv exact i64 %v4, 2
  %v6 = sdiv exact i64 %v5, 2
  %v7 = lshr exact i64 %v6, 1
  %v8 = ashr exact i64 %v7, 1
  %v9 = or disjoint i64 %v8, %b
  %t = trunc i64 %v9 to i32
  %z = zext nneg i32 %t to i64
  %p = alloca i64, align 8
  store volatile i64 %z, ptr %p, align 8
  %v = load volatile i64, ptr %p, align 8
  %g1 = getelementptr inbounds i64, ptr %p, i64 0
  %g2 = getelementptr nusw i64, ptr %p, i64 0
  %g3 = getelementptr nuw i64, ptr %p, i64 0
  %i1 = ptrtoint ptr %g1 to i64
  %i2 = ptrtoint ptr %g2 to i64
  %i3 = ptrtoint ptr %g3 to i64
  %s1 = add i64 %i1, %i2
  %s2 = add i64 %s1, %i3
  %r = add i64 %v, %s2
  ret i64 %r
}
"]

[check-entry!
 "fmf"
 '[[define
    double
    (@fmf (double %a) (double %b))
    [label
     %entry
     (= %v1 (fadd fast double %a %b))
     (= %v2 (fsub nnan double %v1 %b))
     (= %v3 (fmul nsz double %v2 %b))
     (= %v4 (fdiv arcp double %v3 %b))
     (= %v5 (frem contract double %v4 %b))
     (= %v6 (fneg afn double %v5))
     (= %v7 (fadd reassoc double %v6 %b))
     (= %v8 (fsub ninf double %v7 %b))
     (= %c (fcmp nnan oeq double %v8 %b))
     (= %r (select (i1 %c) (double %v7) (double %v8)))
     (ret double %r)]]]
 "define double @fmf(double %a, double %b) {
entry:
  %v1 = fadd fast double %a, %b
  %v2 = fsub nnan double %v1, %b
  %v3 = fmul nsz double %v2, %b
  %v4 = fdiv arcp double %v3, %b
  %v5 = frem contract double %v4, %b
  %v6 = fneg afn double %v5
  %v7 = fadd reassoc double %v6, %b
  %v8 = fsub ninf double %v7, %b
  %c = fcmp nnan oeq double %v8, %b
  %r = select i1 %c, double %v7, double %v8
  ret double %r
}
"]

[check-entry!
 "control2"
 '[[define
    i64
    (@control (i64 %x))
    [label
     %entry
     (= %fz (freeze i64 %x))
     [switch
      i64
      %fz
      (label %other)
      ((i64 0) (label %zero))
      ((i64 1) (label %one))]]
    (label %zero (ret i64 100))
    (label %one (ret i64 200))
    [label
     %other
     [indirectbr
      (ptr (blockaddress @control %zero))
      (label %zero)
      (label %one)]]
    (label %dead (unreachable))]]
 "define i64 @control(i64 %x) {
entry:
  %fz = freeze i64 %x
  switch i64 %fz, label %other [
    i64 0, label %zero
    i64 1, label %one
  ]

zero:
  ret i64 100

one:
  ret i64 200

other:
  indirectbr ptr blockaddress(@control, %zero), [label %zero, label %one]

dead:
  unreachable
}
"]

[check-entry!
 "vaarg"
 '[[define
    i64
    (@nextva (ptr %ap))
    (label %entry (= %v (va_arg (ptr %ap) i64)) (ret i64 %v))]]
 "define i64 @nextva(ptr %ap) {
entry:
  %v = va_arg ptr %ap, i64
  ret i64 %v
}
"]

[check-entry!
 "addrspace"
 '[[define
    (ptr (addrspace 1))
    (@ascast (ptr %p))
    [label
     %entry
     (= %q (addrspacecast ptr %p (ptr (addrspace 1))))
     (ret (ptr (addrspace 1)) %q)]]]
 "define ptr addrspace(1) @ascast(ptr %p) {
entry:
  %q = addrspacecast ptr %p to ptr addrspace(1)
  ret ptr addrspace(1) %q
}
"]

[check-entry!
 "vectors"
 '[[define
    i32
    (@vec (i32 %x))
    [label
     %entry
     (= %v (insertelement ((vector 4 i32) undef) (i32 %x) (i64 0)))
     [=
      %s
      (shufflevector ((vector 4 i32) %v) ((vector 4 i32) undef) (mask 0 5 1 4))]
     (= %e (extractelement ((vector 4 i32) %s) (i64 3)))
     (ret i32 %e)]]]
 "define i32 @vec(i32 %x) {
entry:
  %v = insertelement <4 x i32> undef, i32 %x, i64 0
  %s = shufflevector <4 x i32> %v, <4 x i32> undef, <4 x i32> <i32 0, i32 5, i32 1, i32 4>
  %e = extractelement <4 x i32> %s, i64 3
  ret i32 %e
}
"]

[check-entry!
 "aggregates"
 '[[define
    i64
    (@agg (i64 %x) (i32 %y))
    [label
     %entry
     (= %a (insertvalue ((struct i64 i32) undef) (i64 %x) 0))
     (= %b (insertvalue ((struct i64 i32) %a) (i32 %y) 1))
     (= %f (extractvalue ((struct i64 i32) %b) 0))
     (= %arr (insertvalue ((array 2 i64) undef) (i64 %f) 1))
     (= %g (extractvalue ((array 2 i64) %arr) 1))
     (ret i64 %g)]]]
 "define i64 @agg(i64 %x, i32 %y) {
entry:
  %a = insertvalue { i64, i32 } undef, i64 %x, 0
  %b = insertvalue { i64, i32 } %a, i32 %y, 1
  %f = extractvalue { i64, i32 } %b, 0
  %arr = insertvalue [2 x i64] undef, i64 %f, 1
  %g = extractvalue [2 x i64] %arr, 1
  ret i64 %g
}
"]

[check-entry!
 "atomics"
 '[[define
    i64
    (@atomics (ptr %p) (i64 %v))
    [label
     %entry
     (fence seq_cst)
     (fence acquire)
     (store atomic (i64 %v) (ptr %p) release (align 8))
     (store atomic (i64 %v) (ptr %p) monotonic (align 8))
     (store atomic (i64 %v) (ptr %p) seq_cst (align 8))
     (= %l1 (load atomic i64 (ptr %p) unordered (align 8)))
     (= %l2 (load atomic i64 (ptr %p) acquire (align 8)))
     (= %old (atomicrmw volatile add (ptr %p) (i64 %v) seq_cst))
     (= %pair (cmpxchg weak (ptr %p) (i64 %l1) (i64 %old) acq_rel monotonic))
     (= %val (extractvalue ((struct i64 i1) %pair) 0))
     (= %r (add i64 %l2 %val))
     (ret i64 %r)]]]
 "define i64 @atomics(ptr %p, i64 %v) {
entry:
  fence seq_cst
  fence acquire
  store atomic i64 %v, ptr %p release, align 8
  store atomic i64 %v, ptr %p monotonic, align 8
  store atomic i64 %v, ptr %p seq_cst, align 8
  %l1 = load atomic i64, ptr %p unordered, align 8
  %l2 = load atomic i64, ptr %p acquire, align 8
  %old = atomicrmw volatile add ptr %p, i64 %v seq_cst, align 8
  %pair = cmpxchg weak ptr %p, i64 %l1, i64 %old acq_rel monotonic, align 8
  %val = extractvalue { i64, i1 } %pair, 0
  %r = add i64 %l2, %val
  ret i64 %r
}
"]

[check-entry!
 "rmw-ops"
 '[[define
    void
    (@rmws (ptr %p) (i64 %v) (ptr %q) (double %d))
    [label
     %entry
     (= %r0 (atomicrmw xchg (ptr %p) (i64 %v) monotonic))
     (= %r1 (atomicrmw add (ptr %p) (i64 %v) monotonic))
     (= %r2 (atomicrmw sub (ptr %p) (i64 %v) monotonic))
     (= %r3 (atomicrmw and (ptr %p) (i64 %v) monotonic))
     (= %r4 (atomicrmw nand (ptr %p) (i64 %v) monotonic))
     (= %r5 (atomicrmw or (ptr %p) (i64 %v) monotonic))
     (= %r6 (atomicrmw xor (ptr %p) (i64 %v) monotonic))
     (= %r7 (atomicrmw max (ptr %p) (i64 %v) monotonic))
     (= %r8 (atomicrmw min (ptr %p) (i64 %v) monotonic))
     (= %r9 (atomicrmw umax (ptr %p) (i64 %v) monotonic))
     (= %r10 (atomicrmw umin (ptr %p) (i64 %v) monotonic))
     (= %r11 (atomicrmw fadd (ptr %q) (double %d) monotonic))
     (= %r12 (atomicrmw fsub (ptr %q) (double %d) monotonic))
     (= %r13 (atomicrmw fmax (ptr %q) (double %d) monotonic))
     (= %r14 (atomicrmw fmin (ptr %q) (double %d) monotonic))
     (= %r15 (atomicrmw uinc_wrap (ptr %p) (i64 %v) monotonic))
     (= %r16 (atomicrmw udec_wrap (ptr %p) (i64 %v) monotonic))
     (ret void)]]]
 "define void @rmws(ptr %p, i64 %v, ptr %q, double %d) {
entry:
  %r0 = atomicrmw xchg ptr %p, i64 %v monotonic, align 8
  %r1 = atomicrmw add ptr %p, i64 %v monotonic, align 8
  %r2 = atomicrmw sub ptr %p, i64 %v monotonic, align 8
  %r3 = atomicrmw and ptr %p, i64 %v monotonic, align 8
  %r4 = atomicrmw nand ptr %p, i64 %v monotonic, align 8
  %r5 = atomicrmw or ptr %p, i64 %v monotonic, align 8
  %r6 = atomicrmw xor ptr %p, i64 %v monotonic, align 8
  %r7 = atomicrmw max ptr %p, i64 %v monotonic, align 8
  %r8 = atomicrmw min ptr %p, i64 %v monotonic, align 8
  %r9 = atomicrmw umax ptr %p, i64 %v monotonic, align 8
  %r10 = atomicrmw umin ptr %p, i64 %v monotonic, align 8
  %r11 = atomicrmw fadd ptr %q, double %d monotonic, align 8
  %r12 = atomicrmw fsub ptr %q, double %d monotonic, align 8
  %r13 = atomicrmw fmax ptr %q, double %d monotonic, align 8
  %r14 = atomicrmw fmin ptr %q, double %d monotonic, align 8
  %r15 = atomicrmw uinc_wrap ptr %p, i64 %v monotonic, align 8
  %r16 = atomicrmw udec_wrap ptr %p, i64 %v monotonic, align 8
  ret void
}
"]

[when
 (config:capability? 'atomic-usub)
 [check-entry!
  "fp-cast-fast-math"
  '[[define
     double
     (@casts (double %x))
     [label
      %entry
      (= %a (fptrunc fast double %x float))
      (= %b (fpext nnan float %a double))
      (ret double %b)]]]
  "define double @casts(double %x) {
entry:
  %a = fptrunc fast double %x to float
  %b = fpext nnan float %a to double
  ret double %b
}
"]
 [check-entry!
  "rmw-usub"
  '[[define
     void
     (@usubs (ptr %p) (i64 %v))
     [label
      %entry
      (= %a (atomicrmw usub_cond (ptr %p) (i64 %v) monotonic))
      (= %b (atomicrmw usub_sat (ptr %p) (i64 %v) monotonic))
      (ret void)]]]
  "define void @usubs(ptr %p, i64 %v) {
entry:
  %a = atomicrmw usub_cond ptr %p, i64 %v monotonic, align 8
  %b = atomicrmw usub_sat ptr %p, i64 %v monotonic, align 8
  ret void
}
"]]

[check-entry!
 "alias-address-space"
 '[(= @g (global (addrspace 1) i32 0)                      )
   (= @a (alias (addrspace 1) i32 ((ptr (addrspace 1)) @g)))]
 "@g = addrspace(1) global i32 0
@a = alias i32, ptr addrspace(1) @g
"]

[check-entry!
 "globals"
 '[(= @counter (global i64 0))
   (= @answer (constant private i64 42))
   (= @weakg (global weak i64 1))
   (= @weako (global weak_odr i64 2))
   (= @lonce (global linkonce i64 3))
   (= @lonceo (global linkonce_odr i64 4))
   (= @intern (global internal i64 5))
   (= @avail (global available_externally i64 6))
   (= @commong (global common i64 0))
   (= @append (global appending (array 2 i64) ((i64 1) (i64 2))))
   (= @extg (global external i64))
   (= @extw (global extern_weak i64))
   (= @buf (global internal (array 4 i8) zeroinitializer (align 16)))
   (= @msg (constant private (array 6 i8) (cz "hello")))
   (= @pair (constant internal (struct i64 i32) ((i64 1) (i32 2))))
   (= @vecc (constant internal (vector 2 i32) ((i32 7) (i32 9))))
   (= @pnull (global ptr null))
   (= @fptr (global ptr @reader))
   [define
    i64
    (@reader)
    (label %entry (= %v (load i64 (ptr @counter))) (ret i64 %v))]]
 "@counter = global i64 0
@answer = private constant i64 42
@weakg = weak global i64 1
@weako = weak_odr global i64 2
@lonce = linkonce global i64 3
@lonceo = linkonce_odr global i64 4
@intern = internal global i64 5
@avail = available_externally global i64 6
@commong = common global i64 0
@append = appending global [2 x i64] [i64 1, i64 2]
@extg = external global i64
@extw = extern_weak global i64
@buf = internal global [4 x i8] zeroinitializer, align 16
@msg = private constant [6 x i8] c\"hello\\00\"
@pair = internal constant { i64, i32 } { i64 1, i32 2 }
@vecc = internal constant <2 x i32> <i32 7, i32 9>
@pnull = global ptr null
@fptr = global ptr @reader

define i64 @reader() {
entry:
  %v = load i64, ptr @counter
  ret i64 %v
}
"]

[check-entry!
 "eh-itanium"
 '[(declare i32 (@pers))
   (declare void (@may_throw))
   (declare i32 (@compute i32))
   [define
    i32
    (@guarded (i32 %x))
    (personality ptr @pers)
    [label
     %entry
     (= %r (invoke i32 (@compute (i32 %x)) (label %ok) (label %lpad)))]
    (label %ok (invoke void (@may_throw) (label %done) (label %lpad2)))
    (label %done (ret i32 %r))
    [label
     %lpad
     (= %lp (landingpad (struct ptr i32) cleanup (catch ptr null)))
     (resume (struct ptr i32) %lp)]
    [label
     %lpad2
     (= %lp2 (landingpad (struct ptr i32) (filter (array 1 ptr) ((ptr null)))))
     (ret i32 -1)]]]
 "declare i32 @pers()

declare void @may_throw()

declare i32 @compute(i32)

define i32 @guarded(i32 %x) personality ptr @pers {
entry:
  %r = invoke i32 @compute(i32 %x)
          to label %ok unwind label %lpad

ok:
  invoke void @may_throw()
          to label %done unwind label %lpad2

done:
  ret i32 %r

lpad:
  %lp = landingpad { ptr, i32 }
          cleanup
          catch ptr null
  resume { ptr, i32 } %lp

lpad2:
  %lp2 = landingpad { ptr, i32 }
          filter [1 x ptr] [ptr null]
  ret i32 -1
}
"]

[check-entry!
 "eh-windows"
 '[(declare i32 (@wpers))
   (declare void (@may_throw2))
   [define
    void
    (@wineh)
    (personality ptr @wpers)
    (label %entry (invoke void (@may_throw2) (label %ok) (label %cs.bb)))
    (label %cs.bb (= %cs (catchswitch none ((label %handler)) caller)))
    [label
     %handler
     (= %cp (catchpad %cs ((ptr null) (i32 64) (ptr null))))
     (catchret %cp (label %ok))]
    (label %ok (ret void))]
   [define
    void
    (@wincleanup)
    (personality ptr @wpers)
    (label %entry (invoke void (@may_throw2) (label %ok) (label %cl.bb)))
    (label %cl.bb (= %clp (cleanuppad none ())) (cleanupret %clp caller))
    (label %ok (ret void))]]
 "declare i32 @wpers()

declare void @may_throw2()

define void @wineh() personality ptr @wpers {
entry:
  invoke void @may_throw2()
          to label %ok unwind label %cs.bb

cs.bb:
  %cs = catchswitch within none [label %handler] unwind to caller

handler:
  %cp = catchpad within %cs [ptr null, i32 64, ptr null]
  catchret from %cp to label %ok

ok:
  ret void
}

define void @wincleanup() personality ptr @wpers {
entry:
  invoke void @may_throw2()
          to label %ok unwind label %cl.bb

cl.bb:
  %clp = cleanuppad within none []
  cleanupret from %clp unwind to caller

ok:
  ret void
}
"]

[check-entry!
 "callbr"
 '[[define
    i32
    (@asmgoto (i32 %x))
    (label %entry (callbr void ((asm "" "")) (label %fall) ()))
    [label
     %fall
     [=
      %r
      [callbr
       i32
       ((asm "" "=r,r,!i" sideeffect) (i32 %x))
       (label %out)
       ((label %alt))]]]
    (label %out (ret i32 %r))
    (label %alt (ret i32 -1))]]
 "define i32 @asmgoto(i32 %x) {
entry:
  callbr void asm \"\", \"\"()
          to label %fall []

fall:
  %r = callbr i32 asm sideeffect \"\", \"=r,r,!i\"(i32 %x)
          to label %out [label %alt]

out:
  ret i32 %r

alt:
  ret i32 -1
}
"]

[check-entry!
 "tailcalls"
 '[(declare i64 (@ext i64))
   [define
    i64
    (@t1 (i64 %x))
    (label %entry (= %r (call tail i64 (@ext (i64 %x)))) (ret i64 %r))]
   [define
    i64
    (@t2 (i64 %x))
    (label %entry (= %r (call musttail i64 (@ext (i64 %x)))) (ret i64 %r))]
   [define
    i64
    (@t3 (i64 %x))
    (label %entry (= %r (call notail i64 (@ext (i64 %x)))) (ret i64 %r))]]
 "declare i64 @ext(i64)

define i64 @t1(i64 %x) {
entry:
  %r = tail call i64 @ext(i64 %x)
  ret i64 %r
}

define i64 @t2(i64 %x) {
entry:
  %r = musttail call i64 @ext(i64 %x)
  ret i64 %r
}

define i64 @t3(i64 %x) {
entry:
  %r = notail call i64 @ext(i64 %x)
  ret i64 %r
}
"]

;; calling conventions: named ones spell as LLVM's printer keywords, the
;; nameless ids as (cc N); ccc is the unwritten default. Covers headers (define
;; + declare), call sites (with tail markers and independently of the callee's
;; cc), and invoke.
[check-entry!
 "calling-conventions"
 '[(declare fastcc i64 (@fext i64))
   (declare i32 (@pers))
   [define
    tailcc
    i64
    (@self (i64 %n))
    [label
     %entry
     (= %n1 (sub i64 %n 1))
     (= %r (call musttail tailcc i64 (@self (i64 %n1))))
     (ret i64 %r)]]
   [define
    ghccc
    void
    (@stg (i64 %sp))
    [label
     %entry
     (= %r (call fastcc i64 (@fext (i64 %sp))))
     (call coldcc i64 (@fext (i64 %r)))
     (ret void)]]
   [define
    (cc 11)
    void
    (@numbered)
    (label %entry (call (cc 42) void (@numbered)) (ret void))]
   [define
    internal
    preserve_mostcc
    void
    (@linked)
    (personality ptr @pers)
    (label %entry (invoke swiftcc void (@linked) (label %ok) (label %pad)))
    (label %ok (ret void))
    (label %pad (= %lp (landingpad (struct ptr i32) cleanup)) (ret void))]]
 "declare fastcc i64 @fext(i64)

declare i32 @pers()

define tailcc i64 @self(i64 %n) {
entry:
  %n1 = sub i64 %n, 1
  %r = musttail call tailcc i64 @self(i64 %n1)
  ret i64 %r
}

define ghccc void @stg(i64 %sp) {
entry:
  %r = call fastcc i64 @fext(i64 %sp)
  %0 = call coldcc i64 @fext(i64 %r)
  ret void
}

define cc11 void @numbered() {
entry:
  call cc42 void @numbered()
  ret void
}

define internal preserve_mostcc void @linked() personality ptr @pers {
entry:
  invoke swiftcc void @linked()
          to label %ok unwind label %pad

ok:
  ret void

pad:
  %lp = landingpad { ptr, i32 }
          cleanup
  ret void
}
"]

;; function-position attributes: valueless enums by name, string attributes with
;; and without values, on both defines and declares; the printer canonicalizes
;; to #N groups, which both sides of every comparison go through
[check-entry!
 "function-attributes"
 '[(declare void (@leaf) (attributes ("gc-leaf-function")))
   (declare i32 (@cold_path i32) (attributes cold noreturn nounwind))
   [define
    void
    (@hot (i64 %n))
    [attributes
     alwaysinline
     nounwind
     ("frame-pointer" "all")
     ("target-cpu" "x86-64")]
    (label %entry (call void (@leaf)) (ret void))]
   [define
    void
    (@decorated)
    (attributes noinline optnone)
    (align 16)
    (gc "statepoint-example")
    (label %entry (ret void))]]
 "declare void @leaf() \"gc-leaf-function\"

declare i32 @cold_path(i32) cold noreturn nounwind

define void @hot(i64 %n) alwaysinline nounwind \"frame-pointer\"=\"all\" \"target-cpu\"=\"x86-64\" {
entry:
  call void @leaf()
  ret void
}

define void @decorated() noinline optnone align 16 gc \"statepoint-example\" {
entry:
  ret void
}
"]

[check-entry!
 "varargs"
 '[(declare i32 (@printf ptr variadic))
   (define i64 (@sum2 (i64 %n) variadic) (label %entry (ret i64 %n)))
   [define
    i32
    (@log (ptr %fmt) (i64 %x))
    [label
     %entry
     (= %r (call (fn i32 ptr variadic) (@printf (ptr %fmt) (i64 %x))))
     (= %s (call (fn i64 i64 variadic) (@sum2 (i64 1) (i64 %x))))
     (ret i32 %r)]]]
 "declare i32 @printf(ptr, ...)

define i64 @sum2(i64 %n, ...) {
entry:
  ret i64 %n
}

define i32 @log(ptr %fmt, i64 %x) {
entry:
  %r = call i32 (ptr, ...) @printf(ptr %fmt, i64 %x)
  %s = call i64 (i64, ...) @sum2(i64 1, i64 %x)
  ret i32 %r
}
"]

[check-entry!
 "rotated"
 '[[define
    i64
    (@rotated (i64 %x))
    (label %entry (br (label %compute)))
    (label %use (= %r (add i64 %v 1)) (ret i64 %r))
    (label %compute (= %v (mul i64 %x 2)) (br (label %use)))]]
 "define i64 @rotated(i64 %x) {
entry:
  br label %compute

use:
  %r = add i64 %v, 1
  ret i64 %r

compute:
  %v = mul i64 %x, 2
  br label %use
}
"]

(t:section "coverage: unbuild strictness (not-modeled detection)")

(define (unbuild-of-ir text) (sll:unbuild (ir:parse-ir ctx "strict" text)))

;; valueless enum + string function attributes are modeled now; the strict
;; boundary moved to valued enums and non-function positions
[t:check
 "unbuild accepts modeled function attributes"
 [equal?
  [car
   [unbuild-of-ir
    "define void @f() nounwind \"gc-leaf-function\" {\nentry:\n  ret void\n}"]]
  '[define
    void
    (@f)
    (attributes nounwind ("gc-leaf-function"))
    (label %entry (ret void))]]]
[t:check-exn
 "unbuild rejects valued function attributes"
 (unbuild-of-ir "define void @f() alignstack(8) {\nentry:\n  ret void\n}")]
[t:check-exn
 "unbuild rejects parameter attributes"
 (unbuild-of-ir "define void @f(i64 noundef %x) {\nentry:\n  ret void\n}")]
[t:check-exn
 "unbuild rejects instruction metadata"
 (unbuild-of-ir "define void @f() {\nentry:\n  ret void, !x !0\n}\n!0 = !{}")]
[t:check
 "unbuild names unnamed identified struct types by print slot"
 [equal?
  [car
   [sll:unbuild
    [ir:parse-ir
     (ir:make-context)
     "t"
     "%0 = type { i64, i64 }\ndefine void @f(ptr %p) {\nentry:\n  %v = load %0, ptr %p\n  ret void\n}"]]]
  '(type %0 (struct i64 i64))]]
;; regression: render's local `error` once wrapped itself (infinite recursion)
;; instead of base:error -- this hung rather than raised
[t:check-exn
 "render raises (not loops) on unknown items"
 (render:sll->ll '((bogus-item)))]
[t:check-exn
 "unbuild rejects function prefix data"
 (unbuild-of-ir "define void @f() prefix i32 7 {\nentry:\n  ret void\n}")]
;; calling conventions are modeled now; pin the round-trip shape here
[t:check
 "unbuild spells calling conventions"
 [equal?
  (car (unbuild-of-ir "define fastcc void @f() {\nentry:\n  ret void\n}"))
  '(define fastcc void (@f) (label %entry (ret void)))]]
[t:check-exn
 "unbuild rejects nuw+nsw constexpr binops (no C constructor)"
 [unbuild-of-ir
  "@g = global i64 0\n@p = global i64 add nuw nsw (i64 ptrtoint (ptr @g to i64), i64 1)"]]

;; constructs only expressible alongside intrinsic declarations, which LLVM
;; decorates with auto-attributes strict unbuild rejects: these goldens
;; round-trip through the corpus normalizer instead
[define
 (check-normalized-entry! name golden)
 [let*
  [(pctx (ir:make-context))
   (rctx (ir:make-context))
   (xctx (ir:make-context))
   (parsed (ir:parse-ir pctx name golden))]
  (n:normalize-module! parsed)
  [let*
   [(a (n:comparable-ir (ir:module->string parsed)))
    (prog (sll:unbuild parsed))
    (rebuilt (sll:build rctx name prog))]
   (n:normalize-module! rebuilt)
   [let
    ((b (n:comparable-ir (ir:module->string rebuilt))))
    [unless
     (string=? a b)
     (printf "~%--- rebuilt (~a) ---~%~a--- golden ---~%~a---~%" name b a)]
    (t:check (string-append "normalized round-trip: " name) (string=? a b))]
   [let*
    ((reparsed (ir:parse-ir xctx name (render:sll->ll prog))))
    (n:normalize-module! reparsed)
    [let
     ((b (n:comparable-ir (ir:module->string reparsed))))
     [unless
      (string=? a b)
      (printf "~%--- rendered (~a) ---~%~a--- golden ---~%~a---~%" name b a)]
     [t:check
      (string-append "normalized render round-trip: " name)
      (string=? a b)]]
    (ir:module-dispose! reparsed)]
   (ir:module-dispose! rebuilt)]
  (ir:module-dispose! parsed)
  (ir:context-dispose! pctx)
  (ir:context-dispose! rctx)
  (ir:context-dispose! xctx)]]

[check-entry!
 "round14"
 '[(datalayout "e-A5")
   (module-asm ".globl marker\nmarker:")
   (= @ext (global externally_initialized i32 0))
   ;; NaN payloads travel as folded bitcast constexprs (bit-exact)
   (= @nan (global half (bitcast i16 31745 half)))
   (declare i32 (@resolvee i32))
   (define ptr (@resolver) (label %entry (ret ptr @resolvee)))
   (= @fast_op (ifunc (fn i32 i32) (ptr @resolver)))
   [define
    i64
    (@atomics ((ptr (addrspace 5)) %p) (i64 %v))
    [label
     %entry
     (= %spill (alloca i64 (align 8) (addrspace 5)))
     [store
      atomic
      singlethread
      (i64 %v)
      ((ptr (addrspace 5)) %p)
      seq_cst
      (align 8)]
     [=
      %old
      [atomicrmw
       volatile
       singlethread
       add
       ((ptr (addrspace 5)) %p)
       (i64 1)
       monotonic
       (align 8)]]
     (fence singlethread acquire)
     (ret i64 %old)]]]
 "target datalayout = \"e-A5\"

module asm \".globl marker\"
module asm \"marker:\"

@ext = externally_initialized global i32 0
@nan = global half 0xH7C01

@fast_op = ifunc i32 (i32), ptr @resolver

declare i32 @resolvee(i32)

define ptr @resolver() {
entry:
  ret ptr @resolvee
}

define i64 @atomics(ptr addrspace(5) %p, i64 %v) {
entry:
  %spill = alloca i64, align 8, addrspace(5)
  store atomic i64 %v, ptr addrspace(5) %p syncscope(\"singlethread\") seq_cst, align 8
  %old = atomicrmw volatile add ptr addrspace(5) %p, i64 1 syncscope(\"singlethread\") monotonic, align 8
  fence syncscope(\"singlethread\") acquire
  ret i64 %old
}
"]

[check-entry!
 "gc-bundles"
 '[(datalayout "e-m:e-p:64:64-i64:64-ni:1")
   (triple "x86_64-unknown-linux-gnu")
   (declare void (@runtime_call))
   [define
    void
    (@managed (i64 %frame) ((ptr (addrspace 1)) %obj))
    (gc "statepoint-example")
    [label
     %entry
     [call
      void
      (@runtime_call)
      (bundle "deopt" (i64 %frame) (i32 7))
      (bundle "gc-live" ((ptr (addrspace 1)) %obj))]
     (ret void)]]]
 "target datalayout = \"e-m:e-p:64:64-i64:64-ni:1\"
target triple = \"x86_64-unknown-linux-gnu\"

declare void @runtime_call()

define void @managed(i64 %frame, ptr addrspace(1) %obj) gc \"statepoint-example\" {
entry:
  call void @runtime_call() [ \"deopt\"(i64 %frame, i32 7), \"gc-live\"(ptr addrspace(1) %obj) ]
  ret void
}
"]

[check-normalized-entry!
 "statepoints"
 "define ptr addrspace(1) @relocate_obj(ptr addrspace(1) %obj) gc \"statepoint-example\" {
entry:
  %tok = call token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0(i64 0, i32 0, ptr elementtype(void ()) @do_safepoint, i32 0, i32 0) [ \"deopt\"(i32 1), \"gc-live\"(ptr addrspace(1) %obj) ]
  %obj.r = call ptr addrspace(1) @llvm.experimental.gc.relocate.p1(token %tok, i32 0, i32 0)
  ret ptr addrspace(1) %obj.r
}

define i32 @with_result() gc \"statepoint-example\" {
entry:
  %tok = call token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0(i64 0, i32 0, ptr elementtype(i32 ()) @compute, i32 0, i32 0)
  %r = call i32 @llvm.experimental.gc.result.i32(token %tok)
  ret i32 %r
}

declare void @do_safepoint()
declare i32 @compute()
declare token @llvm.experimental.gc.statepoint.p0(i64, i32, ptr, i32, i32, ...)
declare ptr addrspace(1) @llvm.experimental.gc.relocate.p1(token, i32, i32)
declare i32 @llvm.experimental.gc.result.i32(token)
"]

[check-normalized-entry!
 "metadata-operands"
 "declare float @llvm.experimental.constrained.fadd.f32(float, float, metadata, metadata)
declare i64 @llvm.read_register.i64(metadata)
declare void @llvm.write_register.i64(metadata, i64)
declare i1 @llvm.type.test(ptr, metadata)

define float @strict_add(float %a, float %b) {
entry:
  %r = call float @llvm.experimental.constrained.fadd.f32(float %a, float %b, metadata !\"round.dynamic\", metadata !\"fpexcept.strict\")
  ret float %r
}

define i64 @regs() {
entry:
  %v = call i64 @llvm.read_register.i64(metadata !0)
  call void @llvm.write_register.i64(metadata !1, i64 %v)
  ret i64 %v
}

define i1 @check(ptr %p) {
entry:
  %ok = call i1 @llvm.type.test(ptr %p, metadata !\"vtable_id\")
  ret i1 %ok
}

!0 = !{!\"sp\"}
!1 = !{!\"fp\"}
"]

[check-entry!
 "aliases"
 '[(= @g (global i64 7))
   (= @a (alias i64 (ptr @g)))
   (= @b (alias internal i64 (ptr @a)))
   ;; a zero-offset gep aliasee folds to the plain global (symmetric
   ;; ConstantExpr::get folding, same on the parse side)
   (= @elt (alias i32 (ptr (getelementptr inbounds i64 (ptr @g) (i64 0)))))
   (declare i32 (@ext i32) (align 16))
   [define
    internal
    i64
    (@f)
    (align 32)
    (label %entry (= %v (load i64 (ptr @a))) (ret i64 %v))]
   (= @fa (alias (fn i64) (ptr @f)))]
 "@g = global i64 7

@a = alias i64, ptr @g
@b = internal alias i64, ptr @a
@elt = alias i32, ptr @g
@fa = alias i64 (), ptr @f

declare i32 @ext(i32) align 16

define internal i64 @f() align 32 {
entry:
  %v = load i64, ptr @a, align 4
  ret i64 %v
}
"]

[check-entry!
 "constexprs"
 '[(= @g (global i64 0))
   (type %pair (struct i64 i32))
   (= @arr (global (array 4 %pair) zeroinitializer))
   (= @addr (global i64 (ptrtoint ptr @g i64)))
   (= @back (global ptr (inttoptr i64 74565 ptr)))
   (= @off (global i64 (add nuw i64 (ptrtoint ptr @g i64) 16)))
   (= @dif (global i64 (sub i64 (ptrtoint ptr @g i64) (ptrtoint ptr @arr i64))))
   (= @msk (global i64 (xor i64 (ptrtoint ptr @g i64) 1)))
   ;; trunc-of-ptrtoint folds to a narrower ptrtoint on BOTH paths
   ;; (ConstantExpr::get folding is symmetric with the parser)
   (= @lo (global i32 (trunc i64 (ptrtoint ptr @g i64) i32)))
   [=
    @sp
    (global (ptr (addrspace 1)) (addrspacecast ptr @g (ptr (addrspace 1))))]
   [=
    @fld
    (global ptr (getelementptr inbounds %pair (ptr @arr) (i64 2) (i32 1)))]
   (= @raw (global ptr (getelementptr nuw i8 (ptr @g) (i64 8))))
   [define
    i64
    (@f)
    [label
     %entry
     [=
      %v
      [load
       i64
       (ptr (getelementptr inbounds %pair (ptr @arr) (i64 1) (i32 0)))]]
     (= %s (add i64 %v (ptrtoint ptr @g i64)))
     (ret i64 %s)]]]
 "%pair = type { i64, i32 }

@g = global i64 0
@arr = global [4 x %pair] zeroinitializer
@addr = global i64 ptrtoint (ptr @g to i64)
@back = global ptr inttoptr (i64 74565 to ptr)
@off = global i64 add nuw (i64 ptrtoint (ptr @g to i64), i64 16)
@dif = global i64 sub (i64 ptrtoint (ptr @g to i64), i64 ptrtoint (ptr @arr to i64))
@msk = global i64 xor (i64 ptrtoint (ptr @g to i64), i64 1)
@lo = global i32 ptrtoint (ptr @g to i32)
@sp = global ptr addrspace(1) addrspacecast (ptr @g to ptr addrspace(1))
@fld = global ptr getelementptr inbounds (%pair, ptr @arr, i64 2, i32 1)
@raw = global ptr getelementptr nuw (i8, ptr @g, i64 8)

define i64 @f() {
entry:
  %v = load i64, ptr getelementptr inbounds (%pair, ptr @arr, i64 1, i32 0), align 4
  %s = add i64 %v, ptrtoint (ptr @g to i64)
  ret i64 %s
}
"]

[check-entry!
 "edge-shapes"
 '[(= @z (global (array 0 i64) zeroinitializer))
   (declare void (@ext))
   [define
    void
    (@f (ptr %p))
    [label
     %entry
     (= %v (alloca (vector 2 ptr)))
     [store
      ((vector 2 ptr) ((ptr (blockaddress @f %a)) (ptr (blockaddress @f %b))))
      (ptr %v)]
     (indirectbr (ptr %p) (label %a) (label %b))]
    (label %a (indirectbr (ptr %p)))
    (label %b (ret void))]
   [define
    void
    (@g)
    (personality i8 7)
    (label %entry (invoke void (@ext) (label %ok) (label %pad)))
    (label %cleanup (cleanupret %cp caller))
    (label %pad (= %cp (cleanuppad none ())) (br (label %cleanup)))
    (label %ok (ret void))]]
 "@z = global [0 x i64] zeroinitializer

declare void @ext()

define void @f(ptr %p) {
entry:
  %v = alloca <2 x ptr>, align 16
  store <2 x ptr> <ptr blockaddress(@f, %a), ptr blockaddress(@f, %b)>, ptr %v, align 16
  indirectbr ptr %p, [label %a, label %b]

a:                                                ; preds = %entry
  indirectbr ptr %p, []

b:                                                ; preds = %entry
  ret void
}

define void @g() personality i8 7 {
entry:
  invoke void @ext()
          to label %ok unwind label %pad

cleanup:                                          ; preds = %pad
  cleanupret from %cp unwind to caller

pad:                                              ; preds = %entry
  %cp = cleanuppad within none []
  br label %cleanup

ok:                                               ; preds = %entry
  ret void
}
"]

[check-entry!
 "wide-floats"
 '[(= @h (global half 2.0))
   (= @bf (global bfloat 2.0))
   (= @e (global x86_fp80 -2.5))
   (= @q (global fp128 -0.0))
   (= @pq (global ppc_fp128 2.0))
   [define
    fp128
    (@pick (i1 %c))
    [label
     %entry
     (= %r (select (i1 %c) (fp128 1.0) (fp128 0.5)))
     (ret fp128 %r)]]]
 "@h = global half 0xH4000
@bf = global bfloat 0xR4000
@e = global x86_fp80 0xKC000A000000000000000
@q = global fp128 0xL00000000000000008000000000000000
@pq = global ppc_fp128 0xM40000000000000000000000000000000

define fp128 @pick(i1 %c) {
entry:
  %r = select i1 %c, fp128 0xL00000000000000003FFF000000000000, fp128 0xL00000000000000003FFE000000000000
  ret fp128 %r
}
"]

[check-entry!
 "named-types"
 '[(type %pair (struct i64 i32))
   (type %node (struct i64 ptr))
   (type %packed (packed-struct i8 i64))
   [define
    i64
    (@first (ptr %p))
    [label
     %entry
     (= %v (load %pair (ptr %p)))
     (= %f (extractvalue (%pair %v) 0))
     (= %n (load %node (ptr %p)))
     (= %next (extractvalue (%node %n) 1))
     (= %pk (load %packed (ptr %p)))
     (= %pv (extractvalue (%packed %pk) 1))
     (= %o (load ptr (ptr %next)))
     (= %r (add i64 %f %pv))
     (ret i64 %r)]]
   (= @wide (global i128 170141183460469231731687303715884105727))
   (= @spaced (global (addrspace 1) i64 7))
   [define
    (vector 4 i32)
    (@lanes ((vector 4 i32) %v))
    [label
     %entry
     [=
      %s
      [shufflevector
       ((vector 4 i32) %v)
       ((vector 4 i32) poison)
       (mask 0 poison 1 poison)]]
     (ret (vector 4 i32) %s)]]
   [define
    (scalable-vector 2 i64)
    (@sv ((scalable-vector 2 i64) %v))
    (label %entry (ret (scalable-vector 2 i64) %v))]]
 "%pair = type { i64, i32 }
%node = type { i64, ptr }
%packed = type <{ i8, i64 }>

@wide = global i128 170141183460469231731687303715884105727
@spaced = addrspace(1) global i64 7

define i64 @first(ptr %p) {
entry:
  %v = load %pair, ptr %p
  %f = extractvalue %pair %v, 0
  %n = load %node, ptr %p
  %next = extractvalue %node %n, 1
  %pk = load %packed, ptr %p
  %pv = extractvalue %packed %pk, 1
  %o = load ptr, ptr %next
  %r = add i64 %f, %pv
  ret i64 %r
}

define <4 x i32> @lanes(<4 x i32> %v) {
entry:
  %s = shufflevector <4 x i32> %v, <4 x i32> poison, <4 x i32> <i32 0, i32 poison, i32 1, i32 poison>
  ret <4 x i32> %s
}

define <vscale x 2 x i64> @sv(<vscale x 2 x i64> %v) {
entry:
  ret <vscale x 2 x i64> %v
}
"]

;; ---- the ledger check (level 1)
;; -----------------------------------------------------

(t:section "coverage: observed + excluded = oracle (level 1)")

;; -> (values missing-names overlap-names stale-names implemented-count
;; excluded-count)
[define
 (audit-axis axis oracle observed)
 [let
  ((excluded (exclusions-for axis)))
  [let
   loop
   ((entries oracle) (missing '()) (overlap '()) (count 0))
   [if
    (null? entries)
    [values
     (reverse missing)
     (reverse overlap)
     (filter (lambda (x) (not (assq x oracle))) excluded)
     count
     (length excluded)]
    [let*
     [(name (caar entries))
      (value (cdar entries))
      (obs? (hashtable-ref observed value #f))
      (exc? (memq name excluded))]
     [loop
      (cdr entries)
      (if (or obs? exc?) missing (cons name missing))
      (if (and obs? exc?) (cons name overlap) overlap)
      (if obs? (+ count 1) count)]]]]]]

[define
 (check-axis! label axis oracle observed)
 [let-values
  (((missing overlap stale count excluded) (audit-axis axis oracle observed)))
  [printf
   "  ~a: ~a implemented + ~a excluded = ~a/~a~%"
   label
   count
   excluded
   (+ count excluded)
   (length oracle)]
  [unless
   (null? missing)
   (printf "    NOT implemented and NOT excluded: ~a~%" missing)]
  [unless
   (null? overlap)
   (printf "    implemented but still excluded: ~a~%" overlap)]
  [unless
   (null? stale)
   (printf "    excluded but not in the oracle: ~a~%" stale)]
  [t:check
   (string-append label ": observed + excluded = oracle")
   (and (null? missing) (null? overlap) (null? stale))]]]

(check-axis! "opcodes" 'opcode opcode-oracle observed-opcodes)
[check-axis!
 "icmp predicates"
 'int-predicate
 int-pred-oracle
 observed-int-preds]
[check-axis!
 "fcmp predicates"
 'real-predicate
 real-pred-oracle
 observed-real-preds]
(check-axis! "fast-math flags" 'fast-math fmf-oracle observed-fmf)
(check-axis! "gep flags" 'gep-flag gep-flag-oracle observed-gep-flags)
(check-axis! "atomic orderings" 'ordering ordering-oracle observed-orderings)
(check-axis! "atomicrmw ops" 'rmw-binop rmw-oracle observed-rmw-ops)
(check-axis! "linkages" 'linkage linkage-oracle observed-linkages)
(check-axis! "tail-call kinds" 'tail-kind tailkind-oracle observed-tail-kinds)

[t:check
 "oracle extraction sane: LLVMRet = 1"
 (= (cdr (assq 'LLVMRet opcode-oracle)) 1)]
[t:check
 "oracle extraction sane: LLVMIntEQ = 32"
 (= (cdr (assq 'LLVMIntEQ int-pred-oracle)) 32)]
[t:check
 "oracle extraction sane: LLVMFastMathNoNaNs = 2"
 (= (cdr (assq 'LLVMFastMathNoNaNs fmf-oracle)) 2)]
[t:check
 "oracle extraction sane: LLVMGEPFlagNUW = 4"
 (= (cdr (assq 'LLVMGEPFlagNUW gep-flag-oracle)) 4)]

(ir:context-dispose! ctx)
