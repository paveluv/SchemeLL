;;; (llscheme ll) -- LLVM IR as s-expressions: the first llscheme layer.
;;; Grammar and rationale: project/ll-design.md. Import as:
;;;   (prefix (llscheme ll) ll:)
;;;
;;; An ll program is plain data -- a list of module items:
;;;   (define <type> (@name (<type> %arg) ...) <block> ...)
;;;   (declare <type> (@name <type> ...))
;;; A function body is a list of block groups, mirroring LLVM's object
;;; model (functions contain blocks contain instructions):
;;;   (label %name <insn> ... <terminator>)
;;; The first group is the entry block. Instructions are textual LLVM IR
;;; transliterated: commas dropped, parens added, `%x = rhs` as
;;; (= %x (rhs)), types kept in IR position, phi pairs as (value %label).
;;;
;;; The interpreter builds an (llvm ir) module in two passes per program
;;; (declare all functions, then emit bodies) and two passes per function
;;; (create all blocks, then emit their instructions), so branches and
;;; phi incoming may reference blocks defined later. phi is the only
;;; permitted forward reference to a *value*; everything else must be
;;; defined textually before use.
(library (llscheme ll)
  (export build jit dump unbuild)
  (import (chezscheme)
          (prefix (llvm base) base:)
          (prefix (llvm ir) ir:)
          (prefix (llvm jit) jit:)
          (llscheme ll unbuild))

  (define (ll-error msg . irritants)
    (apply base:error 'll:build msg irritants))

  ;; ---- names ---------------------------------------------------------------

  (define (sigil-name? ch x)
    (and (symbol? x)
         (let ([s (symbol->string x)])
           (and (> (string-length s) 1) (char=? (string-ref s 0) ch)))))

  (define (local-name? x) (sigil-name? #\% x))   ; %value or %label
  (define (global-name? x) (sigil-name? #\@ x))  ; @function

  (define (strip-sigil x)
    (let ([s (symbol->string x)])
      (substring s 1 (string-length s))))

  ;; All-digit names (%0, %42) are positional/anonymous, as in textual IR
  ;; where digits are slot numbers, not names: ll binds them in its own
  ;; environment but leaves the LLVM value unnamed, so LLVM's printer
  ;; reproduces the numbering itself.
  (define (anonymous-name? s)
    (and (> (string-length s) 0)
         (let loop ([i 0])
           (or (fx= i (string-length s))
               (and (char-numeric? (string-ref s i))
                    (loop (fx+ i 1)))))))

  (define (llvm-name x)   ; %sym -> the name to give LLVM ("" = unnamed)
    (let ([s (strip-sigil x)])
      (if (anonymous-name? s) "" s)))

  ;; ---- types -----------------------------------------------------------------

  (define (int-bits t)   ; i1, i8, ..., iN -> N; anything else -> #f
    (let ([s (symbol->string t)])
      (and (> (string-length s) 1)
           (char=? (string-ref s 0) #\i)
           (let ([n (string->number (substring s 1 (string-length s)))])
             (and (fixnum? n) (positive? n) n)))))

  ;; strip an optional trailing `variadic` marker (never spelled `...`,
  ;; which would collide with ellipsis in nanopass/syntax-rules patterns)
  (define (split-variadic lst)
    (if (and (pair? lst) (eq? (car (last-pair lst)) 'variadic))
        (values (reverse (cdr (reverse lst))) #t)
        (values lst #f)))

  ;; iN, float, double, ptr, void; (ptr (addrspace N));
  ;; (array N TY); (vector N TY); (struct TY ...);
  ;; (fn RET ARG ... variadic?) function types
  (define (resolve-type ctx t)
    (cond
      [(symbol? t)
       (case t
         [(ptr) (ir:pointer-type ctx)]
         [(float) (ir:float-type ctx)]
         [(double) (ir:double-type ctx)]
         [(half) (ir:half-type ctx)]
         [(bfloat) (ir:bfloat-type ctx)]
         [(fp128) (ir:fp128-type ctx)]
         [(x86_fp80) (ir:x86fp80-type ctx)]
         [(ppc_fp128) (ir:ppcfp128-type ctx)]
         [(void) (ir:void-type ctx)]
         [(metadata) (ir:metadata-type ctx)]
         [(token) (ir:token-type ctx)]
         [else
          (if (local-name? t)
              ;; %name: a named struct type from a (type %name ...) item
              (or (ir:named-type ctx (strip-sigil t))
                  (ll-error "unknown named type" t))
              (let ([bits (int-bits t)])
                (unless bits (ll-error "unknown type" t))
                (ir:int-type ctx bits)))])]
      [(pair? t)
       (cond
         [(eq? (car t) 'struct)
          (ir:struct-type ctx (map (lambda (e) (resolve-type ctx e)) (cdr t)))]
         [(eq? (car t) 'packed-struct)
          (ir:struct-type ctx (map (lambda (e) (resolve-type ctx e)) (cdr t)) #t)]
         [(and (eq? (car t) 'scalable-vector) (= (length t) 3)
               (fixnum? (cadr t)) (positive? (cadr t)))
          (ir:scalable-vector-type (resolve-type ctx (caddr t)) (cadr t))]
         [(and (eq? (car t) 'ptr) (= (length t) 2)
               (pair? (cadr t)) (eq? (caadr t) 'addrspace)
               (= (length (cadr t)) 2) (fixnum? (cadr (cadr t)))
               (fx>= (cadr (cadr t)) 0))
          (ir:pointer-type ctx (cadr (cadr t)))]
         [(and (eq? (car t) 'ptr) (= (length t) 2) (fixnum? (cadr t)))
          ;; reserved: (ptr N) in operand position will mean an
          ;; inttoptr'd address constant some day
          (ll-error "expected (ptr (addrspace N))" t)]
         ;; lengths are uint64 in LLVM ([0 x T] and beyond-fixnum sizes
         ;; are both legal), so exact integers, not fixnums
         [(and (eq? (car t) 'array) (= (length t) 3)
               (exact? (cadr t)) (integer? (cadr t))
               (<= 0 (cadr t)) (< (cadr t) (expt 2 64)))
          (ir:array-type (resolve-type ctx (caddr t)) (cadr t))]
         [(and (eq? (car t) 'vector) (= (length t) 3)
               (fixnum? (cadr t)) (positive? (cadr t)))
          (ir:vector-type (resolve-type ctx (caddr t)) (cadr t))]
         [(eq? (car t) 'fn)
          (let-values ([(parts variadic?) (split-variadic (cdr t))])
            (unless (pair? parts)
              (ll-error "expected (fn ret-type arg-type ... variadic?)" t))
            (ir:function-type
              (resolve-type ctx (car parts))
              (map (lambda (a) (resolve-type ctx a)) (cdr parts))
              variadic?))]
         [else (ll-error "invalid type" t)])]
      [else (ll-error "invalid type" t)]))

  ;; ---- per-function build state ------------------------------------------------

  (define-record-type fstate
    (fields ctx builder globals locals blocks fname fn
            (mutable phis) (mutable scratch) pending))

  ;; ---- operands ------------------------------------------------------------------

  ;; per-element-typed aggregate constant, e.g. ((i64 1) (i32 2)) -- every
  ;; element a (type value) pair; disambiguated from a single typed operand
  ;; group by the first element's head never being a type constructor
  ;; heads that make a pair a TYPE form; ptr only as (ptr (addrspace N))
  ;; -- (ptr X) with any other X is a ptr-typed operand group
  (define (type-form? h)
    (and (pair? h)
         (case (car h)
           [(struct packed-struct array vector scalable-vector fn) #t]
           [(ptr) (and (pair? (cdr h)) (pair? (cadr h))
                       (eq? (car (cadr h)) 'addrspace))]
           [else #f])))
  (define (aggregate-literal? form)
    (and (pair? form)
         (for-all (lambda (e)
                    (and (pair? e) (pair? (cdr e)) (null? (cddr e))))
                  form)
         (or (not (= (length form) 2))
             (let ([h (car form)])
               (and (pair? h)
                    (not (type-form? h))
                    (not (local-name? (car h))))))))

  ;; metadata operand: (md "string") | (md (element ...)) -> MetadataRef
  (define (resolve-md-ref ctx form)
    (unless (and (pair? form) (eq? (car form) 'md) (= (length form) 2))
      (ll-error "expected (md \"string\") or (md (element ...))" form))
    (let ([x (cadr form)])
      (cond
        [(string? x) (ir:md-string ctx x)]
        [(list? x)
         (ir:md-node ctx (map (lambda (e) (resolve-md-ref ctx e)) x))]
        [else
         (ll-error "expected (md \"string\") or (md (element ...))" form)])))

  ;; call-site operand bundles: (bundle "tag" (type arg) ...)
  (define (bundle-form? x) (and (pair? x) (eq? (car x) 'bundle)))
  (define (resolve-bundle st bf)
    (unless (and (bundle-form? bf) (>= (length bf) 2) (string? (cadr bf)))
      (ll-error "expected (bundle \"tag\" (type arg) ...)" bf))
    (ir:create-operand-bundle
      (cadr bf)
      (map (lambda (g)
             (unless (and (pair? g) (= (length g) 2))
               (ll-error "bundle arguments are (type value) groups" g bf))
             (resolve-operand st (resolve-type (fstate-ctx st) (car g))
                              (cadr g)))
           (cddr bf))))

  ;; ty types bare literals; #f when the position carries no type of its own
  ;; (then literals must come as a (type value) group).
  (define (resolve-operand st ty form)
    (cond
      [(eq? form 'undef)
       (unless ty (ll-error "undef needs a type annotation" form))
       (ir:undef-value ty)]
      [(eq? form 'poison)
       (unless ty (ll-error "poison needs a type annotation" form))
       (ir:poison-value ty)]
      [(local-name? form)
       (or (hashtable-ref (fstate-locals st) form #f)
           ;; not defined yet: legal when the defining block only appears
           ;; textually later (dominance is what matters, and LLVM's own
           ;; printer emits such IR) -- create a placeholder to patch at
           ;; end of function. Needs a type; untyped positions cannot
           ;; forward-reference.
           (and ty (forward-placeholder st ty form))
           (ll-error "unbound local in an untyped position (cannot forward-reference)"
                     form (fstate-fname st)))]
      [(global-name? form)
       (or (hashtable-ref (fstate-globals st) form #f)
           (ll-error "unbound global" form (fstate-fname st)))]
      [(and (pair? form) (eq? (car form) 'blockaddress))
       ;; (blockaddress @function %label) -- a ptr constant
       (unless (and (= (length form) 3) (global-name? (cadr form))
                    (local-name? (caddr form)))
         (ll-error "expected (blockaddress @function %label)" form))
       (unless (eq? (cadr form) (fstate-fname st))
         (ll-error "blockaddress currently supports only the enclosing function"
                   form (fstate-fname st)))
       (ir:block-address
         (hashtable-ref (fstate-globals st) (cadr form) #f)
         (block-by-name st (caddr form)))]
      [(memq form '(null zeroinitializer none))
       (unless ty (ll-error "null/zeroinitializer/none needs a type annotation"
                            form))
       (ir:const-null ty)]
      [(and (integer? form) (exact? form))
       (unless ty (ll-error "integer literal needs a type annotation" form))
       (ir:const-int ty form)]
      [(flonum? form)
       (unless ty (ll-error "float literal needs a type annotation" form))
       (ir:const-real ty form)]
      [(and (pair? form) (memq (car form) '(c cz)))
       (unless ty (ll-error "string constant needs a type annotation" form))
       (resolve-constant (fstate-ctx st) (fstate-globals st) ty form)]
      [(and (pair? form) (eq? (car form) 'md))
       (ir:metadata-value (fstate-ctx st)
                          (resolve-md-ref (fstate-ctx st) form))]
      [(and (pair? form)
            (memq (car form) '(trunc ptrtoint inttoptr bitcast addrspacecast
                                add sub mul xor getelementptr)))
       ;; a constant expression in operand position; self-typed
       (resolve-constant (fstate-ctx st) (fstate-globals st) ty form
                         (lambda (ety ef) (resolve-operand st ety ef)))]
      [(aggregate-literal? form)
       (unless ty (ll-error "aggregate constant needs a type annotation" form))
       (resolve-constant (fstate-ctx st) (fstate-globals st) ty form
                         (lambda (ety ef) (resolve-operand st ety ef)))]
      [(and (pair? form) (pair? (cdr form)) (null? (cddr form)))
       ;; typed operand group: (type value)
       (resolve-operand st (resolve-type (fstate-ctx st) (car form)) (cadr form))]
      [else (ll-error "invalid operand" form (fstate-fname st))]))

  ;; a unique, typed, erasable stand-in for a not-yet-defined %name:
  ;; a freeze-of-undef instruction in a scratch block that is deleted
  ;; after fixup-forwards! rewires every use to the real value
  (define (forward-placeholder st ty name)
    (or (hashtable-ref (fstate-pending st) name #f)
        (let ([b (fstate-builder st)])
          (let ([cur (ir:insert-block b)]
                [scratch (or (fstate-scratch st)
                             (let ([sb (ir:append-block (fstate-ctx st)
                                                        (fstate-fn st)
                                                        "llscheme.fwd")])
                               (fstate-scratch-set! st sb)
                               sb))])
            (ir:position-at-end! b scratch)
            ;; freeze cannot take a token; a token placeholder is a
            ;; parentless cleanuppad in the scratch block instead
            (let ([ph (if (eq? (ir:type-kind ty) 'token)
                          (ir:build-cleanuppad
                            b (ir:const-null ty) '() "")
                          (ir:build-freeze b (ir:undef-value ty) ""))])
              (ir:position-at-end! b cur)
              (hashtable-set! (fstate-pending st) name ph)
              ph)))))

  (define (fixup-forwards! st)
    (let-values ([(names phs) (hashtable-entries (fstate-pending st))])
      (vector-for-each
        (lambda (name ph)
          (let ([real (hashtable-ref (fstate-locals st) name #f)])
            (unless real
              (ll-error "unbound local" name (fstate-fname st)))
            (ir:replace-all-uses! ph real)
            (ir:erase-instruction! ph)))
        names phs))
    (when (fstate-scratch st)
      (ir:delete-block! (fstate-scratch st))))

  ;; ---- blocks -----------------------------------------------------------------------

  (define (label-form? f) (and (pair? f) (eq? (car f) 'label)))

  (define (block-by-name st name)
    (unless (local-name? name) (ll-error "invalid label name" name))
    (or (hashtable-ref (fstate-blocks st) name #f)
        (ll-error "unknown label" name (fstate-fname st))))

  (define (block-ref st form)   ; a (label %x) branch target
    (unless (and (label-form? form) (pair? (cdr form)) (null? (cddr form))
                 (local-name? (cadr form)))
      (ll-error "expected branch target (label %name)" form (fstate-fname st)))
    (block-by-name st (cadr form)))

  ;; block group: (label %name <insn> ... <terminator>)
  (define (check-block-group g fname)
    (unless (label-form? g)
      (ll-error "instruction outside a block (expected (label %name insn ...))"
                g fname))
    (unless (and (pair? (cdr g)) (local-name? (cadr g)))
      (ll-error "block label must be a %name" g fname))
    (when (null? (cddr g))
      (ll-error "empty block" (cadr g) fname))
    (unless (terminator-form? (car (last-pair g)))
      (ll-error "block does not end in a terminator" (cadr g) fname)))

  (define (add-block! st f name)
    (when (hashtable-ref (fstate-blocks st) name #f)
      (ll-error "duplicate label" name (fstate-fname st)))
    (hashtable-set! (fstate-blocks st) name
                    (ir:append-block (fstate-ctx st) f (llvm-name name))))

  ;; ---- the opcode tables ----------------------------------------------------------------

  (define binops             ; (op type a b)
    `((add . ,ir:build-add) (sub . ,ir:build-sub) (mul . ,ir:build-mul)
      (sdiv . ,ir:build-sdiv) (udiv . ,ir:build-udiv)
      (srem . ,ir:build-srem) (urem . ,ir:build-urem)
      (and . ,ir:build-and) (or . ,ir:build-or) (xor . ,ir:build-xor)
      (shl . ,ir:build-shl) (lshr . ,ir:build-lshr) (ashr . ,ir:build-ashr)
      (fadd . ,ir:build-fadd) (fsub . ,ir:build-fsub)
      (fmul . ,ir:build-fmul) (fdiv . ,ir:build-fdiv)
      (frem . ,ir:build-frem)))

  (define casts              ; (op type value to type)
    `((trunc . ,ir:build-trunc) (zext . ,ir:build-zext) (sext . ,ir:build-sext)
      (fptrunc . ,ir:build-fptrunc) (fpext . ,ir:build-fpext)
      (fptosi . ,ir:build-fp->si) (fptoui . ,ir:build-fp->ui)
      (sitofp . ,ir:build-si->fp) (uitofp . ,ir:build-ui->fp)
      (ptrtoint . ,ir:build-ptr->int) (inttoptr . ,ir:build-int->ptr)
      (bitcast . ,ir:build-bitcast) (addrspacecast . ,ir:build-addrspacecast)))

  ;; LLVMAtomicOrdering; cross-checked against the headers by the coverage
  ;; tests. NotAtomic (0) is the absence of an ordering, not writable.
  (define atomic-orderings
    '((unordered . 1) (monotonic . 2) (acquire . 4) (release . 5)
      (acq_rel . 6) (seq_cst . 7)))

  (define (ordering-int sym form)
    (cond
      [(and (symbol? sym) (assq sym atomic-orderings)) => cdr]
      [else (ll-error "unknown atomic ordering" sym form)]))

  ;; trailing [ordering] before the attribute groups of atomic load/store
  (define (split-ordering rest form)
    (if (and (pair? rest) (symbol? (car rest)))
        (cond
          [(assq (car rest) atomic-orderings) =>
           (lambda (p) (values (cdr p) (cdr rest)))]
          [else (ll-error "unknown ordering or attribute" (car rest) form)])
        (values #f rest)))

  ;; callee of call/invoke/callbr: a function/pointer operand, or inline
  ;; asm: (asm "template" "constraints" flag ...), flags: sideeffect
  ;; alignstack. callbr requires an asm callee (LLVM restriction).
  (define (resolve-callee st fnty form)
    (if (and (pair? form) (eq? (car form) 'asm))
        (begin
          (unless (and (>= (length form) 3) (string? (cadr form))
                       (string? (caddr form))
                       (for-all (lambda (f) (memq f '(sideeffect alignstack)))
                                (cdddr form)))
            (ll-error "expected (asm \"template\" \"constraints\" flag ...)" form))
          (ir:inline-asm fnty (cadr form) (caddr form)
                         (and (memq 'sideeffect (cdddr form)) #t)
                         (and (memq 'alignstack (cdddr form)) #t)))
        ;; the callee slot is ptr-typed: lets undef/null callees and
        ;; forward references through
        (resolve-operand st (ir:pointer-type (fstate-ctx st)) form)))

  ;; the type slot of call/invoke/callbr holds either the result type (the
  ;; call-site function type is then built from the argument groups) or a
  ;; full (fn ...) type -- required for vararg calls, as in IR's
  ;; `call i32 (ptr, ...) @printf(...)`.
  ;; -> (values fn-type result-type arg-values)
  (define (callsite-signature st ctx ty-form groups form)
    (for-each
      (lambda (g)
        (unless (and (pair? g) (pair? (cdr g)) (null? (cddr g)))
          (ll-error "call argument must be (type value)" g form)))
      groups)
    (let ([avals (map (lambda (g)
                        (resolve-operand st (resolve-type ctx (car g)) (cadr g)))
                      groups)])
      (if (and (pair? ty-form) (eq? (car ty-form) 'fn))
          (let ([fnty (resolve-type ctx ty-form)])
            (values fnty (ir:type-return-type fnty) avals))
          (let ([retty (resolve-type ctx ty-form)])
            (values (ir:function-type
                      retty (map (lambda (g) (resolve-type ctx (car g))) groups))
                    retty avals)))))

  ;; `within` parent of catchswitch/catchpad/cleanuppad: none | %pad;
  ;; token-typed, so forward references get token placeholders
  (define (parent-pad st ctx form)
    (if (eq? form 'none)
        (ir:const-null (ir:token-type ctx))
        (resolve-operand st (ir:token-type ctx) form)))

  ;; unwind destination: the keyword operand `caller` -> #f, or (label %x)
  (define (unwind-dest st rest form)
    (cond
      [(equal? rest '(caller)) #f]
      [(and (pair? rest) (null? (cdr rest))) (block-ref st (car rest))]
      [else (ll-error "expected unwind destination: caller or (label %x)"
                      form (fstate-fname st))]))

  ;; LLVMAtomicRMWBinOp; cross-checked by the coverage tests
  (define rmw-ops
    '((xchg . 0) (add . 1) (sub . 2) (and . 3) (nand . 4) (or . 5) (xor . 6)
      (max . 7) (min . 8) (umax . 9) (umin . 10) (fadd . 11) (fsub . 12)
      (fmax . 13) (fmin . 14) (uinc_wrap . 15) (udec_wrap . 16)))

  ;; ---- instruction flags -----------------------------------------------------
  ;; Flags sit where IR writes them: between the opcode and the type (for
  ;; fcmp, before the predicate). They are peeled off the front of the
  ;; argument list, validated per opcode, and applied to the built
  ;; instruction via the C API setters (getelementptr takes its no-wrap
  ;; mask at construction instead).

  ;; LLVMFastMathFlags bits; cross-checked against the installed headers
  ;; by tests/test-coverage.ss
  (define fmf-bits
    '((reassoc . 1) (nnan . 2) (ninf . 4) (nsz . 8)
      (arcp . 16) (contract . 32) (afn . 64) (fast . 127)))

  ;; LLVMGEPNoWrapFlags bits; inbounds implies nusw, as in the IR parser
  (define gep-flag-bits
    '((inbounds . 3) (nusw . 2) (nuw . 4)))

  (define wrap-flag-ops '(add sub mul shl trunc))
  (define exact-flag-ops '(udiv sdiv lshr ashr))

  (define flag-symbols
    '(nsw nuw exact disjoint nneg volatile atomic weak inbounds nusw
       tail musttail notail
       reassoc nnan ninf nsz arcp contract afn fast))

  ;; split leading flag symbols from the rest of an instruction's arguments
  (define (span-flags rest)
    (let loop ([r rest] [flags '()])
      (if (and (pair? r) (symbol? (car r)) (memq (car r) flag-symbols))
          (loop (cdr r) (cons (car r) flags))
          (values (reverse flags) r))))

  (define (require-flag-op op ops flag form)
    (unless (memq op ops)
      (ll-error "flag is not valid for this opcode" flag form)))

  (define (apply-flags! op v flags form)
    (let ([fmf (fold-left
                 (lambda (mask flag)
                   (case flag
                     [(nsw) (require-flag-op op wrap-flag-ops flag form)
                      (ir:set-nsw! v) mask]
                     [(nuw) (require-flag-op op wrap-flag-ops flag form)
                      (ir:set-nuw! v) mask]
                     [(exact) (require-flag-op op exact-flag-ops flag form)
                      (ir:set-exact! v) mask]
                     [(disjoint) (require-flag-op op '(or) flag form)
                      (ir:set-disjoint! v) mask]
                     [(nneg) (require-flag-op op '(zext uitofp) flag form)
                      (ir:set-nneg! v) mask]
                     [(volatile)
                      (require-flag-op op '(load store atomicrmw cmpxchg) flag form)
                      (ir:set-volatile! v) mask]
                     [(atomic) ; ordering applied by the load/store handler
                      (require-flag-op op '(load store) flag form) mask]
                     [(weak) (require-flag-op op '(cmpxchg) flag form)
                      (ir:set-weak! v) mask]
                     [(tail) (require-flag-op op '(call) flag form)
                      (ir:set-tail-call-kind! v 1) mask]
                     [(musttail) (require-flag-op op '(call) flag form)
                      (ir:set-tail-call-kind! v 2) mask]
                     [(notail) (require-flag-op op '(call) flag form)
                      (ir:set-tail-call-kind! v 3) mask]
                     [(inbounds nusw)
                      (ll-error "flag is only valid on getelementptr" flag form)]
                     [else (bitwise-ior mask (cdr (assq flag fmf-bits)))]))
                 0 flags)])
      (unless (zero? fmf)
        (unless (ir:can-use-fast-math-flags? v)
          (ll-error "fast-math flags are not valid on this instruction" op form))
        (ir:set-fast-math-flags! v fmf))))

  (define (gep-flags-mask flags form)
    (fold-left (lambda (mask flag)
                 (cond
                   [(assq flag gep-flag-bits) =>
                    (lambda (p) (bitwise-ior mask (cdr p)))]
                   [else (ll-error "flag is not valid on getelementptr" flag form)]))
               0 flags))

  ;; atomic load/store: the `atomic` flag and a trailing ordering symbol
  ;; must come together
  (define (set-atomic-ordering! v flags ord form)
    (cond
      [(and (memq 'atomic flags) ord) (ir:set-ordering! v ord)]
      [(memq 'atomic flags)
       (ll-error "atomic load/store requires an ordering" form)]
      [ord (ll-error "an ordering requires the atomic flag" form)]))

  ;; apply post-hoc flags; getelementptr consumed its flags at construction
  (define (finish-op! op flags form v)
    (unless (or (null? flags) (eq? op 'getelementptr))
      (apply-flags! op v flags form))
    v)

  ;; instructions with no bindable result
  (define no-result-ops
    '(store br ret switch indirectbr unreachable fence
       resume catchret cleanupret))

  ;; instructions that may (and must) end a block; invoke and catchswitch
  ;; are terminators that also bind a result via =
  (define terminator-ops
    '(ret br switch indirectbr unreachable
       invoke resume catchswitch catchret cleanupret callbr))

  (define (terminator-form? f)
    (and (pair? f)
         (or (memq (car f) terminator-ops)
             (and (eq? (car f) '=) (= (length f) 3) (pair? (caddr f))
                  (memq (car (caddr f)) terminator-ops)))))

  ;; trailing attribute groups, e.g. (align 8)
  (define (apply-attrs! v attrs form)
    (for-each
      (lambda (a)
        (if (and (pair? a) (eq? (car a) 'align)
                 (pair? (cdr a)) (null? (cddr a))
                 (fixnum? (cadr a)) (positive? (cadr a)))
            (ir:set-alignment! v (cadr a))
            (ll-error "unknown attribute" a form)))
      attrs))

  ;; ---- instruction emission ------------------------------------------------------------

  (define (emit-op st form name)
    (let-values ([(flags args) (span-flags (cdr form))])
      (let ([op (car form)]
            [b (fstate-builder st)] [ctx (fstate-ctx st)])
        (define (arity n shape)
          (unless (= (length args) n)
            (ll-error (string-append "expected " shape) form (fstate-fname st))))
        (define (arity>= n shape)
          (unless (>= (length args) n)
            (ll-error (string-append "expected " shape) form (fstate-fname st))))
        (finish-op! op flags form
          (cond
            [(assq op binops) =>
             (lambda (entry)
               (arity 3 "(op type a b)")
               (let ([ty (resolve-type ctx (car args))])
                 ((cdr entry) b
                  (resolve-operand st ty (cadr args))
                  (resolve-operand st ty (caddr args))
                  name)))]
            [(assq op casts) =>
             (lambda (entry)
               (arity 3 "(op src-type value dest-type)")
               (let ([ty (resolve-type ctx (car args))]
                     [dst (resolve-type ctx (caddr args))])
                 ((cdr entry) b (resolve-operand st ty (cadr args)) dst name)))]
            [else
             (case op
               [(icmp fcmp)
                (arity 4 "(icmp/fcmp pred type a b)")
                (let* ([pred (car args)]
                       [ty (resolve-type ctx (cadr args))]
                       [x (resolve-operand st ty (caddr args))]
                       [y (resolve-operand st ty (cadddr args))])
                  (if (eq? op 'icmp)
                    (ir:build-icmp b pred x y name)
                    (ir:build-fcmp b pred x y name)))]
               [(select)
                (arity 3 "(select (i1 c) (type a) (type b))")
                (ir:build-select b
                                 (resolve-operand st #f (car args))
                                 (resolve-operand st #f (cadr args))
                                 (resolve-operand st #f (caddr args))
                                 name)]
               [(fneg)
                (arity 2 "(fneg type value)")
                (ir:build-fneg b
                               (resolve-operand st (resolve-type ctx (car args)) (cadr args))
                               name)]
               [(phi)
                (arity>= 1 "(phi type (value %label) ...)")   ; zero-incoming phis are legal parse-level IR
                ;; emit empty; incoming resolves at end of function, when
                ;; every value and label is bound (IR's only forward value ref)
                (let ([ph (ir:build-phi b (resolve-type ctx (car args)) name)])
                  (fstate-phis-set! st (cons (list ph (car args) (cdr args) form)
                                         (fstate-phis st)))
                  ph)]
               [(call)
                ;; (call type (callee (type arg) ...) (bundle "tag" ...) ...)
                (arity>= 2 "(call type (callee (type arg) ...) bundles...)")
                (let ([app (cadr args)])
                  (unless (pair? app)
                    (ll-error "call expects an application group (callee args...)"
                              form))
                  (let-values ([(fnty retty avals)
                                (callsite-signature st ctx (car args)
                                                    (cdr app) form)])
                    (when (and (eq? (ir:type-kind retty) 'void)
                            (not (string=? name "")))
                      (ll-error "cannot bind the result of a void call" form))
                    (if (null? (cddr args))
                        (ir:build-call b fnty
                                       (resolve-callee st fnty (car app))
                                       avals name)
                        (let ([brefs (map (lambda (bf) (resolve-bundle st bf))
                                          (cddr args))])
                          (let ([v (ir:build-call-bundles
                                     b fnty (resolve-callee st fnty (car app))
                                     avals brefs name)])
                            (for-each ir:dispose-operand-bundle! brefs)
                            v)))))]
               [(invoke)
                ;; (invoke type (callee args...) bundles... (label %ok) (label %pad))
                (arity>= 4 "(invoke type (callee args...) bundles... (label %ok) (label %pad))")
                (let* ([app (cadr args)]
                       [bundles (filter bundle-form? (cddr args))]
                       [labels (filter (lambda (x) (not (bundle-form? x)))
                                       (cddr args))])
                  (unless (pair? app)
                    (ll-error "invoke expects an application group (callee args...)"
                              form))
                  (unless (= (length labels) 2)
                    (ll-error "invoke expects (label %ok) (label %pad)" form))
                  (let-values ([(fnty retty avals)
                                (callsite-signature st ctx (car args)
                                                    (cdr app) form)])
                    (when (and (eq? (ir:type-kind retty) 'void)
                            (not (string=? name "")))
                      (ll-error "cannot bind the result of a void invoke" form))
                    (if (null? bundles)
                        (ir:build-invoke b fnty
                                         (resolve-callee st fnty (car app))
                                         avals
                                         (block-ref st (car labels))
                                         (block-ref st (cadr labels))
                                         name)
                        (let ([brefs (map (lambda (bf) (resolve-bundle st bf))
                                          bundles)])
                          (let ([v (ir:build-invoke-bundles
                                     b fnty (resolve-callee st fnty (car app))
                                     avals
                                     (block-ref st (car labels))
                                     (block-ref st (cadr labels))
                                     brefs name)])
                            (for-each ir:dispose-operand-bundle! brefs)
                            v)))))]
               [(callbr)
                ;; (callbr type ((asm ...) args...)
                ;;         (label %fallthrough) ((label %indirect) ...))
                (arity 4 "(callbr type ((asm ...) args...) (label %fall) ((label %i) ...))")
                (let ([app (cadr args)])
                  (unless (and (pair? app) (pair? (car app))
                               (eq? (caar app) 'asm))
                    (ll-error "callbr requires an inline-asm callee (LLVM restriction)"
                              form))
                  (unless (list? (cadddr args))
                    (ll-error "callbr expects a list of indirect (label %x) targets"
                              form))
                  (let-values ([(fnty retty avals)
                                (callsite-signature st ctx (car args)
                                                    (cdr app) form)])
                    (ir:build-callbr b fnty
                                     (resolve-callee st fnty (car app))
                                     (block-ref st (caddr args))
                                     (map (lambda (d) (block-ref st d))
                                          (cadddr args))
                                     avals name)))]
               [(landingpad)
                ;; (landingpad type clause ...) where clause is: cleanup |
                ;; (catch type constant) | (filter type constant)
                (arity>= 1 "(landingpad type cleanup|(catch ty c)|(filter ty c) ...)")
                (let ([lp (ir:build-landingpad b (resolve-type ctx (car args))
                                               (length (cdr args)) name)])
                  (for-each
                    (lambda (c)
                      (cond
                        [(eq? c 'cleanup) (ir:set-landingpad-cleanup! lp)]
                        [(and (pair? c) (memq (car c) '(catch filter))
                              (= (length c) 3))
                         (ir:add-clause! lp
                           (resolve-constant ctx (fstate-globals st)
                                             (resolve-type ctx (cadr c))
                                             (caddr c)))]
                        [else (ll-error "invalid landingpad clause" c form)]))
                    (cdr args))
                  lp)]
               [(resume)
                (arity 2 "(resume type value)")
                (ir:build-resume b
                  (resolve-operand st (resolve-type ctx (car args)) (cadr args)))]
               [(catchswitch)
                ;; (catchswitch none|%pad ((label %h) ...) caller|(label %x))
                (arity 3 "(catchswitch parent ((label %h) ...) caller|(label %x))")
                (unless (list? (cadr args))
                  (ll-error "catchswitch expects a list of (label %h) handlers"
                            form))
                (let* ([handlers (cadr args)]
                       [cs (ir:build-catchswitch b
                             (parent-pad st ctx (car args))
                             (unwind-dest st (cddr args) form)
                             (length handlers) name)])
                  (for-each
                    (lambda (h) (ir:add-handler! cs (block-ref st h)))
                    handlers)
                  cs)]
               [(catchpad cleanuppad)
                ;; (catchpad none|%pad ((type arg) ...))
                (arity 2 "(catchpad/cleanuppad parent ((type arg) ...))")
                (unless (list? (cadr args))
                  (ll-error "expected a list of (type arg) pad arguments" form))
                (let ([parent (parent-pad st ctx (car args))]
                      [pargs (map (lambda (g) (resolve-operand st #f g))
                                  (cadr args))])
                  (if (eq? op 'catchpad)
                      (ir:build-catchpad b parent pargs name)
                      (ir:build-cleanuppad b parent pargs name)))]
               [(catchret)
                ;; (catchret %pad (label %next))
                (arity 2 "(catchret %pad (label %next))")
                (ir:build-catchret
                  b (resolve-operand st (ir:token-type ctx) (car args))
                  (block-ref st (cadr args)))]
               [(cleanupret)
                ;; (cleanupret %pad caller|(label %x))
                (arity 2 "(cleanupret %pad caller|(label %x))")
                (ir:build-cleanupret
                  b (resolve-operand st (ir:token-type ctx) (car args))
                  (unwind-dest st (cdr args) form))]
               [(load)
                (arity>= 2 "(load type (ptr p) ...)")
                (let-values ([(ord attrs) (split-ordering (cddr args) form)])
                  (let ([v (ir:build-load b (resolve-type ctx (car args))
                                          (resolve-operand st #f (cadr args))
                                          name)])
                    (set-atomic-ordering! v flags ord form)
                    (apply-attrs! v attrs form)
                    v))]
               [(store)
                (arity>= 2 "(store (type v) (ptr p) ...)")
                (let-values ([(ord attrs) (split-ordering (cddr args) form)])
                  (let ([s (ir:build-store b
                                           (resolve-operand st #f (car args))
                                           (resolve-operand st #f (cadr args)))])
                    (set-atomic-ordering! s flags ord form)
                    (apply-attrs! s attrs form)
                    s))]
               [(alloca)
                ;; (alloca type (count-type count)? (align n)?)
                (arity>= 1 "(alloca type (count-type count)? (align n)?)")
                (let* ([ty (resolve-type ctx (car args))]
                       [rest (cdr args)]
                       [count (and (pair? rest) (pair? (car rest))
                                   (not (eq? (caar rest) 'align))
                                   (car rest))]
                       [attrs (if count (cdr rest) rest)]
                       [v (if count
                              (ir:build-array-alloca
                                b ty (resolve-operand st #f count) name)
                              (ir:build-alloca b ty name))])
                  (apply-attrs! v attrs form)
                  v)]
               [(getelementptr)
                (arity>= 2 "(getelementptr type (ptr p) (type index) ...)")
                (ir:build-gep/flags b (resolve-type ctx (car args))
                                    (resolve-operand st #f (cadr args))
                                    (map (lambda (g) (resolve-operand st #f g)) (cddr args))
                                    (gep-flags-mask flags form)
                                    name)]
               [(freeze)
                (arity 2 "(freeze type value)")
                (ir:build-freeze b
                  (resolve-operand st (resolve-type ctx (car args)) (cadr args))
                  name)]
               [(va_arg)
                (arity 2 "(va_arg (ptr va-list) type)")
                (ir:build-va-arg b (resolve-operand st #f (car args))
                                 (resolve-type ctx (cadr args)) name)]
               [(extractelement)
                (arity 2 "(extractelement (vec-type v) (int-type i))")
                (ir:build-extractelement b
                  (resolve-operand st #f (car args))
                  (resolve-operand st #f (cadr args)) name)]
               [(insertelement)
                (arity 3 "(insertelement (vec-type v) (elt-type e) (int-type i))")
                (ir:build-insertelement b
                  (resolve-operand st #f (car args))
                  (resolve-operand st #f (cadr args))
                  (resolve-operand st #f (caddr args)) name)]
               [(shufflevector)
                (arity 3 "(shufflevector (vec-type a) (vec-type b) (mask i ...))")
                (let ([m (caddr args)])
                  (unless (and (pair? m) (eq? (car m) 'mask) (pair? (cdr m))
                               (for-all (lambda (x)
                                          (or (fixnum? x) (eq? x 'poison)))
                                        (cdr m)))
                    (ll-error "shufflevector mask must be (mask int|poison ...)"
                              m form))
                  (let ([i32 (resolve-type ctx 'i32)])
                    (ir:build-shufflevector b
                      (resolve-operand st #f (car args))
                      (resolve-operand st #f (cadr args))
                      (ir:const-vector
                        (map (lambda (i)
                               (if (eq? i 'poison)
                                   (ir:poison-value i32)
                                   (ir:const-int i32 i)))
                             (cdr m)))
                      name)))]
               [(extractvalue)
                (arity 2 "(extractvalue (agg-type v) index)")
                (unless (fixnum? (cadr args))
                  (ll-error "extractvalue index must be a bare integer" form))
                (ir:build-extractvalue b (resolve-operand st #f (car args))
                                       (cadr args) name)]
               [(insertvalue)
                (arity 3 "(insertvalue (agg-type v) (elt-type e) index)")
                (unless (fixnum? (caddr args))
                  (ll-error "insertvalue index must be a bare integer" form))
                (ir:build-insertvalue b
                  (resolve-operand st #f (car args))
                  (resolve-operand st #f (cadr args))
                  (caddr args) name)]
               [(fence)
                (arity 1 "(fence ordering)")
                (ir:build-fence b (ordering-int (car args) form))]
               [(atomicrmw)
                (arity>= 4 "(atomicrmw op (ptr p) (type v) ordering (align n)?)")
                (let ([rmw (assq (car args) rmw-ops)])
                  (unless rmw
                    (ll-error "unknown atomicrmw operation" (car args) form))
                  (let ([v (ir:build-atomicrmw b (cdr rmw)
                                               (resolve-operand st #f (cadr args))
                                               (resolve-operand st #f (caddr args))
                                               (ordering-int (cadddr args) form)
                                               name)])
                    (apply-attrs! v (cddddr args) form)
                    v))]
               [(cmpxchg)
                (arity>= 5 "(cmpxchg (ptr p) (type cmp) (type new) succ-ord fail-ord (align n)?)")
                (let ([v (ir:build-cmpxchg b
                                           (resolve-operand st #f (car args))
                                           (resolve-operand st #f (cadr args))
                                           (resolve-operand st #f (caddr args))
                                           (ordering-int (cadddr args) form)
                                           (ordering-int (car (cddddr args)) form)
                                           name)])
                  (apply-attrs! v (cdr (cddddr args)) form)
                  v)]
               [(switch)
                (arity>= 3 "(switch type value (label %else) ((type c) (label %l)) ...)")
                (let* ([ty (resolve-type ctx (car args))]
                       [v (resolve-operand st ty (cadr args))]
                       [cases (cdddr args)]
                       [sw (ir:build-switch b v (block-ref st (caddr args))
                                            (length cases))])
                  (for-each
                    (lambda (c)
                      (unless (and (pair? c) (pair? (cdr c)) (null? (cddr c)))
                        (ll-error "switch case must be ((type const) (label %l))"
                                  c form))
                      (ir:add-case! sw (resolve-operand st ty (car c))
                                    (block-ref st (cadr c))))
                    cases)
                  sw)]
               [(indirectbr)
                ;; zero label destinations is legal (unreachable-like)
                (arity>= 1 "(indirectbr (ptr address) (label %l) ...)")
                (let ([ibr (ir:build-indirect-br b
                             (resolve-operand st #f (car args))
                             (length (cdr args)))])
                  (for-each
                    (lambda (d) (ir:add-destination! ibr (block-ref st d)))
                    (cdr args))
                  ibr)]
               [(unreachable)
                (arity 0 "(unreachable)")
                (ir:build-unreachable b)]
               [(br)
                (cond
                  [(= (length args) 1)         ; (br (label %x))
                   (ir:build-br b (block-ref st (car args)))]
                  [(= (length args) 4)         ; (br i1 %c (label %a) (label %b))
                   (let ([c (resolve-operand st (resolve-type ctx (car args))
                                             (cadr args))])
                     (ir:build-cond-br b c
                                       (block-ref st (caddr args))
                                       (block-ref st (cadddr args))))]
                  [else (ll-error "expected (br (label %x)) or (br i1 %c (label %a) (label %b))"
                          form (fstate-fname st))])]
               [(ret)
                (cond
                  [(equal? args '(void)) (ir:build-ret-void b)]
                  [(= (length args) 2)
                   (ir:build-ret b (resolve-operand st (resolve-type ctx (car args))
                                                    (cadr args)))]
                  [else (ll-error "expected (ret void) or (ret type value)"
                          form (fstate-fname st))])]
               [else (ll-error "unknown opcode" op form)])])))))

  (define (emit-insn! st form)
    (cond
      [(not (pair? form))
       (ll-error "invalid instruction" form (fstate-fname st))]
      [(label-form? form)
       (ll-error "blocks do not nest: (label ...) inside a block"
                 form (fstate-fname st))]
      [(eq? (car form) '=)
       (unless (and (= (length form) 3) (local-name? (cadr form))
                    (pair? (caddr form)))
         (ll-error "expected (= %name (op ...))" form (fstate-fname st)))
       (let ([lhs (cadr form)] [rhs (caddr form)])
         (when (memq (car rhs) no-result-ops)
           (ll-error "instruction produces no result to bind" form))
         (when (hashtable-ref (fstate-locals st) lhs #f)
           (ll-error "duplicate local name" lhs (fstate-fname st)))
         (hashtable-set! (fstate-locals st) lhs
                         (emit-op st rhs (llvm-name lhs))))]
      [else (emit-op st form "")]))

  (define (fixup-phis! st)
    (for-each
      (lambda (rec)
        (let ([ph (car rec)]
              [ty (resolve-type (fstate-ctx st) (cadr rec))]
              [pairs (caddr rec)]
              [form (cadddr rec)])
          (ir:phi-add-incoming! ph
            (map (lambda (pr)
                   (unless (and (pair? pr) (pair? (cdr pr)) (null? (cddr pr)))
                     (ll-error "phi incoming must be [value %label]" pr form))
                   (cons (resolve-operand st ty (car pr))
                         (block-by-name st (cadr pr))))
                 pairs))))
      (reverse (fstate-phis st))))

  ;; ---- global variables and constant initializers ---------------------------

  ;; LLVMLinkage; cross-checked against the headers by the coverage tests.
  ;; Keys are the IR keywords.
  (define linkages
    '((external . 0) (available_externally . 1)
      (linkonce . 2) (linkonce_odr . 3)
      (weak . 5) (weak_odr . 6) (appending . 7)
      (internal . 8) (private . 9)
      (extern_weak . 12) (common . 14)))

  ;; initializers: literals, undef/zeroinitializer/null, @globals,
  ;; (c "bytes") / (cz "bytes"), and per-element-typed aggregates
  ;; like ((i64 1) (i32 2)) -- exactly how IR spells them.
  ;; elem-resolve (optional): resolver for aggregate elements -- the
  ;; instruction path passes resolve-operand so elements may be
  ;; blockaddress constants, which need the enclosing function's blocks
  (define (resolve-constant ctx globals ty form . opt)
    (define elem-resolve
      (if (pair? opt)
          (car opt)
          (lambda (ety ef) (resolve-constant ctx globals ety ef))))
    (define (constant-group g)
      (unless (and (pair? g) (pair? (cdr g)) (null? (cddr g)))
        (ll-error "aggregate element must be (type constant)" g form))
      (elem-resolve (resolve-type ctx (car g)) (cadr g)))
    (cond
      [(eq? form 'undef) (ir:undef-value ty)]
      [(eq? form 'poison) (ir:poison-value ty)]
      [(memq form '(zeroinitializer null)) (ir:const-null ty)]
      [(global-name? form)
       (or (hashtable-ref globals form #f)
           (ll-error "unbound global in initializer" form))]
      [(and (integer? form) (exact? form)) (ir:const-int ty form)]
      [(flonum? form) (ir:const-real ty form)]
      [(and (pair? form) (memq (car form) '(c cz)))
       (unless (and (= (length form) 2) (string? (cadr form)))
         (ll-error "expected (c \"bytes\") or (cz \"bytes\")" form))
       (ir:const-string ctx (cadr form) (eq? (car form) 'cz))]
      [(and (pair? form)
            (memq (car form) '(trunc ptrtoint inttoptr bitcast
                                addrspacecast)))
       ;; constexpr cast: (op src-type value dst-type), like instructions
       (unless (= (length form) 4)
         (ll-error "expected (cast-op src-type constant dst-type)" form))
       (ir:const-cast (car form)
                      (elem-resolve (resolve-type ctx (cadr form))
                                    (caddr form))
                      (resolve-type ctx (cadddr form)))]
      [(and (pair? form) (memq (car form) '(add sub mul xor)))
       ;; constexpr binop: (op nuw? nsw? type a b)
       (let loop ([rest (cdr form)] [nuw #f] [nsw #f])
         (cond
           [(and (pair? rest) (eq? (car rest) 'nuw)) (loop (cdr rest) #t nsw)]
           [(and (pair? rest) (eq? (car rest) 'nsw)) (loop (cdr rest) nuw #t)]
           [else
            (unless (= (length rest) 3)
              (ll-error "expected (binop nuw|nsw? type constant constant)"
                        form))
            (when (and (or nuw nsw) (eq? (car form) 'xor))
              (ll-error "xor carries no wrap flags" form))
            (when (and nuw nsw)
              (ll-error "the C API cannot construct nuw+nsw constexprs" form))
            (let ([ety (resolve-type ctx (car rest))])
              (ir:const-binop (car form) nuw nsw
                              (elem-resolve ety (cadr rest))
                              (elem-resolve ety (caddr rest))))]))]
      [(and (pair? form) (eq? (car form) 'getelementptr))
       ;; constexpr gep: (getelementptr flags? src-type (ty ptr) (ty i)...)
       (let loop ([rest (cdr form)] [flags 0])
         (cond
           [(and (pair? rest) (eq? (car rest) 'inbounds))
            (loop (cdr rest) (bitwise-ior flags 3))]   ; inbounds implies nusw
           [(and (pair? rest) (eq? (car rest) 'nusw))
            (loop (cdr rest) (bitwise-ior flags 2))]
           [(and (pair? rest) (eq? (car rest) 'nuw))
            (loop (cdr rest) (bitwise-ior flags 4))]
           [else
            (unless (and (pair? rest) (pair? (cdr rest)))
              (ll-error "expected (getelementptr flags? src-type groups...)"
                        form))
            (let ([groups (map constant-group (cdr rest))])
              (ir:const-gep (resolve-type ctx (car rest))
                            (car groups) (cdr groups) flags))]))]
      [(and (pair? form) (for-all pair? form))
       (let ([elts (map constant-group form)])
         (case (ir:type-kind ty)
           [(array) (ir:const-array (resolve-type ctx (caar form)) elts)]
           [(vector) (ir:const-vector elts)]
           [(struct) (if (ir:struct-name ty)
                         (ir:const-named-struct ty elts)
                         (ir:const-struct ctx elts
                                          (ir:packed-struct-type? ty)))]
           [else (ll-error "aggregate initializer for a non-aggregate type"
                           form)]))]
      [else (ll-error "invalid constant initializer" form)]))

  ;; (= @name (global|constant linkage? type init? attr*)) -- the kind is
  ;; the head, linkage is a modifier after it (like instruction flags);
  ;; no initializer only for external/extern_weak declarations
  (define (parse-global item)
    ;; -> (values name linkage-int-or-#f constant? type-form init-form attrs)
    (unless (and (= (length item) 3) (global-name? (cadr item))
                 (pair? (caddr item)))
      (ll-error "expected (= @name (global|constant ...))" item))
    (let ([name (cadr item)]
          [rhs (caddr item)])
      (unless (and (memq (car rhs) '(global constant)) (pair? (cdr rhs)))
        (ll-error "expected (global ...) or (constant ...)" item))
      (let* ([constant? (eq? (car rhs) 'constant)]
             [as (let ([x (cadr rhs)])
                   (and (pair? x) (eq? (car x) 'addrspace)
                        (= (length x) 2) (fixnum? (cadr x))
                        (cadr x)))]
             [rhs (if as (cdr rhs) rhs)]
             [lk (and (symbol? (cadr rhs)) (assq (cadr rhs) linkages))]
             [rhs (if lk (cdr rhs) rhs)]
             [ty-form (cadr rhs)]
             [rest (cddr rhs)]
             [attr? (lambda (f) (and (pair? f) (eq? (car f) 'align)))]
             [init (and (pair? rest) (not (attr? (car rest))) (car rest))]
             [attrs (if init (cdr rest) rest)])
        (unless (for-all attr? attrs)
          (ll-error "malformed global attributes" attrs item))
        (values name (and lk (cdr lk)) constant? ty-form init attrs as))))

  ;; ---- module items ---------------------------------------------------------------------

  (define (item-kind item)
    (unless (and (pair? item)
                 (memq (car item) '(define declare = type datalayout triple)))
      (ll-error "unknown module item (expected define, declare, type, datalayout, triple or (= @name ...))"
                item))
    (car item))

  ;; (type %name (struct ...)|(packed-struct ...)|opaque) -- named struct
  ;; types; created before anything resolves types, bodies filled second
  ;; so structs may reference each other recursively
  (define (check-type-item item)
    (unless (and (= (length item) 3) (local-name? (cadr item))
                 (or (eq? (caddr item) 'opaque)
                     (and (pair? (caddr item))
                          (memq (car (caddr item)) '(struct packed-struct)))))
      (ll-error "expected (type %name (struct ...)|opaque)" item)))

  (define (create-type-item! ctx item)
    (when (eq? (car item) 'type)
      (check-type-item item)
      (let ([nm (strip-sigil (cadr item))])
        (when (ir:named-type ctx nm)
          (ll-error "duplicate named type" (cadr item)))
        (ir:create-named-struct ctx nm))))

  (define (fill-type-item! ctx item)
    (when (eq? (car item) 'type)
      (let ([body (caddr item)])
        (unless (eq? body 'opaque)
          (ir:struct-set-body!
            (ir:named-type ctx (strip-sigil (cadr item)))
            (map (lambda (e) (resolve-type ctx e)) (cdr body))
            (eq? (car body) 'packed-struct))))))

  ;; (define|declare linkage? ret-type (@name ...) body ...)
  ;; -> (values ret-type-form name-sym rest linkage-int-or-#f body)
  (define (item-signature item)
    (unless (>= (length item) 3)
      (ll-error "malformed module item" item))
    (let* ([lk (and (symbol? (cadr item)) (assq (cadr item) linkages))]
           [item (if lk (cdr item) item)])
      (unless (>= (length item) 3)
        (ll-error "malformed module item" item))
      (let ([sig (caddr item)])
        (unless (and (pair? sig) (global-name? (car sig)))
          (ll-error "function signature must be (@name ...)" item))
        (values (cadr item) (car sig) (cdr sig) (and lk (cdr lk))
                (cdddr item)))))

  (define (check-param p item)
    (unless (and (pair? p) (pair? (cdr p)) (null? (cddr p))
                 (local-name? (cadr p)))
      (ll-error "parameter must be (type %name)" p item)))

  ;; pass 1: create every function and global variable up front, so bodies
  ;; and initializers may reference them in any order
  (define (alias-item? item)
    (and (eq? (item-kind item) '=)
         (pair? (caddr item)) (eq? (car (caddr item)) 'alias)))

  (define (declare-item! ctx m globals item)
    (let ([kind (item-kind item)])
      (if (or (memq kind '(type datalayout triple)) (alias-item? item))
          (void)   ; types have their own passes; aliases come after
        (if (eq? kind '=)
          (let-values ([(name lk constant? ty-form init attrs as)
                        (parse-global item)])
            (when (hashtable-ref globals name #f)
              (ll-error "duplicate global name" name))
            ;; explicit address space always: LLVMAddGlobal would use the
            ;; datalayout's default-globals space (G) instead of 0
            (hashtable-set! globals name
                            (ir:add-global m (resolve-type ctx ty-form)
                                           (llvm-name name) (or as 0))))
          (declare-function! ctx m globals item kind)))))

  (define (declare-function! ctx m globals item kind)
    (let-values ([(retty-form fname rest0 lk body) (item-signature item)])
      (let-values ([(rest variadic?) (split-variadic rest0)])
        (when (hashtable-ref globals fname #f)
          (ll-error "duplicate global name" fname))
        (let* ([retty (resolve-type ctx retty-form)]
               [ptys (case kind
                       [(define)
                        (map (lambda (p)
                               (check-param p item)
                               (resolve-type ctx (car p)))
                             rest)]
                       [(declare) (map (lambda (t) (resolve-type ctx t)) rest)])])
          (let ([f (ir:add-function m (llvm-name fname)
                                    (ir:function-type retty ptys variadic?))])
            (when lk (ir:set-linkage! f lk))
            ;; optional decorations after the signature, in print order:
            ;; (align N) then (gc "name")
            (let deco ([b body])
              (when (and (pair? b) (pair? (car b)))
                (case (car (car b))
                  [(align)
                   (let ([a (car b)])
                     (unless (and (= (length a) 2) (fixnum? (cadr a))
                                  (positive? (cadr a)))
                       (ll-error "expected (align bytes)" a fname))
                     (ir:set-alignment! f (cadr a)))
                   (deco (cdr b))]
                  [(gc)
                   (let ([g (car b)])
                     (unless (and (= (length g) 2) (string? (cadr g)))
                       (ll-error "expected (gc \"name\")" g fname))
                     (ir:set-gc! f (cadr g)))
                   (deco (cdr b))]
                  [else (void)])))
            (hashtable-set! globals fname f))))))

  ;; pass 2: set global initializers/linkage; emit the body of each define
  (define (emit-item! ctx m globals item)
    (when (and (eq? (item-kind item) '=) (not (alias-item? item)))
      (let-values ([(name lk constant? ty-form init attrs as) (parse-global item)])
        (let ([g (hashtable-ref globals name #f)])
          (when lk (ir:set-linkage! g lk))
          (when constant? (ir:set-global-constant! g))
          (if init
              (ir:set-initializer! g
                (resolve-constant ctx globals (resolve-type ctx ty-form) init))
              ;; 0 = external, 12 = extern_weak: declarations
              (unless (memq lk '(0 12))
                (ll-error "a global without an initializer must be external or extern_weak"
                          name)))
          (apply-attrs! g attrs item))))
    (when (eq? (item-kind item) 'define)
      (let-values ([(retty-form fname params lk full-body0) (item-signature item)])
        (let* ([f (hashtable-ref globals fname #f)]
               ;; (align N)/(gc "...") were applied in the declare pass
               [full-body (let skip ([b full-body0])
                            (if (and (pair? b) (pair? (car b))
                                     (memq (caar b) '(align gc)))
                                (skip (cdr b))
                                b))]
               ;; optional (personality type @fn) before the first block,
               ;; as in `define ... personality ptr @pers {`
               [pers? (and (pair? full-body) (pair? (car full-body))
                           (eq? (caar full-body) 'personality))]
               [body (if pers? (cdr full-body) full-body)]
               [builder (ir:make-builder ctx)])
          (when pers?
            (let ([p (car full-body)])
              (unless (= (length p) 3)
                (ll-error "expected (personality type value)" p fname))
              ;; any constant: @fn, null, undef, integers, constexprs
              (ir:set-personality-fn! f
                (resolve-constant ctx globals (resolve-type ctx (cadr p))
                                  (caddr p)))))
          (when (null? body)
            (ll-error "function body is empty" fname))
          (let ([st (make-fstate ctx builder globals (make-eq-hashtable)
                                 (make-eq-hashtable) fname f '() #f
                                 (make-eq-hashtable))])
            ;; bind and name the parameters (skipping a variadic marker)
            (let-values ([(params variadic?) (split-variadic params)])
              (let loop ([ps params] [i 0])
                (unless (null? ps)
                  (let ([pname (cadr (car ps))]
                        [pv (ir:function-param f i)])
                    (when (hashtable-ref (fstate-locals st) pname #f)
                      (ll-error "duplicate parameter name" pname fname))
                    (let ([nm (llvm-name pname)])
                      (unless (string=? nm "") (ir:set-value-name! pv nm)))
                    (hashtable-set! (fstate-locals st) pname pv)
                    (loop (cdr ps) (+ i 1)))))
              ;; every body form is a block group; the first is the entry
              ;; block. Create all blocks before emitting, so branches and
              ;; phi incoming may reference blocks defined later.
              (for-each (lambda (g) (check-block-group g fname)) body)
              (for-each (lambda (g) (add-block! st f (cadr g))) body)
              (for-each
                (lambda (g)
                  (ir:position-at-end! builder (block-by-name st (cadr g)))
                  (for-each (lambda (fm) (emit-insn! st fm)) (cddr g)))
                body)
              (fixup-phis! st)
              (fixup-forwards! st)
              (ir:builder-dispose! builder)))))))

  ;; ---- entry points --------------------------------------------------------------------------

  ;; Build an ll program (a list of module items) into a fresh (llvm ir)
  ;; module in the given context.
  ;; (= @a (alias linkage? value-type (ptr aliasee))). Two phases so
  ;; that (a) aliases print in program order (LLVM prints creation
  ;; order) and (b) aliases may reference aliases in any order: create
  ;; each with a null aliasee first, then patch the aliasees.
  (define (alias-parts ctx item)
    (let* ([rhs (caddr item)]
           [rest (cdr rhs)]
           [lk (and (pair? rest) (symbol? (car rest))
                    (assq (car rest) linkages))]
           [rest (if lk (cdr rest) rest)])
      (unless (and (= (length rest) 2) (pair? (cadr rest))
                   (= (length (cadr rest)) 2))
        (ll-error "expected (= @name (alias linkage? type (ptr aliasee)))"
                  item))
      (values (cadr item) lk (car rest) (cadr rest))))

  (define (create-alias! ctx m globals item)
    (when (alias-item? item)
      (let-values ([(name lk vty-form g) (alias-parts ctx item)])
        (when (hashtable-ref globals name #f)
          (ll-error "duplicate global name" name))
        (let ([a (ir:add-alias m (resolve-type ctx vty-form)
                               (ir:const-null (ir:pointer-type ctx))
                               (llvm-name name))])
          (when lk (ir:set-linkage! a (cdr lk)))
          (hashtable-set! globals name a)))))

  (define (patch-alias! ctx m globals item)
    (when (alias-item? item)
      (let-values ([(name lk vty-form g) (alias-parts ctx item)])
        (ir:alias-set-aliasee!
          (hashtable-ref globals name #f)
          (resolve-constant ctx globals (resolve-type ctx (car g))
                            (cadr g))))))

  (define (build ctx name prog)
    (let ([m (ir:make-module ctx name)]
          [globals (make-eq-hashtable)])
      ;; target strings first: datalayout drives default alignments the
      ;; builder bakes into instructions (e.g. alloca)
      (for-each
        (lambda (item)
          (when (pair? item)
            (case (car item)
              [(datalayout) (ir:set-data-layout! m (cadr item))]
              [(triple) (ir:set-target! m (cadr item))])))
        prog)
      (for-each (lambda (item) (create-type-item! ctx item)) prog)
      (for-each (lambda (item) (fill-type-item! ctx item)) prog)
      (for-each (lambda (item) (declare-item! ctx m globals item)) prog)
      (for-each (lambda (item) (create-alias! ctx m globals item)) prog)
      (for-each (lambda (item) (patch-alias! ctx m globals item)) prog)
      (for-each (lambda (item) (emit-item! ctx m globals item)) prog)
      m))

  ;; Build, verify and JIT a program; returns the jit record, ready for
  ;; (jit:function j "name").
  (define (jit prog)
    (let* ([jc (jit:make-context)]
           [m (build (jit:context-ir jc) "ll" prog)]
           [j (jit:make)])
      (ir:verify-module m)
      (jit:add-module! j jc m)
      (jit:context-dispose! jc)
      j))

  ;; Build a program and return its textual LLVM IR (for humans).
  (define (dump prog)
    (let* ([ctx (ir:make-context)]
           [m (build ctx "ll" prog)]
           [s (ir:module->string m)])
      (ir:module-dispose! m)
      (ir:context-dispose! ctx)
      s)))
