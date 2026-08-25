;;; (sll) -- LLVM IR as s-expressions: the first SchemeLL layer.
;;; Grammar and rationale: project/sll-design.md. Import as:
;;;   (prefix (sll) sll:)
;;;
;;; An sll program is plain data -- a list of module items:
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
(library (sll)
  (export build jit dump unbuild procedure load-sll stackmap-keeper
          object assembly)
  (import (except (chezscheme) error)
          (prefix (llvm base) base:)
          (prefix (llvm ir) ir:)
          (prefix (llvm jit) jit:)
          (prefix (llvm target) target:)
          (prefix (sll attributes) attrs:)
          (sll unbuild))

  (define (error msg . irritants)
    (apply base:error 'sll:build msg irritants))

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
  ;; where digits are slot numbers, not names: sll binds them in its own
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
         [(x86_mmx) (ir:x86mmx-type ctx)]
         [(x86_amx) (ir:x86amx-type ctx)]
         [else
          (if (local-name? t)
              ;; %name: a named struct type from a (type %name ...) item
              (or (lookup-type ctx (strip-sigil t))
                  (error "unknown named type" t))
              (let ([bits (int-bits t)])
                (unless bits (error "unknown type" t))
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
          (error "expected (ptr (addrspace N))" t)]
         ;; lengths are uint64 in LLVM ([0 x T] and beyond-fixnum sizes
         ;; are both legal), so exact integers, not fixnums
         [(and (eq? (car t) 'array) (= (length t) 3)
               (exact? (cadr t)) (integer? (cadr t))
               (<= 0 (cadr t)) (< (cadr t) (expt 2 64)))
          (ir:array-type (resolve-type ctx (caddr t)) (cadr t))]
         [(and (eq? (car t) 'vector) (= (length t) 3)
               (fixnum? (cadr t)) (positive? (cadr t)))
          (ir:vector-type (resolve-type ctx (caddr t)) (cadr t))]
         [(eq? (car t) 'target-ext)
          ;; (target-ext "name" TYPE-PARAM ... INT-PARAM ...)
          (unless (and (>= (length t) 2) (string? (cadr t)))
            (error "expected (target-ext \"name\" params...)" t))
          (let loop ([ps (cddr t)] [tys '()])
            (if (or (null? ps) (integer? (car ps)))
                (begin
                  (unless (for-all (lambda (x)
                                     (and (integer? x) (exact? x) (>= x 0)))
                                   ps)
                    (error "target-ext int params must trail the type params"
                           t))
                  (ir:target-ext-type ctx (cadr t)
                                      (map (lambda (x) (resolve-type ctx x))
                                           (reverse tys))
                                      ps))
                (loop (cdr ps) (cons (car ps) tys))))]
         [(eq? (car t) 'fn)
          (let-values ([(parts variadic?) (split-variadic (cdr t))])
            (unless (pair? parts)
              (error "expected (fn ret-type arg-type ... variadic?)" t))
            (ir:function-type
              (resolve-type ctx (car parts))
              (map (lambda (a) (resolve-type ctx a)) (cdr parts))
              variadic?))]
         [else (error "invalid type" t)])]
      [else (error "invalid type" t)]))

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
           [(struct packed-struct array vector scalable-vector fn
              target-ext) #t]
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
      (error "expected (md \"string\") or (md (element ...))" form))
    (let ([x (cadr form)])
      (cond
        [(string? x) (ir:md-string ctx x)]
        [(list? x)
         (ir:md-node ctx (map (lambda (e) (resolve-md-ref ctx e)) x))]
        [else
         (error "expected (md \"string\") or (md (element ...))" form)])))

  ;; call-site operand bundles: (bundle "tag" (type arg) ...)
  (define (bundle-form? x) (and (pair? x) (eq? (car x) 'bundle)))
  (define (resolve-bundle st bf)
    (unless (and (bundle-form? bf) (>= (length bf) 2) (string? (cadr bf)))
      (error "expected (bundle \"tag\" (type arg) ...)" bf))
    (ir:create-operand-bundle
      (cadr bf)
      (map (lambda (g)
             (unless (and (pair? g) (= (length g) 2))
               (error "bundle arguments are (type value) groups" g bf))
             (resolve-operand st (resolve-type (fstate-ctx st) (car g))
                              (cadr g)))
           (cddr bf))))

  ;; ty types bare literals; #f when the position carries no type of its own
  ;; (then literals must come as a (type value) group).
  (define (resolve-operand st ty form)
    (cond
      [(eq? form 'undef)
       (unless ty (error "undef needs a type annotation" form))
       (ir:undef-value ty)]
      [(eq? form 'poison)
       (unless ty (error "poison needs a type annotation" form))
       (ir:poison-value ty)]
      [(local-name? form)
       (or (hashtable-ref (fstate-locals st) form #f)
           ;; not defined yet: legal when the defining block only appears
           ;; textually later (dominance is what matters, and LLVM's own
           ;; printer emits such IR) -- create a placeholder to patch at
           ;; end of function. Needs a type; untyped positions cannot
           ;; forward-reference.
           (and ty (forward-placeholder st ty form))
           (error "unbound local in an untyped position (cannot forward-reference)"
                  form (fstate-fname st)))]
      [(global-name? form)
       (or (hashtable-ref (fstate-globals st) form #f)
           (error "unbound global" form (fstate-fname st)))]
      [(and (pair? form) (eq? (car form) 'blockaddress))
       ;; (blockaddress @function %label) -- a ptr constant
       (unless (and (= (length form) 3) (global-name? (cadr form))
                    (local-name? (caddr form)))
         (error "expected (blockaddress @function %label)" form))
       (let* ([fname (cadr form)]
              [fn (or (hashtable-ref (fstate-globals st) fname #f)
                      (error "unbound function in blockaddress" form))]
              [tbl (if (eq? fname (fstate-fname st))
                       (fstate-blocks st)
                       (or (and (function-blocks)
                                (hashtable-ref (function-blocks) fname #f))
                           (error "blockaddress target is not a define"
                                  form)))]
              [bb (or (hashtable-ref tbl (caddr form) #f)
                      (error "unknown label in blockaddress" form))])
         (ir:block-address fn bb))]
      [(memq form '(null zeroinitializer none))
       (unless ty (error "null/zeroinitializer/none needs a type annotation"
                         form))
       (ir:const-null ty)]
      [(and (integer? form) (exact? form))
       (unless ty (error "integer literal needs a type annotation" form))
       (ir:const-int ty form)]
      [(flonum? form)
       (unless ty (error "float literal needs a type annotation" form))
       (ir:const-real ty form)]
      [(and (pair? form) (memq (car form) '(c cz)))
       (unless ty (error "string constant needs a type annotation" form))
       (resolve-constant (fstate-ctx st) (fstate-globals st) ty form)]
      [(and (pair? form) (eq? (car form) 'md))
       (ir:metadata-value (fstate-ctx st)
                          (resolve-md-ref (fstate-ctx st) form))]
      [(and (pair? form)
            (memq (car form) '(trunc ptrtoint inttoptr bitcast addrspacecast
                                add sub mul xor getelementptr splat
                                extractelement insertelement)))
       ;; a constant expression in operand position; splat is typed by
       ;; its context, the rest are self-typed
       (resolve-constant (fstate-ctx st) (fstate-globals st) ty form
                         (lambda (ety ef) (resolve-operand st ety ef)))]
      [(aggregate-literal? form)
       (unless ty (error "aggregate constant needs a type annotation" form))
       (resolve-constant (fstate-ctx st) (fstate-globals st) ty form
                         (lambda (ety ef) (resolve-operand st ety ef)))]
      [(and (pair? form) (pair? (cdr form)) (null? (cddr form)))
       ;; typed operand group: (type value)
       (resolve-operand st (resolve-type (fstate-ctx st) (car form)) (cadr form))]
      [else (error "invalid operand" form (fstate-fname st))]))

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
                                                        "sll.fwd")])
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
              (error "unbound local" name (fstate-fname st)))
            (ir:replace-all-uses! ph real)
            (ir:erase-instruction! ph)))
        names phs))
    (when (fstate-scratch st)
      (ir:delete-block! (fstate-scratch st))))

  ;; ---- blocks -----------------------------------------------------------------------

  (define (label-form? f) (and (pair? f) (eq? (car f) 'label)))

  (define (block-by-name st name)
    (unless (local-name? name) (error "invalid label name" name))
    (or (hashtable-ref (fstate-blocks st) name #f)
        (error "unknown label" name (fstate-fname st))))

  (define (block-ref st form)   ; a (label %x) branch target
    (unless (and (label-form? form) (pair? (cdr form)) (null? (cddr form))
                 (local-name? (cadr form)))
      (error "expected branch target (label %name)" form (fstate-fname st)))
    (block-by-name st (cadr form)))

  ;; block group: (label %name <insn> ... <terminator>)
  (define (check-block-group g fname)
    (unless (label-form? g)
      (error "instruction outside a block (expected (label %name insn ...))"
             g fname))
    (unless (and (pair? (cdr g)) (local-name? (cadr g)))
      (error "block label must be a %name" g fname))
    (when (null? (cddr g))
      (error "empty block" (cadr g) fname))
    (unless (terminator-form? (car (last-pair g)))
      (error "block does not end in a terminator" (cadr g) fname)))

  ;; fname -> (label -> block) for every define, filled BEFORE any body
  ;; or initializer is emitted, so blockaddress may cross functions
  (define function-blocks (make-parameter #f))

  (define (prepare-blocks! ctx globals item)
    (when (eq? (item-kind item) 'define)
      (let-values ([(retty-form fname params lk ccv full-body)
                    (item-signature item)])
        (let* ([f (hashtable-ref globals fname #f)]
               [body (let skip ([b full-body])
                       (if (and (pair? b) (pair? (car b))
                                (memq (caar b)
                                      '(attributes align gc personality)))
                           (skip (cdr b))
                           b))]
               [tbl (make-eq-hashtable)])
          (for-each (lambda (g) (check-block-group g fname)) body)
          (for-each
            (lambda (g)
              (let ([name (cadr g)])
                (when (hashtable-ref tbl name #f)
                  (error "duplicate label" name fname))
                (hashtable-set! tbl name
                                (ir:append-block ctx f (llvm-name name)))))
            body)
          (hashtable-set! (function-blocks) fname tbl)))))

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
      [else (error "unknown atomic ordering" sym form)]))

  ;; trailing [ordering] before the attribute groups of atomic load/store
  (define (split-ordering rest form)
    (if (and (pair? rest) (symbol? (car rest)))
        (cond
          [(assq (car rest) atomic-orderings) =>
           (lambda (p) (values (cdr p) (cdr rest)))]
          [else (error "unknown ordering or attribute" (car rest) form)])
        (values #f rest)))

  ;; callee of call/invoke/callbr: a function/pointer operand, or inline
  ;; asm: (asm "template" "constraints" flag ...), flags: sideeffect
  ;; alignstack. callbr requires an asm callee (LLVM restriction).
  ;; count an asm constraint string's operands and compare with the
  ;; call-site function type: LLVM SEGFAULTS on a mismatch instead of
  ;; erroring, so this is a safety check, not pedantry. Constraints
  ;; using + or * (tied-by-plus, indirect) have subtler counting and
  ;; are skipped; ~clobbers and !label constraints (callbr) count as
  ;; neither.
  (define (check-asm-arity fnty form)
    (let ([cs (caddr form)])
      ;; + (read-write) and * (indirect) make counting subtler; skip
      (unless (let loop ([i 0])
                (and (< i (string-length cs))
                     (or (memv (string-ref cs i) '(#\+ #\*))
                         (loop (+ i 1)))))
        (let loop ([i 0] [start 0] [outs 0] [ins 0])
          (define (classify from to outs ins)
            (cond
              [(= from to)
               ;; an empty ITEM (doubled or trailing comma) is fatal to
               ;; LLVM; an empty STRING is simply zero items
               (if (zero? (string-length cs))
                   (values outs ins)
                   (error "empty constraint item (doubled or trailing comma?)"
                          cs form))]
              [(char=? (string-ref cs from) #\~) (values outs ins)]
              [(char=? (string-ref cs from) #\!) (values outs ins)]
              [(char=? (string-ref cs from) #\=) (values (+ outs 1) ins)]
              [else (values outs (+ ins 1))]))
          (if (= i (string-length cs))
              (let-values ([(outs ins) (classify start i outs ins)])
                (let* ([retty (ir:type-return-type fnty)]
                       [want-outs (case (ir:type-kind retty)
                                    [(void) 0]
                                    [(struct)
                                     (ir:struct-field-count retty)]
                                    [else 1])]
                       [want-ins (length (ir:type-param-types fnty))])
                  (unless (and (= outs want-outs) (= ins want-ins))
                    (error "asm constraint operand counts do not match the call-site type (LLVM would crash on this)"
                           `(constraints ,cs outputs ,outs inputs ,ins)
                           `(type wants outputs ,want-outs inputs
                                  ,want-ins)
                           form))))
              (if (char=? (string-ref cs i) #\,)
                  (let-values ([(outs ins) (classify start i outs ins)])
                    (loop (+ i 1) (+ i 1) outs ins))
                  (loop (+ i 1) start outs ins)))))))

  (define resolve-callee
    (case-lambda
      [(st fnty form) (resolve-callee* st fnty form 0)]
      [(st fnty form as) (resolve-callee* st fnty form as)]))
  (define (resolve-callee* st fnty form as)
    (if (and (pair? form) (eq? (car form) 'asm))
        (begin
          (unless (and (>= (length form) 3) (string? (cadr form))
                       (string? (caddr form))
                       (for-all (lambda (f)
                                  (memq f '(sideeffect alignstack
                                             inteldialect unwind)))
                                (cdddr form)))
            (error "expected (asm \"template\" \"constraints\" flag ...)" form))
          (check-asm-arity fnty form)
          (ir:inline-asm fnty (cadr form) (caddr form)
                         (and (memq 'sideeffect (cdddr form)) #t)
                         (and (memq 'alignstack (cdddr form)) #t)
                         (and (memq 'inteldialect (cdddr form)) #t)
                         (and (memq 'unwind (cdddr form)) #t)))
        ;; the callee slot is ptr-typed: lets undef/null callees and
        ;; forward references through; a call-site (addrspace n) marker
        ;; types constant callees outside the program space
        (resolve-operand st (ir:pointer-type (fstate-ctx st) as) form)))

  ;; the type slot of call/invoke/callbr holds either the result type (the
  ;; call-site function type is then built from the argument groups) or a
  ;; full (fn ...) type -- required for vararg calls, as in IR's
  ;; `call i32 (ptr, ...) @printf(...)`.
  ;; -> (values fn-type result-type arg-values)
  (define (callsite-signature st ctx ty-form groups form)
    (for-each
      (lambda (g)
        (unless (and (pair? g) (pair? (cdr g)) (null? (cddr g)))
          (error "call argument must be (type value)" g form)))
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
      [else (error "expected unwind destination: caller or (label %x)"
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
    '(nsw nuw exact disjoint nneg volatile atomic weak singlethread
       inbounds nusw tail musttail notail
       reassoc nnan ninf nsz arcp contract afn fast))

  ;; split leading flag symbols from the rest of an instruction's arguments
  (define (span-flags rest)
    (let loop ([r rest] [flags '()])
      (if (and (pair? r) (symbol? (car r)) (memq (car r) flag-symbols))
          (loop (cdr r) (cons (car r) flags))
          (values (reverse flags) r))))

  (define (require-flag-op op ops flag form)
    (unless (memq op ops)
      (error "flag is not valid for this opcode" flag form)))

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
                     [(singlethread)
                      (require-flag-op op '(load store fence atomicrmw cmpxchg)
                                       flag form)
                      (ir:set-atomic-single-thread! v) mask]
                     [(tail) (require-flag-op op '(call) flag form)
                      (ir:set-tail-call-kind! v 1) mask]
                     [(musttail) (require-flag-op op '(call) flag form)
                      (ir:set-tail-call-kind! v 2) mask]
                     [(notail) (require-flag-op op '(call) flag form)
                      (ir:set-tail-call-kind! v 3) mask]
                     [(inbounds nusw)
                      (error "flag is only valid on getelementptr" flag form)]
                     [else (bitwise-ior mask (cdr (assq flag fmf-bits)))]))
                 0 flags)])
      (unless (zero? fmf)
        (unless (ir:can-use-fast-math-flags? v)
          (error "fast-math flags are not valid on this instruction" op form))
        (ir:set-fast-math-flags! v fmf))))

  (define (gep-flags-mask flags form)
    (fold-left (lambda (mask flag)
                 (cond
                   [(assq flag gep-flag-bits) =>
                    (lambda (p) (bitwise-ior mask (cdr p)))]
                   [else (error "flag is not valid on getelementptr" flag form)]))
               0 flags))

  ;; atomic load/store: the `atomic` flag and a trailing ordering symbol
  ;; must come together
  (define (set-atomic-ordering! v flags ord form)
    (cond
      [(and (memq 'atomic flags) ord) (ir:set-ordering! v ord)]
      [(memq 'atomic flags)
       (error "atomic load/store requires an ordering" form)]
      [ord (error "an ordering requires the atomic flag" form)]))

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
        (cond
          [(and (pair? a) (eq? (car a) 'align)
                (pair? (cdr a)) (null? (cddr a))
                (fixnum? (cadr a)) (positive? (cadr a)))
           (ir:set-alignment! v (cadr a))]
          [(and (pair? a) (eq? (car a) 'addrspace)
                (pair? (cdr a)) (null? (cddr a)) (fixnum? (cadr a)))
           ;; the builder places allocas in the datalayout's A space;
           ;; the annotation is declarative -- verify it landed there
           (unless (= (cadr a) (ir:value-address-space v))
             (error "alloca address space must match the datalayout's alloca space"
                    a form))]
          [else (error "unknown attribute" a form)]))
      attrs))

  ;; ---- instruction emission ------------------------------------------------------------

  (define (emit-op st form name)
    (let-values ([(flags args) (span-flags (cdr form))])
      (let ([op (car form)]
            [b (fstate-builder st)] [ctx (fstate-ctx st)])
        (define (arity n shape)
          (unless (= (length args) n)
            (error (string-append "expected " shape) form (fstate-fname st))))
        (define (arity>= n shape)
          (unless (>= (length args) n)
            (error (string-append "expected " shape) form (fstate-fname st))))
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
                ;; (call cconv? (addrspace n)? type (callee args...) bundles...)
                (arity>= 2 "(call type (callee (type arg) ...) bundles...)")
                (let* ([ccv (cc-spec (car args) form)]
                       [args (if ccv (cdr args) args)]
                       [callee-as (and (pair? (car args))
                                       (eq? (caar args) 'addrspace)
                                       (cadr (car args)))]
                       [args (if callee-as (cdr args) args)]
                       [app (cadr args)])
                  (unless (pair? app)
                    (error "call expects an application group (callee args...)"
                           form))
                  (let-values ([(fnty retty avals)
                                (callsite-signature st ctx (car args)
                                                    (cdr app) form)])
                    (when (and (eq? (ir:type-kind retty) 'void)
                            (not (string=? name "")))
                      (error "cannot bind the result of a void call" form))
                    (let* ([callee (resolve-callee st fnty (car app)
                                                   (or callee-as 0))]
                           [v (if (null? (cddr args))
                                  (ir:build-call b fnty callee avals name)
                                  (let ([brefs (map (lambda (bf)
                                                      (resolve-bundle st bf))
                                                    (cddr args))])
                                    (let ([v (ir:build-call-bundles
                                               b fnty callee avals brefs name)])
                                      (for-each ir:dispose-operand-bundle! brefs)
                                      v)))])
                      (when ccv (ir:set-instruction-call-conv! v ccv))
                      v)))]
               [(invoke)
                ;; (invoke cconv? type (callee args...) bundles... (label %ok) (label %pad))
                (arity>= 4 "(invoke type (callee args...) bundles... (label %ok) (label %pad))")
                (let* ([ccv (cc-spec (car args) form)]
                       [args (if ccv (cdr args) args)]
                       [app (cadr args)]
                       [bundles (filter bundle-form? (cddr args))]
                       [labels (filter (lambda (x) (not (bundle-form? x)))
                                       (cddr args))])
                  (unless (pair? app)
                    (error "invoke expects an application group (callee args...)"
                           form))
                  (unless (= (length labels) 2)
                    (error "invoke expects (label %ok) (label %pad)" form))
                  (let-values ([(fnty retty avals)
                                (callsite-signature st ctx (car args)
                                                    (cdr app) form)])
                    (when (and (eq? (ir:type-kind retty) 'void)
                            (not (string=? name "")))
                      (error "cannot bind the result of a void invoke" form))
                    (let ([v (if (null? bundles)
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
                                     v)))])
                      (when ccv (ir:set-instruction-call-conv! v ccv))
                      v)))]
               [(callbr)
                ;; (callbr cconv? type ((asm ...) args...) bundles...
                ;;         (label %fallthrough) ((label %indirect) ...))
                (arity>= 4 "(callbr type ((asm ...) args...) bundles... (label %fall) ((label %i) ...))")
                (let* ([ccv (cc-spec (car args) form)]
                       [args (if ccv (cdr args) args)]
                       [bundles (filter bundle-form? (cddr args))]
                       [args (cons (car args)
                                   (cons (cadr args)
                                         (filter (lambda (x)
                                                   (not (bundle-form? x)))
                                                 (cddr args))))]
                       [app (cadr args)])
                  (unless (and (pair? app) (pair? (car app))
                               (eq? (caar app) 'asm))
                    (error "callbr requires an inline-asm callee (LLVM restriction)"
                           form))
                  (unless (list? (cadddr args))
                    (error "callbr expects a list of indirect (label %x) targets"
                           form))
                  (let-values ([(fnty retty avals)
                                (callsite-signature st ctx (car args)
                                                    (cdr app) form)])
                    (let ([v (if (null? bundles)
                                 (ir:build-callbr b fnty
                                                  (resolve-callee st fnty (car app))
                                                  (block-ref st (caddr args))
                                                  (map (lambda (d) (block-ref st d))
                                                       (cadddr args))
                                                  avals name)
                                 (let ([brefs (map (lambda (bf)
                                                     (resolve-bundle st bf))
                                                   bundles)])
                                   (let ([v (ir:build-callbr
                                              b fnty
                                              (resolve-callee st fnty (car app))
                                              (block-ref st (caddr args))
                                              (map (lambda (d) (block-ref st d))
                                                   (cadddr args))
                                              avals brefs name)])
                                     (for-each ir:dispose-operand-bundle! brefs)
                                     v)))])
                      (when ccv (ir:set-instruction-call-conv! v ccv))
                      v)))]
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
                        [else (error "invalid landingpad clause" c form)]))
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
                  (error "catchswitch expects a list of (label %h) handlers"
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
                  (error "expected a list of (type arg) pad arguments" form))
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
                                   (not (memq (caar rest)
                                              '(align addrspace)))
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
                    (error "shufflevector mask must be (mask int|poison ...)"
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
                  (error "extractvalue index must be a bare integer" form))
                (ir:build-extractvalue b (resolve-operand st #f (car args))
                                       (cadr args) name)]
               [(insertvalue)
                (arity 3 "(insertvalue (agg-type v) (elt-type e) index)")
                (unless (fixnum? (caddr args))
                  (error "insertvalue index must be a bare integer" form))
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
                    (error "unknown atomicrmw operation" (car args) form))
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
                        (error "switch case must be ((type const) (label %l))"
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
                  [else (error "expected (br (label %x)) or (br i1 %c (label %a) (label %b))"
                          form (fstate-fname st))])]
               [(ret)
                (cond
                  [(equal? args '(void)) (ir:build-ret-void b)]
                  [(= (length args) 2)
                   (ir:build-ret b (resolve-operand st (resolve-type ctx (car args))
                                                    (cadr args)))]
                  [else (error "expected (ret void) or (ret type value)"
                          form (fstate-fname st))])]
               [else (error "unknown opcode" op form)])])))))

  (define (emit-insn! st form)
    (cond
      [(not (pair? form))
       (error "invalid instruction" form (fstate-fname st))]
      [(label-form? form)
       (error "blocks do not nest: (label ...) inside a block"
              form (fstate-fname st))]
      [(eq? (car form) '=)
       (unless (and (= (length form) 3) (local-name? (cadr form))
                    (pair? (caddr form)))
         (error "expected (= %name (op ...))" form (fstate-fname st)))
       (let ([lhs (cadr form)] [rhs (caddr form)])
         (when (memq (car rhs) no-result-ops)
           (error "instruction produces no result to bind" form))
         (when (hashtable-ref (fstate-locals st) lhs #f)
           (error "duplicate local name" lhs (fstate-fname st)))
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
                     (error "phi incoming must be [value %label]" pr form))
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

  ;; llvm::CallingConv; keys are the IR keywords, i.e. exactly the
  ;; names LLVM 19's printer uses (probed by setting every id 0..120
  ;; and reading the print). Ids the printer has no name for spell as
  ;; (cc N) -- and named ones MUST use the name, so sll data is
  ;; canonical both directions (same shape as the anonymity rule).
  ;; ccc (0) is the default and is never written.
  (define call-convs
    '((fastcc . 8) (coldcc . 9) (ghccc . 10) (anyregcc . 13)
      (preserve_mostcc . 14) (preserve_allcc . 15) (swiftcc . 16)
      (cxx_fast_tlscc . 17) (tailcc . 18) (cfguard_checkcc . 19)
      (swifttailcc . 20) (preserve_nonecc . 21)
      (x86_stdcallcc . 64) (x86_fastcallcc . 65)
      (arm_apcscc . 66) (arm_aapcscc . 67) (arm_aapcs_vfpcc . 68)
      (msp430_intrcc . 69) (x86_thiscallcc . 70)
      (ptx_kernel . 71) (ptx_device . 72)
      (spir_func . 75) (spir_kernel . 76) (intel_ocl_bicc . 77)
      (x86_64_sysvcc . 78) (win64cc . 79) (x86_vectorcallcc . 80)
      (hhvmcc . 81) (hhvm_ccc . 82) (x86_intrcc . 83)
      (avr_intrcc . 84) (avr_signalcc . 85)
      (amdgpu_vs . 87) (amdgpu_gs . 88) (amdgpu_ps . 89)
      (amdgpu_cs . 90) (amdgpu_kernel . 91) (x86_regcallcc . 92)
      (amdgpu_hs . 93) (amdgpu_ls . 95) (amdgpu_es . 96)
      (aarch64_vector_pcs . 97) (aarch64_sve_vector_pcs . 98)
      (amdgpu_gfx . 100)
      (aarch64_sme_preservemost_from_x0 . 102)
      (aarch64_sme_preservemost_from_x2 . 103)
      (amdgpu_cs_chain . 104) (amdgpu_cs_chain_preserve . 105)
      (m68k_rtdcc . 106) (graalcc . 107) (riscv_vector_cc . 110)
      (aarch64_sme_preservemost_from_x1 . 111)))

  ;; an optional calling-convention spec at the head of a form:
  ;; a named symbol, or (cc N) for ids without a printer name.
  ;; Returns the id or #f (not a cc spec); errors on a malformed one.
  (define (cc-spec x form)
    (cond
      [(and (symbol? x) (assq x call-convs)) => cdr]
      [(and (pair? x) (eq? (car x) 'cc))
       (unless (and (pair? (cdr x)) (null? (cddr x))
                    (fixnum? (cadr x)) (<= 1 (cadr x) 1023))
         (error "expected (cc N) with N in 1..1023" x form))
       (let ([n (cadr x)])
         (cond
           [(find (lambda (p) (= (cdr p) n)) call-convs) =>
            (lambda (p)
              (error "this calling convention has a name; use it"
                     (car p) form))]
           [else n]))]
      [else #f]))

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
        (error "aggregate element must be (type constant)" g form))
      (elem-resolve (resolve-type ctx (car g)) (cadr g)))
    (cond
      [(eq? form 'undef) (ir:undef-value ty)]
      [(eq? form 'poison) (ir:poison-value ty)]
      [(memq form '(zeroinitializer null)) (ir:const-null ty)]
      [(global-name? form)
       (or (hashtable-ref globals form #f)
           (error "unbound global in initializer" form))]
      [(and (integer? form) (exact? form)) (ir:const-int ty form)]
      [(flonum? form) (ir:const-real ty form)]
      [(and (pair? form) (memq (car form) '(c cz)))
       (unless (and (= (length form) 2) (string? (cadr form)))
         (error "expected (c \"bytes\") or (cz \"bytes\")" form))
       (ir:const-string ctx (cadr form) (eq? (car form) 'cz))]
      [(and (pair? form) (eq? (car form) 'blockaddress))
       ;; in initializers: blocks of every define exist before emission
       (let* ([fn (or (hashtable-ref globals (cadr form) #f)
                      (error "unbound function in blockaddress" form))]
              [tbl (or (and (function-blocks)
                            (hashtable-ref (function-blocks) (cadr form) #f))
                       (error "blockaddress target is not a define" form))]
              [bb (or (hashtable-ref tbl (caddr form) #f)
                      (error "unknown label in blockaddress" form))])
         (ir:block-address fn bb))]
      [(and (pair? form)
            (memq (car form) '(trunc ptrtoint inttoptr bitcast
                                addrspacecast)))
       ;; constexpr cast: (op src-type value dst-type), like instructions
       (unless (= (length form) 4)
         (error "expected (cast-op src-type constant dst-type)" form))
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
              (error "expected (binop nuw|nsw? type constant constant)"
                     form))
            (when (and (or nuw nsw) (eq? (car form) 'xor))
              (error "xor carries no wrap flags" form))
            (when (and nuw nsw)
              (error "the C API cannot construct nuw+nsw constexprs" form))
            (let ([ety (resolve-type ctx (car rest))])
              (ir:const-binop (car form) nuw nsw
                              (elem-resolve ety (cadr rest))
                              (elem-resolve ety (caddr rest))))]))]
      [(and (pair? form) (memq (car form) '(extractelement insertelement)))
       ;; element-access constexprs, instruction-shaped groups
       (let ([gs (map constant-group (cdr form))])
         (if (eq? (car form) 'extractelement)
             (begin
               (unless (= (length gs) 2)
                 (error "expected (extractelement (ty v) (ty i))" form))
               (ir:const-extractelement (car gs) (cadr gs)))
             (begin
               (unless (= (length gs) 3)
                 (error "expected (insertelement (ty v) (ty e) (ty i))" form))
               (ir:const-insertelement (car gs) (cadr gs) (caddr gs)))))]
      [(and (pair? form) (eq? (car form) 'splat))
       ;; splat constant: (splat (elem-type elem)); ty is the vector type
       (unless (and ty (= (length form) 2) (pair? (cadr form))
                    (= (length (cadr form)) 2))
         (error "expected (splat (element-type element))" form))
       (ir:const-splat ty (constant-group (cadr form)))]
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
              (error "expected (getelementptr flags? src-type groups...)"
                     form))
            (let ([groups (map constant-group (cdr rest))])
              (ir:const-gep (resolve-type ctx (car rest))
                            (car groups) (cdr groups) flags))]))]
      [(and (pair? form) (for-all pair? form))
       (let ([elts (map constant-group form)])
         (case (ir:type-kind ty)
           [(array) (ir:const-array (resolve-type ctx (caar form)) elts)]
           [(vector) (ir:const-vector elts)]
           ;; identified (named OR anonymous) vs literal struct types --
           ;; the name alone misses anonymous identified structs
           [(struct) (if (ir:literal-struct-type? ty)
                         (ir:const-struct ctx elts
                                          (ir:packed-struct-type? ty))
                         (ir:const-named-struct ty elts))]
           [else (error "aggregate initializer for a non-aggregate type"
                        form)]))]
      [else (error "invalid constant initializer" form)]))

  ;; (= @name (global|constant linkage? type init? attr*)) -- the kind is
  ;; the head, linkage is a modifier after it (like instruction flags);
  ;; no initializer only for external/extern_weak declarations
  (define (parse-global item)
    ;; -> (values name linkage-int-or-#f constant? type-form init-form
    ;;            attrs addrspace-or-#f externally-initialized?)
    (unless (and (= (length item) 3) (global-name? (cadr item))
                 (pair? (caddr item)))
      (error "expected (= @name (global|constant ...))" item))
    (let ([name (cadr item)]
          [rhs (caddr item)])
      (unless (and (memq (car rhs) '(global constant)) (pair? (cdr rhs)))
        (error "expected (global ...) or (constant ...)" item))
      (let* ([constant? (eq? (car rhs) 'constant)]
             [as (let ([x (cadr rhs)])
                   (and (pair? x) (eq? (car x) 'addrspace)
                        (= (length x) 2) (fixnum? (cadr x))
                        (cadr x)))]
             [rhs (if as (cdr rhs) rhs)]
             [lk (and (symbol? (cadr rhs)) (assq (cadr rhs) linkages))]
             [rhs (if lk (cdr rhs) rhs)]
             [ext-init? (eq? (cadr rhs) 'externally_initialized)]
             [rhs (if ext-init? (cdr rhs) rhs)]
             [ty-form (cadr rhs)]
             [rest (cddr rhs)]
             [attr? (lambda (f) (and (pair? f) (eq? (car f) 'align)))]
             [init (and (pair? rest) (not (attr? (car rest))) (car rest))]
             [attrs (if init (cdr rest) rest)])
        (unless (for-all attr? attrs)
          (error "malformed global attributes" attrs item))
        (values name (and lk (cdr lk)) constant? ty-form init attrs as
                ext-init?))))

  ;; ---- module items ---------------------------------------------------------------------

  (define (item-kind item)
    (unless (and (pair? item)
                 (memq (car item)
                       '(define declare = type datalayout triple module-asm)))
      (error "unknown module item (expected define, declare, type, datalayout, triple, module-asm or (= @name ...))"
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
      (error "expected (type %name (struct ...)|opaque)" item)))

  ;; all-digit type names are anonymous (like values): the struct is
  ;; created UNNAMED so the printer numbers it; the binding lives here
  (define anon-types (make-parameter #f))

  (define (lookup-type ctx nm)
    (if (anonymous-name? nm)
        (and (anon-types) (hashtable-ref (anon-types) nm #f))
        (ir:named-type ctx nm)))

  (define (create-type-item! ctx item)
    (when (eq? (car item) 'type)
      (check-type-item item)
      (let ([nm (strip-sigil (cadr item))])
        (when (lookup-type ctx nm)
          (error "duplicate named type" (cadr item)))
        (if (anonymous-name? nm)
            (hashtable-set! (anon-types) nm
                            (ir:create-named-struct ctx ""))
            (ir:create-named-struct ctx nm)))))

  (define (fill-type-item! ctx item)
    (when (eq? (car item) 'type)
      (let ([body (caddr item)])
        (unless (eq? body 'opaque)
          (ir:struct-set-body!
            (lookup-type ctx (strip-sigil (cadr item)))
            (map (lambda (e) (resolve-type ctx e)) (cdr body))
            (eq? (car body) 'packed-struct))))))

  ;; (define|declare linkage? cconv? ret-type (@name ...) body ...)
  ;; -> (values ret-type-form name-sym rest linkage-int-or-#f
  ;;            cc-int-or-#f body)
  (define (item-signature item)
    (unless (>= (length item) 3)
      (error "malformed module item" item))
    (let* ([lk (and (symbol? (cadr item)) (assq (cadr item) linkages))]
           [item (if lk (cdr item) item)]
           [ccv (and (>= (length item) 3) (cc-spec (cadr item) item))]
           [item (if ccv (cdr item) item)])
      (unless (>= (length item) 3)
        (error "malformed module item" item))
      (let ([sig (caddr item)])
        (unless (and (pair? sig) (global-name? (car sig)))
          (error "function signature must be (@name ...)" item))
        (values (cadr item) (car sig) (cdr sig) (and lk (cdr lk)) ccv
                (cdddr item)))))

  (define (check-param p item)
    (unless (and (pair? p) (pair? (cdr p)) (null? (cddr p))
                 (local-name? (cadr p)))
      (error "parameter must be (type %name)" p item)))

  ;; pass 1: create every function and global variable up front, so bodies
  ;; and initializers may reference them in any order
  (define (alias-item? item)
    (and (eq? (item-kind item) '=)
         (pair? (caddr item)) (eq? (car (caddr item)) 'alias)))

  (define (ifunc-item? item)
    (and (eq? (item-kind item) '=)
         (pair? (caddr item)) (eq? (car (caddr item)) 'ifunc)))

  (define (declare-item! ctx m globals item)
    (let ([kind (item-kind item)])
      (if (or (memq kind '(type datalayout triple module-asm))
              (alias-item? item) (ifunc-item? item))
          (void)   ; types have their own passes; aliases come after
        (if (eq? kind '=)
          (let-values ([(name lk constant? ty-form init attrs as ext-init?)
                        (parse-global item)])
            (when (hashtable-ref globals name #f)
              (error "duplicate global name" name))
            ;; explicit address space always: LLVMAddGlobal would use the
            ;; datalayout's default-globals space (G) instead of 0
            (hashtable-set! globals name
                            (ir:add-global m (resolve-type ctx ty-form)
                                           (llvm-name name) (or as 0))))
          (declare-function! ctx m globals item kind)))))

  ;; an (attributes ...) element: a bare symbol is a valueless enum
  ;; attribute (the names LLVM's own kind lookup accepts, via
  ;; (sll attributes)); ("key") and ("key" "value") are string
  ;; attributes. Valued enums and type attributes are not modeled.
  (define (resolve-attribute ctx spec form fname)
    (cond
      [(symbol? spec)
       (let ([kind (attrs:enum-name->kind spec)])
         (unless kind
           (error "unknown enum attribute (valued and type attributes are not modeled)"
                  spec form fname))
         (ir:create-enum-attribute ctx kind 0))]
      [(and (pair? spec) (string? (car spec)) (null? (cdr spec)))
       (ir:create-string-attribute ctx (car spec) "")]
      [(and (pair? spec) (string? (car spec)) (pair? (cdr spec))
            (string? (cadr spec)) (null? (cddr spec)))
       (ir:create-string-attribute ctx (car spec) (cadr spec))]
      [else
       (error "attribute must be a symbol, (\"key\") or (\"key\" \"value\")"
              spec form fname)]))

  (define (declare-function! ctx m globals item kind)
    (let-values ([(retty-form fname rest0 lk ccv body) (item-signature item)])
      (let-values ([(rest variadic?) (split-variadic rest0)])
        (when (hashtable-ref globals fname #f)
          (error "duplicate global name" fname))
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
            (when ccv (ir:set-function-call-conv! f ccv))
            ;; optional decorations after the signature, in print order:
            ;; (attributes ...) then (align N) then (gc "name")
            (let deco ([b body])
              (when (and (pair? b) (pair? (car b)))
                (case (car (car b))
                  [(attributes)
                   (for-each
                     (lambda (spec)
                       (ir:add-function-attribute!
                         f (resolve-attribute ctx spec (car b) fname)))
                     (cdr (car b)))
                   (deco (cdr b))]
                  [(align)
                   (let ([a (car b)])
                     (unless (and (= (length a) 2) (fixnum? (cadr a))
                                  (positive? (cadr a)))
                       (error "expected (align bytes)" a fname))
                     (ir:set-alignment! f (cadr a)))
                   (deco (cdr b))]
                  [(gc)
                   (let ([g (car b)])
                     (unless (and (= (length g) 2) (string? (cadr g)))
                       (error "expected (gc \"name\")" g fname))
                     (ir:set-gc! f (cadr g)))
                   (deco (cdr b))]
                  [else (void)])))
            (hashtable-set! globals fname f))))))

  ;; pass 2: set global initializers/linkage; emit the body of each define
  (define (emit-item! ctx m globals item)
    (when (and (eq? (item-kind item) '=)
               (not (alias-item? item)) (not (ifunc-item? item)))
      (let-values ([(name lk constant? ty-form init attrs as ext-init?)
                    (parse-global item)])
        (let ([g (hashtable-ref globals name #f)])
          (when lk (ir:set-linkage! g lk))
          (when ext-init? (ir:set-externally-initialized! g))
          (when constant? (ir:set-global-constant! g))
          (if init
              (ir:set-initializer! g
                (resolve-constant ctx globals (resolve-type ctx ty-form) init))
              ;; 0 = external, 12 = extern_weak: declarations
              (unless (memq lk '(0 12))
                (error "a global without an initializer must be external or extern_weak"
                       name)))
          (apply-attrs! g attrs item))))
    (when (eq? (item-kind item) 'define)
      (let-values ([(retty-form fname params lk ccv full-body0)
                    (item-signature item)])
        (let* ([f (hashtable-ref globals fname #f)]
               ;; (attributes ...)/(align N)/(gc "...") were applied in
               ;; the declare pass
               [full-body (let skip ([b full-body0])
                            (if (and (pair? b) (pair? (car b))
                                     (memq (caar b) '(attributes align gc)))
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
                (error "expected (personality type value)" p fname))
              ;; any constant: @fn, null, undef, integers, constexprs
              (ir:set-personality-fn! f
                (resolve-constant ctx globals (resolve-type ctx (cadr p))
                                  (caddr p)))))
          (when (null? body)
            (error "function body is empty" fname))
          (let ([st (make-fstate ctx builder globals (make-eq-hashtable)
                                 (hashtable-ref (function-blocks) fname #f)
                                 fname f '() #f
                                 (make-eq-hashtable))])
            ;; bind and name the parameters (skipping a variadic marker)
            (let-values ([(params variadic?) (split-variadic params)])
              (let loop ([ps params] [i 0])
                (unless (null? ps)
                  (let ([pname (cadr (car ps))]
                        [pv (ir:function-param f i)])
                    (when (hashtable-ref (fstate-locals st) pname #f)
                      (error "duplicate parameter name" pname fname))
                    (let ([nm (llvm-name pname)])
                      (unless (string=? nm "") (ir:set-value-name! pv nm)))
                    (hashtable-set! (fstate-locals st) pname pv)
                    (loop (cdr ps) (+ i 1)))))
              ;; blocks were created in the prepare pass (so blockaddress
              ;; may reference them across functions); emit into them
              (for-each
                (lambda (g)
                  (ir:position-at-end! builder (block-by-name st (cadr g)))
                  (for-each (lambda (fm) (emit-insn! st fm)) (cddr g)))
                body)
              (fixup-phis! st)
              (fixup-forwards! st)
              (ir:builder-dispose! builder)))))))

  ;; ---- entry points --------------------------------------------------------------------------

  ;; Build an sll program (a list of module items) into a fresh (llvm ir)
  ;; module in the given context.
  ;; (= @a (alias linkage? value-type (ptr aliasee))). Two phases so
  ;; that (a) aliases print in program order (LLVM prints creation
  ;; order) and (b) aliases may reference aliases in any order: create
  ;; each with a null aliasee first, then patch the aliasees.
  (define (alias-parts ctx item)
    (let* ([rhs (caddr item)]
           [rest (cdr rhs)]
           [as (let ([x (car rest)])
                 (and (pair? x) (eq? (car x) 'addrspace) (cadr x)))]
           [rest (if as (cdr rest) rest)]
           [lk (and (pair? rest) (symbol? (car rest))
                    (assq (car rest) linkages))]
           [rest (if lk (cdr rest) rest)])
      (unless (and (= (length rest) 2) (pair? (cadr rest))
                   (= (length (cadr rest)) 2))
        (error "expected (= @name (alias (addrspace n)? linkage? type (ptr aliasee)))"
               item))
      (values (cadr item) as lk (car rest) (cadr rest))))

  ;; (= @i (ifunc linkage? fn-type (ptr @resolver))) -- same two-phase
  ;; scheme as aliases (creation order = print order)
  (define (ifunc-parts ctx item)
    (let* ([rest (cdr (caddr item))]
           [lk (and (pair? rest) (symbol? (car rest))
                    (assq (car rest) linkages))]
           [rest (if lk (cdr rest) rest)])
      (unless (and (= (length rest) 2) (pair? (cadr rest))
                   (= (length (cadr rest)) 2))
        (error "expected (= @name (ifunc linkage? fn-type (ptr resolver)))"
               item))
      (values (cadr item) lk (car rest) (cadr rest))))

  (define (create-ifunc! ctx m globals item)
    (when (ifunc-item? item)
      (let-values ([(name lk fnty-form g) (ifunc-parts ctx item)])
        (when (hashtable-ref globals name #f)
          (error "duplicate global name" name))
        (let ([i (ir:add-ifunc m (llvm-name name)
                               (resolve-type ctx fnty-form)
                               (ir:const-null (ir:pointer-type ctx)))])
          (when lk (ir:set-linkage! i (cdr lk)))
          (hashtable-set! globals name i)))))

  (define (patch-ifunc! ctx m globals item)
    (when (ifunc-item? item)
      (let-values ([(name lk fnty-form g) (ifunc-parts ctx item)])
        (ir:ifunc-set-resolver!
          (hashtable-ref globals name #f)
          (resolve-constant ctx globals (resolve-type ctx (car g))
                            (cadr g))))))

  (define (create-alias! ctx m globals item)
    (when (alias-item? item)
      (let-values ([(name as lk vty-form g) (alias-parts ctx item)])
        (when (hashtable-ref globals name #f)
          (error "duplicate global name" name))
        (let ([a (ir:add-alias m (resolve-type ctx vty-form)
                               (ir:const-null
                                 (ir:pointer-type ctx (or as 0)))
                               (llvm-name name) (or as 0))])
          (when lk (ir:set-linkage! a (cdr lk)))
          (hashtable-set! globals name a)))))

  (define (patch-alias! ctx m globals item)
    (when (alias-item? item)
      (let-values ([(name as lk vty-form g) (alias-parts ctx item)])
        (ir:alias-set-aliasee!
          (hashtable-ref globals name #f)
          (resolve-constant ctx globals (resolve-type ctx (car g))
                            (cadr g))))))

  (define (build ctx name prog)
    (let ([m (ir:make-module ctx name)]
          [globals (make-eq-hashtable)])
      (anon-types (make-hashtable string-hash string=?))
      ;; target strings first: datalayout drives default alignments the
      ;; builder bakes into instructions (e.g. alloca)
      (for-each
        (lambda (item)
          (when (pair? item)
            (case (car item)
              [(datalayout) (ir:set-data-layout! m (cadr item))]
              [(triple) (ir:set-target! m (cadr item))]
              [(module-asm) (ir:set-module-asm! m (cadr item))])))
        prog)
      (for-each (lambda (item) (create-type-item! ctx item)) prog)
      (for-each (lambda (item) (fill-type-item! ctx item)) prog)
      (for-each (lambda (item) (declare-item! ctx m globals item)) prog)
      (for-each (lambda (item) (create-alias! ctx m globals item)) prog)
      (for-each (lambda (item) (create-ifunc! ctx m globals item)) prog)
      (parameterize ([function-blocks (make-eq-hashtable)])
        (for-each (lambda (item) (prepare-blocks! ctx globals item)) prog)
        (for-each (lambda (item) (patch-alias! ctx m globals item)) prog)
        (for-each (lambda (item) (patch-ifunc! ctx m globals item)) prog)
        (for-each (lambda (item) (emit-item! ctx m globals item)) prog))
      m))

  ;; Build, verify and JIT a program; returns the jit record, ready for
  ;; (jit:function j "name").
  (define (jit prog)
    (let* ([jc (jit:make-context)]
           [m (build (jit:context-ir jc) "sll" prog)]
           [j (jit:make)])
      (ir:verify-module m)
      (jit:add-module! j jc m)
      (jit:context-dispose! jc)
      j))

  ;; Read a .sll file: sll module items with embedded Scheme. The file
  ;; is the INVERSE of a Scheme source: its top level is data, and code
  ;; is escaped INTO it --
  ;;   ,expr and ,@expr   quasiquote escapes, anywhere in any item
  ;;                      (including a whole item or item splice)
  ;;   (scheme expr ...)  top-level: evaluated for effect (defines,
  ;;                      imports) in the file's environment before the
  ;;                      items are; contributes no items
  ;; Everything else is literal sll; escapes evaluate in strict
  ;; top-to-bottom file order. Plain data files load unchanged.
  ;; NOTE: like a Makefile, a .sll with escapes is a program -- load
  ;; only what you trust. (Named load-sll: Chez has an unrelated
  ;; built-in load-program that an unprefixed double import would
  ;; silently shadow this with.)
  (define (load-sll path)
    (let ([env (copy-environment (environment '(chezscheme)) #t)])
      (call-with-input-file path
        (lambda (p)
          (let loop ([acc '()])
            (let ([d (read p)])
              (cond
                [(eof-object? d) (reverse acc)]
                [(and (pair? d) (eq? (car d) 'scheme))
                 (for-each (lambda (e) (eval e env)) (cdr d))
                 (loop acc)]
                ;; each item evaluates AS IT IS READ, so stateful
                ;; escapes observe strict top-to-bottom file order
                ;; (one quasiquote over the whole file would leave
                ;; the order of ,expr side effects unspecified)
                [(and (pair? d) (eq? (car d) 'unquote))
                 (loop (cons (eval (cadr d) env) acc))]
                [(and (pair? d) (eq? (car d) 'unquote-splicing))
                 (loop (append (reverse (eval (cadr d) env)) acc))]
                [else
                 (loop (cons (eval (list 'quasiquote d) env) acc))])))))))

  ;; The one-stop shop: compile a program in memory and hand back one of
  ;; its functions as an ordinary Scheme procedure. The procedure keeps
  ;; the underlying JIT alive.
  (define (procedure prog name)
    (jit:function (jit prog) name))

  ;; Module items that expose the module's .llvm_stackmaps section to
  ;; run-time lookup: codegen's own section symbol is local (invisible
  ;; to ORC and to normal linking), so an exported keeper pointer is
  ;; the portable handle. Splice into any program whose GC stack maps
  ;; must be readable at run time; consume via jit:stackmap-address
  ;; (JIT) or the sll_stackmaps_keeper symbol (AOT).
  ;; (@-symbols are spelled via string->symbol: the R6RS reader used
  ;; for this library rejects a leading @, unlike the .sll/user side)
  (define stackmap-keeper
    (let ([sm (string->symbol "@__LLVM_StackMaps")]
          [keeper (string->symbol "@sll_stackmaps_keeper")])
      `((= ,sm (global external i8))
        (= ,keeper (constant ptr ,sm)))))

  ;; The one-call AOT pipeline: build, stamp the module with a target
  ;; machine's triple and layout, optionally run passes, verify, emit.
  ;; opts is a property list:
  ;;   'machine       target machine to use (default: the host; a
  ;;                  machine created here is disposed here)
  ;;   'passes        new-pass-manager pipeline string, e.g.
  ;;                  "default<O2>" or "rewrite-statepoints-for-gc"
  ;;   'non-integral  address spaces for the layout's ni: component
  ;;                  (a moving-GC pointer space needs this BEFORE any
  ;;                  passes run -- see target:configure-module!)
  ;; (object prog opts ...)   -> relocatable object code, a bytevector
  ;; (assembly prog opts ...) -> assembly text, a string
  (define (compile-through prog opts emit)
    (define (opt key) (cond [(memq key opts) => cadr] [else #f]))
    (let* ([own-machine? (not (opt 'machine))]
           [tm (or (opt 'machine) (target:make-machine))]
           [ctx (ir:make-context)]
           [m (build ctx "sll" prog)])
      (target:configure-module! m tm (or (opt 'non-integral) '()))
      (cond [(opt 'passes) => (lambda (p) (ir:run-module-passes! m p))])
      (ir:verify-module m)
      (let ([result (emit tm m)])
        (ir:module-dispose! m)
        (ir:context-dispose! ctx)
        (when own-machine? (target:machine-dispose! tm))
        result)))

  (define (object prog . opts)
    (compile-through prog opts target:emit-object-bytevector))

  (define (assembly prog . opts)
    (compile-through prog opts target:emit-assembly-string))

  ;; Build a program and return its textual LLVM IR (for humans).
  (define (dump prog)
    (let* ([ctx (ir:make-context)]
           [m (build ctx "sll" prog)]
           [s (ir:module->string m)])
      (ir:module-dispose! m)
      (ir:context-dispose! ctx)
      s)))
