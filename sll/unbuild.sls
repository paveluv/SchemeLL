;;; (sll unbuild) -- the inverse of sll:build: walk an in-memory
;;; LLVM module (typically one produced by LLVM's own parser) and emit the
;;; sll program that rebuilds it. Re-exported by (sll) as sll:unbuild.
;;;
;;; Strictness: everything sll does not model raises a `not modeled` error
;;; naming the construct -- see project/not-modeled.md for the complete
;;; ledger (including constructs this walker cannot even detect). Nothing
;;; is ever silently dropped.
;;;
;;; Unnamed values: LLVM's printer numbers unnamed values per function --
;;; arguments first, then per block the block itself and each non-void
;;; instruction. unbuild names unnamed values with exactly their slot
;;; number, so the rebuilt module prints byte-identically to the source.
;;;
;;; Layering note (see project/RULES.md): this library reads through
;;; (llvm raw) getters directly -- they are read-only walks over borrowed
;;; pointers, with none of the ownership hazards (llvm ir) exists to fence.
(library (sll unbuild)
  (export unbuild)
  (import (except (chezscheme) error)
          (prefix (llvm base) base:)
          (prefix (llvm raw) LLVM)
          (prefix (llvm ir) ir:))

  (define (error msg . irritants)
    (apply base:error 'sll:unbuild msg irritants))

  (define (not-modeled what . irritants)
    (apply error
           (string-append "not modeled (see project/not-modeled.md): " what)
           irritants))

  (define (nz? x) (not (zero? x)))            ; LLVMBool -> boolean
  (define (isa? x) (not (base:null-ptr? x)))  ; LLVMIsA* cast -> boolean

  ;; read a (char*, size_t-out) style string getter
  (define (out-string getter v)
    (let-values ([(ptr len)
                  (base:call-with-out-ptr (lambda (out) (getter v out)))])
      (base:cstring->string/len ptr len)))

  ;; ---- reverse enum tables ---------------------------------------------------
  ;; Ints match Core.h; every entry is exercised end to end by the golden
  ;; corpus in tests/test-coverage.ss, which validates them empirically.

  (define opcode-names
    '((1 . ret) (2 . br) (3 . switch) (4 . indirectbr) (5 . invoke)
      (7 . unreachable) (8 . add) (9 . fadd) (10 . sub) (11 . fsub)
      (12 . mul) (13 . fmul) (14 . udiv) (15 . sdiv) (16 . fdiv)
      (17 . urem) (18 . srem) (19 . frem) (20 . shl) (21 . lshr)
      (22 . ashr) (23 . and) (24 . or) (25 . xor) (26 . alloca)
      (27 . load) (28 . store) (29 . getelementptr) (30 . trunc)
      (31 . zext) (32 . sext) (33 . fptoui) (34 . fptosi) (35 . uitofp)
      (36 . sitofp) (37 . fptrunc) (38 . fpext) (39 . ptrtoint)
      (40 . inttoptr) (41 . bitcast) (42 . icmp) (43 . fcmp) (44 . phi)
      (45 . call) (46 . select) (49 . va_arg) (50 . extractelement)
      (51 . insertelement) (52 . shufflevector) (53 . extractvalue)
      (54 . insertvalue) (55 . fence) (56 . cmpxchg) (57 . atomicrmw)
      (58 . resume) (59 . landingpad) (60 . addrspacecast)
      (61 . cleanupret) (62 . catchret) (63 . catchpad) (64 . cleanuppad)
      (65 . catchswitch) (66 . fneg) (67 . callbr) (68 . freeze)))

  (define binop-names
    '(add fadd sub fsub mul fmul udiv sdiv fdiv urem srem frem
       shl lshr ashr and or xor))

  (define cast-names
    '(trunc zext sext fptoui fptosi uitofp sitofp fptrunc fpext
       ptrtoint inttoptr bitcast addrspacecast))

  (define int-pred-names
    '((32 . eq) (33 . ne) (34 . ugt) (35 . uge) (36 . ult) (37 . ule)
      (38 . sgt) (39 . sge) (40 . slt) (41 . sle)))

  (define real-pred-names
    '((0 . false) (1 . oeq) (2 . ogt) (3 . oge) (4 . olt) (5 . ole)
      (6 . one) (7 . ord) (8 . uno) (9 . ueq) (10 . ugt) (11 . uge)
      (12 . ult) (13 . ule) (14 . une) (15 . true)))

  (define ordering-names
    '((1 . unordered) (2 . monotonic) (4 . acquire) (5 . release)
      (6 . acq_rel) (7 . seq_cst)))

  (define rmw-names
    '((0 . xchg) (1 . add) (2 . sub) (3 . and) (4 . nand) (5 . or)
      (6 . xor) (7 . max) (8 . min) (9 . umax) (10 . umin) (11 . fadd)
      (12 . fsub) (13 . fmax) (14 . fmin) (15 . uinc_wrap)
      (16 . udec_wrap)))

  (define linkage-names   ; external (0) is the default and is omitted
    '((1 . available_externally) (2 . linkonce) (3 . linkonce_odr)
      (5 . weak) (6 . weak_odr) (7 . appending) (8 . internal)
      (9 . private) (12 . extern_weak) (14 . common)))

  (define fmf-names
    '((1 . reassoc) (2 . nnan) (4 . ninf) (8 . nsz) (16 . arcp)
      (32 . contract) (64 . afn)))

  (define (enum-name table n what)
    (cond
      [(assv n table) => cdr]
      [else (not-modeled (string-append what " enum value") n)]))

  ;; ---- types --------------------------------------------------------------------

  (define (unbuild-type ty)
    (case (ir:type-kind ty)
      [(void) 'void]
      [(half) 'half]
      [(bfloat) 'bfloat]
      [(float) 'float]
      [(double) 'double]
      [(x86-fp80) 'x86_fp80]
      [(fp128) 'fp128]
      [(ppc-fp128) 'ppc_fp128]
      [(integer)
       (string->symbol
         (string-append "i" (number->string (ir:type-int-width ty))))]
      [(pointer)
       (let ([as (LLVMGetPointerAddressSpace ty)])
         (if (zero? as) 'ptr `(ptr (addrspace ,as))))]
      [(array)
       `(array ,(LLVMGetArrayLength2 ty)
               ,(unbuild-type (LLVMGetElementType ty)))]
      [(vector)
       `(vector ,(LLVMGetVectorSize ty)
                ,(unbuild-type (LLVMGetElementType ty)))]
      [(struct)
       (if (nz? (LLVMIsLiteralStruct ty))
           `(,(if (nz? (LLVMIsPackedStruct ty)) 'packed-struct 'struct)
             ,@(struct-fields ty))
           ;; identified struct: reference by name, register a (type ...)
           ;; item to be emitted at the top of the program. Unnamed ones
           ;; get first-encounter numbers -- the same order the printer
           ;; assigns %N type slots, since our walk mirrors print order
           (let ([nm (let ([given (base:cstring->string
                                    (LLVMGetStructName ty))])
                       (if (and given (not (string=? given "")))
                           given
                           (or (hashtable-ref (struct-registry) ty #f)
                               (let ([n (anon-type-counter)])
                                 (anon-type-counter (+ n 1))
                                 (number->string n)))))])
             (hashtable-set! (struct-registry) ty nm)
             (sigil-symbol "%" nm)))]
      [(function)
       `(fn ,(unbuild-type (ir:type-return-type ty))
            ,@(map unbuild-type (ir:type-param-types ty))
            ,@(if (ir:type-vararg? ty) '(variadic) '()))]
      [(scalable-vector)
       `(scalable-vector ,(LLVMGetVectorSize ty)
                         ,(unbuild-type (LLVMGetElementType ty)))]
      [(metadata) 'metadata]
      [(token) 'token]
      [else (not-modeled (string-append "type kind: " (symbol->string (ir:type-kind ty))))]))

  (define (struct-fields ty)
    (let loop ([i 0])
      (if (fx= i (LLVMCountStructElementTypes ty))
          '()
          (cons (unbuild-type (LLVMStructGetTypeAtIndex ty i))
                (loop (fx+ i 1))))))

  ;; identified structs encountered during a walk: ty -> name
  (define struct-registry (make-parameter #f))
  ;; next %N slot for unnamed identified structs (a mutable parameter)
  (define anon-type-counter
    (make-parameter 0 (lambda (v) v)))

  ;; 'tolerate-builder-folds: emit instructions the C-API builder will
  ;; fold instead of raising -- the rebuild is then only comparable
  ;; modulo folding (the corpus harness's fixpoint tier)
  (define tolerate-folds (make-parameter #f))

  ;; ---- names ---------------------------------------------------------------------

  (define-record-type ustate
    (fields names     ; value/block ptr -> %symbol
            gnames    ; global/function ptr -> @symbol
            fnptr))   ; the function being unbuilt (blockaddress check)

  (define (sigil-symbol sigil name)
    (string->symbol (string-append sigil name)))

  (define (all-digits? s)
    (let loop ([i 0])
      (or (fx= i (string-length s))
          (and (char-numeric? (string-ref s i)) (loop (fx+ i 1))))))

  (define (void-typed? v) (eq? (ir:type-kind (LLVMTypeOf v)) 'void))

  ;; assign %names per function, numbering unnamed slots like LLVM's printer
  (define (function-names f)
    (let ([tbl (make-eqv-hashtable)] [n 0])
      (define (slot!)
        (let ([s (number->string n)]) (set! n (+ n 1)) s))
      (define (add! v given)
        (when (and (not (string=? given "")) (all-digits? given))
          (not-modeled "values explicitly named with digit strings"))
        (hashtable-set! tbl v
          (sigil-symbol "%" (if (string=? given "") (slot!) given))))
      (for-each (lambda (p) (add! p (ir:value-name p)))
                (ir:function-params f))
      (for-each
        (lambda (bb)
          (add! bb (or (base:cstring->string (LLVMGetBasicBlockName bb)) ""))
          (for-each
            (lambda (ins)
              (unless (void-typed? ins) (add! ins (ir:value-name ins))))
            (ir:block-instructions bb)))
        (ir:function-blocks f))
      tbl))

  (define (local-name st v)
    (or (hashtable-ref (ustate-names st) v #f)
        (error "internal: value has no assigned name" v)))

  (define (global-sym st v)
    (or (hashtable-ref (ustate-gnames st) v #f)
        (error "internal: global has no assigned name" v)))

  ;; ---- constants -------------------------------------------------------------------

  (define (const-double c)
    (let ([out (foreign-alloc 4)])
      (foreign-set! 'integer-32 out 0 0)
      (let* ([d (LLVMConstRealGetDouble c out)]
             [lost (nz? (foreign-ref 'integer-32 out 0))])
        (foreign-free out)
        (values d lost))))

  ;; fp constants a double cannot carry (NaN payloads, fp80/fp128
  ;; values): fold the constant through its integer bits -- bitcast
  ;; constexprs fold bit-exactly in both directions for every float
  ;; type except ppc_fp128
  (define (fp-bits-form c ty)
    (let ([w (case (ir:type-kind ty)
               [(half bfloat) 16]
               [(float) 32]
               [(double) 64]
               [(x86-fp80) 80]
               [(fp128) 128]
               [else #f])])
      (unless w
        (not-modeled "fp constants not exactly representable as double"))
      (let ([ic (LLVMConstBitCast
                  c (LLVMIntTypeInContext (LLVMGetTypeContext ty) w))])
        (unless (isa? (LLVMIsAConstantInt ic))
          (not-modeled "fp constants not exactly representable as double"))
        (let ([bits (if (<= w 64)
                        (bitwise-and (LLVMConstIntGetSExtValue ic)
                                     (- (bitwise-arithmetic-shift-left 1 w) 1))
                        ;; wider than the C getters: via the printed form
                        (let* ([txt (ir:value->string ic)]
                               [sp (let loop ([i 0])
                                     (cond
                                       [(fx= i (string-length txt)) #f]
                                       [(char=? (string-ref txt i) #\space) i]
                                       [else (loop (fx+ i 1))]))]
                               [n (and sp (string->number
                                            (substring txt (fx+ sp 1)
                                                       (string-length txt))))])
                          (unless n
                            (not-modeled "unparsable wide integer constant"
                                         txt))
                          (mod n (bitwise-arithmetic-shift-left 1 w))))])
          `(bitcast ,(string->symbol
                       (string-append "i" (number->string w)))
                    ,bits
                    ,(unbuild-type ty))))))

  ;; aggregate constants are only expressible in sll where per-element-typed
  ;; groups are accepted (global initializers, landingpad clauses)
  (define (constant-form st c allow-aggregate?)
    (let ([ty (LLVMTypeOf c)])
      (cond
        [(nz? (LLVMIsPoison c)) 'poison]      ; poison is-a undef: check first
        [(nz? (LLVMIsUndef c)) 'undef]
        [(isa? (LLVMIsAConstantInt c))
         (let ([w (ir:type-int-width ty)])
           (cond
             [(= w 1) (LLVMConstIntGetZExtValue c)]   ; i1: 0/1, not 0/-1
             [(<= w 64) (LLVMConstIntGetSExtValue c)]
             [else
              ;; wider than the C API getters: read the printed form,
              ;; e.g. "i128 -5" -> -5
              (let* ([txt (ir:value->string c)]
                     [sp (let loop ([i 0])
                           (cond
                             [(fx= i (string-length txt)) #f]
                             [(char=? (string-ref txt i) #\space) i]
                             [else (loop (fx+ i 1))]))]
                     [n (and sp (string->number
                                  (substring txt (fx+ sp 1)
                                             (string-length txt))))])
                (or n (not-modeled "unparsable wide integer constant" txt)))]))]
        [(isa? (LLVMIsAConstantFP c))
         (let-values ([(d lost) (const-double c)])
           (cond
             [(and (not lost)
                   (or (= d d) (eq? (ir:type-kind ty) 'double))
                   ;; ppc_fp128: LLVMConstRealGetDouble under-reports
                   ;; loss; trust only a rebuilt-print comparison
                   (or (not (eq? (ir:type-kind ty) 'ppc-fp128))
                       (string=? (ir:value->string c)
                                 (ir:value->string (LLVMConstReal ty d)))))
              d]
             [else (fp-bits-form c ty)]))]
        [(or (isa? (LLVMIsAFunction c)) (isa? (LLVMIsAGlobalVariable c))
             (isa? (LLVMIsAGlobalAlias c)))
         (global-sym st c)]     ; globals are ptr constants
        [(isa? (LLVMIsAConstantPointerNull c)) 'null]
        [(isa? (LLVMIsAConstantAggregateZero c)) 'zeroinitializer]
        [(isa? (LLVMIsAConstantTokenNone c)) 'none]
        [(isa? (LLVMIsABlockAddress c)) (blockaddress-form st c)]
        [(or (isa? (LLVMIsAConstantDataArray c))
             (isa? (LLVMIsAConstantArray c))
             (isa? (LLVMIsAConstantStruct c))
             (isa? (LLVMIsAConstantVector c))
             (isa? (LLVMIsAConstantDataVector c)))
         (aggregate-form st c ty)]
        [(isa? (LLVMIsAConstantExpr c))
         (constexpr-form st c)]
        [else (not-modeled "constant kind" (ir:value->string c))])))

  ;; the constexpr kinds LLVM 19 still has (zext/sext/icmp/select/and/
  ;; shl are gone upstream); spelled exactly like the instruction forms
  (define constexpr-casts '(trunc ptrtoint inttoptr bitcast addrspacecast))
  (define constexpr-binops '(add sub mul xor))

  (define (constexpr-form st c)
    (let* ([opnum (LLVMGetConstOpcode c)]
           [op (enum-name opcode-names opnum "constant expression opcode")]
           [ty (LLVMTypeOf c)])
      (define (opn i) (LLVMGetOperand c i))
      (define (grp v)
        (list (unbuild-type (LLVMTypeOf v)) (constant-form st v #t)))
      (cond
        [(memq op constexpr-casts)
         `(,op ,(unbuild-type (LLVMTypeOf (opn 0)))
               ,(constant-form st (opn 0) #t)
               ,(unbuild-type ty))]
        [(memq op constexpr-binops)
         (let ([flags (if (eq? op 'xor)    ; xor carries no wrap flags
                          '()
                          (wrap-flags c))])
           ;; the C API constructors set one flag each, never both
           (when (equal? flags '(nuw nsw))
             (not-modeled "constant expressions" 'nuw+nsw))
           `(,op ,@flags ,(unbuild-type ty)
                 ,(constant-form st (opn 0) #t)
                 ,(constant-form st (opn 1) #t)))]
        [(eq? op 'getelementptr)
         ;; inrange(lo, hi) has no C API accessor at all; the printed
         ;; form is the only witness
         (when (text-contains? (ir:value->string c) "inrange(")
           (not-modeled "inrange annotations on gep constant expressions (no C API)"))
         `(getelementptr ,@(gep-flag-syms c)
                         ,(unbuild-type (LLVMGetGEPSourceElementType c))
                         ,(grp (opn 0))
                         ,@(let loop ([i 1])
                             (if (fx= i (LLVMGetNumOperands c))
                                 '()
                                 (cons (grp (opn i)) (loop (fx+ i 1))))))]
        [else (not-modeled "constant expressions" op)])))

  (define (aggregate-form st c ty)
    (let ([count (case (ir:type-kind ty)
                   [(array) (LLVMGetArrayLength2 ty)]
                   [(vector) (LLVMGetVectorSize ty)]
                   [(struct) (LLVMCountStructElementTypes ty)]
                   [else (not-modeled "aggregate constant type")])])
      (or (byte-string-form c ty count)
          (let loop ([i 0])
            (if (= i count)
                '()
                (let ([e (LLVMGetAggregateElement c i)])
                  (cons (list (unbuild-type (LLVMTypeOf e))
                              (constant-form st e #t))
                        (loop (+ i 1)))))))))

  ;; i8 arrays of ASCII bytes read back as (c "...") -- other byte arrays
  ;; fall through to per-element groups (which LLVM re-canonicalizes into
  ;; the same constant, so both spellings rebuild identically)
  (define (byte-string-form c ty count)
    (and (nz? (LLVMIsConstantString c))
         (let ([s (out-string LLVMGetAsString c)])
           (and (let ok ([i 0])
                  (or (fx= i (string-length s))
                      (and (fx< (char->integer (string-ref s i)) 128)
                           (ok (fx+ i 1)))))
                `(c ,s)))))

  (define (blockaddress-form st c)
    (let* ([f (LLVMGetBlockAddressFunction c)]
           [bb (LLVMGetBlockAddressBasicBlock c)]
           ;; another function's labels come from a fresh naming walk
           ;; (same numbering the printer gives that function)
           [names (if (eqv? f (ustate-fnptr st))
                      (ustate-names st)
                      (function-names f))])
      `(blockaddress ,(global-sym st f)
                     ,(hashtable-ref names bb #f))))

  ;; ---- operands ----------------------------------------------------------------------

  ;; equal-content metadata nodes with different identities are distinct
  ;; nodes (e.g. LowerTypeTests typeids `distinct !{}`); rebuilding them
  ;; uniqued would collapse the identities -- form -> first value seen
  (define md-node-forms (make-parameter #f))

  ;; metadata operand forms: (md "string") | (md (elem ...)); distinct
  ;; nodes rebuild as uniqued ones (no C API), cycles cannot
  (define (md-string-text v)
    (let-values ([(p len) (base:call-with-out-ptr
                            (lambda (out) (LLVMGetMDString v out)))])
      (base:cstring->string/len p len)))

  (define (md-form v seen)
    (cond
      [(isa? (LLVMIsAMDString v)) `(md ,(md-string-text v))]
      [(isa? (LLVMIsAValueAsMetadata v))
       (not-modeled "value-as-metadata operands (metadata-wrapped SSA values)")]
      [(isa? (LLVMIsAMDNode v))
       (when (memv v seen)
         (not-modeled "cyclic metadata node operands (distinct self-references)"))
       (let* ([n (LLVMGetMDNodeNumOperands v)]
              [arr (foreign-alloc (fxmax 8 (fx* 8 n)))])
         (LLVMGetMDNodeOperands v arr)
         (let loop ([i 0] [acc '()])
           (if (fx= i n)
               (begin
                 (foreign-free arr)
                 (let ([form `(md ,(reverse acc))] [reg (md-node-forms)])
                   (when reg
                     (let ([prev (hashtable-ref reg form #f)])
                       (cond
                         [(not prev) (hashtable-set! reg form v)]
                         [(eqv? prev v) (void)]
                         [else
                          (not-modeled
                            "distinct metadata operand nodes (same content, different identity; no C API for distinct nodes)")])))
                   form))
               (loop (fx+ i 1)
                     (cons (md-form (foreign-ref 'unsigned-64 arr (fx* 8 i))
                                    (cons v seen))
                           acc)))))]
      [else (not-modeled "metadata operand kind")]))

  (define (metadata-value? v)
    (or (isa? (LLVMIsAMDString v)) (isa? (LLVMIsAValueAsMetadata v))
        (isa? (LLVMIsAMDNode v))))

  (define (operand st v)
    (cond
      [(metadata-value? v) (md-form v '())]
      [(isa? (LLVMIsAArgument v)) (local-name st v)]
      [(isa? (LLVMIsAInstruction v)) (local-name st v)]
      [(or (isa? (LLVMIsAFunction v)) (isa? (LLVMIsAGlobalVariable v))
           (isa? (LLVMIsAGlobalAlias v)))
       (global-sym st v)]
      [(isa? (LLVMIsAInlineAsm v)) (asm-form v)]
      [else (constant-form st v #t)]))

  (define (group st v)      ; typed operand group (type value)
    (list (unbuild-type (LLVMTypeOf v)) (operand st v)))

  (define (asm-form v)
    (unless (zero? (LLVMGetInlineAsmDialect v))
      (not-modeled "Intel-dialect inline asm"))
    (when (nz? (LLVMGetInlineAsmCanUnwind v))
      (not-modeled "unwinding inline asm (asm unwind)"))
    `(asm ,(out-string LLVMGetInlineAsmAsmString v)
          ,(out-string LLVMGetInlineAsmConstraintString v)
          ,@(if (nz? (LLVMGetInlineAsmHasSideEffects v)) '(sideeffect) '())
          ,@(if (nz? (LLVMGetInlineAsmNeedsAlignedStack v)) '(alignstack) '())))

  ;; ---- instruction flags ------------------------------------------------------------

  (define (wrap-flags v)
    (append (if (nz? (LLVMGetNUW v)) '(nuw) '())
            (if (nz? (LLVMGetNSW v)) '(nsw) '())))

  (define (fmf-flags v)
    (if (ir:can-use-fast-math-flags? v)
        (let ([m (ir:fast-math-flags v)])
          (cond
            [(zero? m) '()]
            [(= m 127) '(fast)]
            [else (fold-right (lambda (e acc)
                                (if (nz? (bitwise-and m (car e)))
                                    (cons (cdr e) acc)
                                    acc))
                              '() fmf-names)]))
        '()))

  (define (int-flags v op)
    (cond
      [(memq op '(add sub mul shl trunc)) (wrap-flags v)]
      [(memq op '(udiv sdiv lshr ashr))
       (if (nz? (LLVMGetExact v)) '(exact) '())]
      [(eq? op 'or) (if (nz? (LLVMGetIsDisjoint v)) '(disjoint) '())]
      [else '()]))

  (define (gep-flag-syms v)
    (let ([m (LLVMGEPGetNoWrapFlags v)])
      (append (if (nz? (bitwise-and m 1)) '(inbounds) '())
              ;; inbounds implies nusw; only emit nusw when it stands alone
              (if (and (nz? (bitwise-and m 2)) (zero? (bitwise-and m 1)))
                  '(nusw) '())
              (if (nz? (bitwise-and m 4)) '(nuw) '()))))

  (define (memory-flags v atomic?)
    (append (if (nz? (LLVMGetVolatile v)) '(volatile) '())
            (if atomic? '(atomic) '())
            (if (nz? (LLVMIsAtomicSingleThread v)) '(singlethread) '())))

  (define (ordering-tail v)   ; atomic load/store ordering
    (let ([o (ir:instruction-ordering v)])
      (if (zero? o)
          (values '() #f)
          (values (list (enum-name ordering-names o "ordering")) #t))))

  ;; GetAlignment returns 0 both for "unset" and for alignments >= 2^32
  ;; (a C API truncation); omit the attribute in either case
  (define (align-attr v)
    (let ([a (LLVMGetAlignment v)])
      (if (zero? a) '() `((align ,a)))))

  ;; ---- instructions ------------------------------------------------------------------

  ;; the <letter><n> component of a datalayout string (A = alloca
  ;; space, P = program space); no C API exposes these
  (define (dl-component dl letter)
    (if (not dl)
        0
        (let ([n (string-length dl)])
          (let loop ([i 0])
            (cond
              [(>= i n) 0]
              [(and (char=? (string-ref dl i) letter)
                    (or (zero? i) (char=? (string-ref dl (- i 1)) #\-))
                    (< (+ i 1) n)
                    (char-numeric? (string-ref dl (+ i 1))))
               (let scan ([j (+ i 1)] [v 0])
                 (if (and (< j n) (char-numeric? (string-ref dl j)))
                     (scan (+ j 1)
                           (+ (* v 10)
                              (- (char->integer (string-ref dl j)) 48)))
                     v))]
              [else (loop (+ i 1))])))))
  (define (dl-alloca-addrspace dl) (dl-component dl #\A))
  (define (dl-program-addrspace dl) (dl-component dl #\P))

  (define (block-label st bb) `(label ,(local-name st bb)))

  (define (successor st ins i)
    (block-label st (LLVMGetSuccessor ins i)))

  (define (call-type-slot fnty)
    (if (ir:type-vararg? fnty)
        (unbuild-type fnty)
        (unbuild-type (ir:type-return-type fnty))))

  ;; (bundle "tag" (type arg) ...) forms from a call site; each read
  ;; bundle ref is a fresh object the reader must dispose
  (define (bundle-forms st ins)
    (let ([nb (LLVMGetNumOperandBundles ins)])
      (let loop ([i 0])
        (if (fx= i nb)
            '()
            (let* ([bref (LLVMGetOperandBundleAtIndex ins i)]
                   [tag (let-values ([(p len)
                                      (base:call-with-out-ptr
                                        (lambda (out)
                                          (LLVMGetOperandBundleTag bref out)))])
                          (base:cstring->string/len p len))]
                   [na (LLVMGetNumOperandBundleArgs bref)]
                   [bargs (let aloop ([j 0])
                            (if (fx= j na)
                                '()
                                (cons (group st (LLVMGetOperandBundleArgAtIndex
                                                  bref j))
                                      (aloop (fx+ j 1)))))])
              (LLVMDisposeOperandBundle bref)
              (cons `(bundle ,tag ,@bargs) (loop (fx+ i 1))))))))

  ;; a callee through a pointer outside the program address space needs
  ;; IR's `call addrspace(N)` spelling (only render consumes this; the
  ;; builder takes the space from the callee value itself)
  (define (callee-addrspace-marker st ins)
    (let ([as (LLVMGetPointerAddressSpace
                (LLVMTypeOf (LLVMGetCalledValue ins)))]
          [pas (dl-program-addrspace
                 (base:cstring->string
                   (LLVMGetDataLayoutStr
                     (LLVMGetGlobalParent (ustate-fnptr st)))))])
      (if (= as pas) '() `((addrspace ,as)))))

  (define (application st ins)
    (let ([n (LLVMGetNumArgOperands ins)])
      ;; the callee slot carries no type annotation in sll, so callees
      ;; whose value NEEDS one (null/undef/poison) lose a non-zero
      ;; address space; named callees carry their own type and are fine
      (let ([cv (LLVMGetCalledValue ins)])
        (when (and (not (zero? (LLVMGetPointerAddressSpace (LLVMTypeOf cv))))
                   (or (isa? (LLVMIsAConstantPointerNull cv))
                       (nz? (LLVMIsUndef cv))
                       (nz? (LLVMIsPoison cv))))
          (not-modeled "calls through pointer constants in non-zero address spaces")))
      (cons (operand st (LLVMGetCalledValue ins))
            (let loop ([i 0])
              (if (fx= i n)
                  '()
                  (cons (group st (LLVMGetOperand ins i))
                        (loop (fx+ i 1))))))))

  ;; opcodes the C-API builder constant-folds when every operand is a
  ;; constant -- unrebuildable as instructions, so flagged honestly
  (define foldable-ops
    '(add fadd sub fsub mul fmul udiv sdiv fdiv urem srem frem
       shl lshr ashr and or xor fneg
       trunc zext sext fptoui fptosi uitofp sitofp fptrunc fpext
       ptrtoint inttoptr bitcast addrspacecast
       icmp fcmp select getelementptr
       extractelement insertelement shufflevector
       extractvalue insertvalue))

  (define (all-constant-operands? ins)
    (let ([n (LLVMGetNumOperands ins)])
      (let loop ([i 0])
        (or (fx= i n)
            (and (isa? (LLVMIsAConstant (LLVMGetOperand ins i)))
                 (loop (fx+ i 1)))))))

  (define (insn-form st ins)
    (when (nz? (LLVMHasMetadata ins))
      (not-modeled "instruction metadata (!dbg, !tbaa, ...)"))
    (let* ([opnum (ir:instruction-opcode ins)]
           [op (enum-name opcode-names opnum "opcode")]
           [ty (LLVMTypeOf ins)])
      (define (op0) (LLVMGetOperand ins 0))
      (define (op1) (LLVMGetOperand ins 1))
      (define (op2) (LLVMGetOperand ins 2))
      (when (and (not (tolerate-folds)) (memq op foldable-ops)
                 (all-constant-operands? ins))
        (not-modeled "instructions with all-constant operands (the C-API builder folds them)"))
      (cond
        [(memq op binop-names)
         `(,op ,@(int-flags ins op) ,@(fmf-flags ins)
               ,(unbuild-type ty) ,(operand st (op0)) ,(operand st (op1)))]
        [(memq op cast-names)
         (when (and (not (tolerate-folds)) (eqv? (LLVMTypeOf (op0)) ty))
           (not-modeled "no-op casts (the C-API builder folds them away)"))
         `(,op ,@(if (eq? op 'trunc) (wrap-flags ins) '())
               ,@(if (and (memq op '(zext uitofp)) (nz? (LLVMGetNNeg ins)))
                     '(nneg) '())
               ,(unbuild-type (LLVMTypeOf (op0))) ,(operand st (op0))
               ,(unbuild-type ty))]
        [else
         (case op
           [(ret)
            (if (zero? (LLVMGetNumOperands ins))
                '(ret void)
                `(ret ,(unbuild-type (LLVMTypeOf (op0))) ,(operand st (op0))))]
           [(br)
            (if (= 1 (LLVMGetNumSuccessors ins))
                `(br ,(successor st ins 0))
                `(br i1 ,(operand st (op0))
                     ,(successor st ins 0) ,(successor st ins 1)))]
           [(switch)
            `(switch ,(unbuild-type (LLVMTypeOf (op0))) ,(operand st (op0))
                     ,(successor st ins 0)
                     ,@(let loop ([i 1])
                         (if (fx= i (LLVMGetNumSuccessors ins))
                             '()
                             (cons (list (group st (LLVMGetOperand ins (* 2 i)))
                                         (successor st ins i))
                               (loop (fx+ i 1))))))]
           [(indirectbr)
            `(indirectbr ,(group st (op0))
                         ,@(let loop ([i 0])
                             (if (fx= i (LLVMGetNumSuccessors ins))
                                 '()
                                 (cons (successor st ins i)
                                       (loop (fx+ i 1))))))]
           [(unreachable) '(unreachable)]
           [(fneg)
            `(fneg ,@(fmf-flags ins) ,(unbuild-type ty) ,(operand st (op0)))]
           [(icmp)
            `(icmp ,(enum-name int-pred-names (ir:icmp-predicate ins)
                               "icmp predicate")
                   ,(unbuild-type (LLVMTypeOf (op0)))
                   ,(operand st (op0)) ,(operand st (op1)))]
           [(fcmp)
            `(fcmp ,@(fmf-flags ins)
                   ,(enum-name real-pred-names (ir:fcmp-predicate ins)
                               "fcmp predicate")
                   ,(unbuild-type (LLVMTypeOf (op0)))
                   ,(operand st (op0)) ,(operand st (op1)))]
           [(select)
            `(select ,@(fmf-flags ins)
                     ,(group st (op0)) ,(group st (op1)) ,(group st (op2)))]
           [(phi)
            `(phi ,@(fmf-flags ins) ,(unbuild-type ty)
                  ,@(let loop ([i 0])
                      (if (fx= i (LLVMCountIncoming ins))
                          '()
                          (cons (list (operand st (LLVMGetIncomingValue ins i))
                                      (local-name st (LLVMGetIncomingBlock ins i)))
                                (loop (fx+ i 1))))))]
           [(call)
            `(call ,@(case (ir:tail-call-kind ins)
                       [(0) '()] [(1) '(tail)] [(2) '(musttail)]
                       [else '(notail)])
                   ,@(fmf-flags ins)
                   ,@(callee-addrspace-marker st ins)
                   ,(call-type-slot (LLVMGetCalledFunctionType ins))
                   ,(application st ins)
                   ,@(bundle-forms st ins))]
           [(invoke)
            `(invoke ,(call-type-slot (LLVMGetCalledFunctionType ins))
                     ,(application st ins)
                     ,@(bundle-forms st ins)
                     ,(block-label st (LLVMGetNormalDest ins))
                     ,(block-label st (LLVMGetUnwindDest ins)))]
           [(callbr)
            (when (nz? (LLVMGetNumOperandBundles ins))
              (not-modeled "operand bundles on callbr"))
            `(callbr ,(call-type-slot (LLVMGetCalledFunctionType ins))
                     ,(application st ins)
                     ,(successor st ins 0)
                     ,(let loop ([i 1])
                        (if (fx= i (LLVMGetNumSuccessors ins))
                            '()
                            (cons (successor st ins i) (loop (fx+ i 1))))))]
           [(alloca)
            ;; the C-API builder always allocates in the datalayout's
            ;; alloca space (A); only allocas THERE can be rebuilt
            (let ([as (LLVMGetPointerAddressSpace ty)]
                  [dl (base:cstring->string
                        (LLVMGetDataLayoutStr
                          (LLVMGetGlobalParent (ustate-fnptr st))))])
              (unless (= as (dl-alloca-addrspace dl))
                (not-modeled "alloca outside the datalayout's alloca address space (the C-API builder always uses A)")))
            `(alloca ,(unbuild-type (LLVMGetAllocatedType ins))
                     ,@(let ([count (op0)])
                         ;; the printer elides only an i32-typed constant 1
                         (if (and (isa? (LLVMIsAConstantInt count))
                                  (= 1 (LLVMConstIntGetZExtValue count))
                                  (= 32 (ir:type-int-width (LLVMTypeOf count))))
                             '()
                             (list (group st count))))
                     ,@(align-attr ins)
                     ,@(let ([as (LLVMGetPointerAddressSpace ty)])
                         (if (zero? as) '() `((addrspace ,as)))))]
           [(load)
            (let-values ([(ord atomic?) (ordering-tail ins)])
              `(load ,@(memory-flags ins atomic?) ,(unbuild-type ty)
                     ,(group st (op0)) ,@ord ,@(align-attr ins)))]
           [(store)
            (let-values ([(ord atomic?) (ordering-tail ins)])
              `(store ,@(memory-flags ins atomic?)
                      ,(group st (op0)) ,(group st (op1))
                      ,@ord ,@(align-attr ins)))]
           [(getelementptr)
            `(getelementptr ,@(gep-flag-syms ins)
                            ,(unbuild-type (LLVMGetGEPSourceElementType ins))
                            ,(group st (op0))
                            ,@(let loop ([i 1])
                                (if (fx= i (LLVMGetNumOperands ins))
                                    '()
                                    (cons (group st (LLVMGetOperand ins i))
                                          (loop (fx+ i 1))))))]
           [(extractelement)
            `(extractelement ,(group st (op0)) ,(group st (op1)))]
           [(insertelement)
            `(insertelement ,(group st (op0)) ,(group st (op1))
                            ,(group st (op2)))]
           [(shufflevector)
            `(shufflevector ,(group st (op0)) ,(group st (op1))
                            (mask ,@(let loop ([i 0])
                                      (if (fx= i (LLVMGetNumMaskElements ins))
                                          '()
                                          (let ([m (LLVMGetMaskValue ins i)])
                                            (cons (if (= m (LLVMGetUndefMaskElem))
                                                      'poison m)
                                                  (loop (fx+ i 1))))))))]
           [(extractvalue insertvalue)
            ;; multi-index forms have no C-API builder; under the
            ;; tolerance flag they are emitted for the render tier
            (when (and (> (LLVMGetNumIndices ins) 1)
                       (not (tolerate-folds)))
              (not-modeled "multi-index extractvalue/insertvalue"))
            (let* ([n (LLVMGetNumIndices ins)]
                   [arr (LLVMGetIndices ins)]
                   [idxs (let loop ([i 0])
                           (if (fx= i n)
                               '()
                               (cons (foreign-ref 'unsigned-32 arr
                                                  (fx* 4 i))
                                     (loop (fx+ i 1)))))])
              (if (eq? op 'extractvalue)
                  `(extractvalue ,(group st (op0)) ,@idxs)
                  `(insertvalue ,(group st (op0)) ,(group st (op1))
                                ,@idxs)))]
           [(fence)
            `(fence ,@(if (nz? (LLVMIsAtomicSingleThread ins))
                          '(singlethread) '())
                    ,(enum-name ordering-names (ir:instruction-ordering ins)
                                "ordering"))]
           [(atomicrmw)
            `(atomicrmw ,@(memory-flags ins #f)
                        ,(enum-name rmw-names (ir:atomicrmw-binop ins)
                                    "atomicrmw operation")
                        ,(group st (op0)) ,(group st (op1))
                        ,(enum-name ordering-names
                                    (ir:instruction-ordering ins) "ordering")
                        ,@(align-attr ins))]
           [(cmpxchg)
            `(cmpxchg ,@(if (nz? (LLVMGetWeak ins)) '(weak) '())
                      ,@(memory-flags ins #f)
                      ,(group st (op0)) ,(group st (op1)) ,(group st (op2))
                      ,(enum-name ordering-names
                                  (ir:cmpxchg-success-ordering ins) "ordering")
                      ,(enum-name ordering-names
                                  (ir:cmpxchg-failure-ordering ins) "ordering")
                      ,@(align-attr ins))]
           [(va_arg)
            `(va_arg ,(group st (op0)) ,(unbuild-type ty))]
           [(freeze)
            `(freeze ,(unbuild-type ty) ,(operand st (op0)))]
           [(landingpad)
            `(landingpad ,(unbuild-type ty)
                         ,@(if (nz? (LLVMIsCleanup ins)) '(cleanup) '())
                         ,@(let loop ([i 0])
                             (if (fx= i (LLVMGetNumClauses ins))
                                 '()
                                 (let* ([c (LLVMGetClause ins i)]
                                        [cty (LLVMTypeOf c)]
                                        [kind (if (eq? (ir:type-kind cty) 'array)
                                                  'filter 'catch)])
                                   (cons (list kind (unbuild-type cty)
                                               (constant-form st c #t))
                                         (loop (fx+ i 1)))))))]
           [(resume)
            `(resume ,(unbuild-type (LLVMTypeOf (op0))) ,(operand st (op0)))]
           [(catchswitch)
            `(catchswitch ,(parent-pad-form st (op0))
                          ,(let* ([n (LLVMGetNumHandlers ins)]
                                  [arr (foreign-alloc (fxmax 8 (fx* 8 n)))])
                             (LLVMGetHandlers ins arr)
                             (let loop ([i 0] [acc '()])
                               (if (fx= i n)
                                   (begin (foreign-free arr) (reverse acc))
                                   (loop (fx+ i 1)
                                     (cons (block-label st
                                             (foreign-ref 'unsigned-64 arr
                                                          (fx* 8 i)))
                                           acc)))))
                          ,(unwind-dest-form st ins))]
           [(catchpad cleanuppad)
            (let ([n (LLVMGetNumOperands ins)])
              `(,op ,(parent-pad-form st (LLVMGetOperand ins (- n 1)))
                    ,(let loop ([i 0])
                       (if (fx= i (fx- n 1))
                           '()
                           (cons (group st (LLVMGetOperand ins i))
                                 (loop (fx+ i 1)))))))]
           [(catchret)
            `(catchret ,(operand st (op0)) ,(successor st ins 0))]
           [(cleanupret)
            `(cleanupret ,(operand st (op0)) ,(unwind-dest-form st ins))]
           [else (not-modeled "instruction" op)])])))

  (define (parent-pad-form st v)
    (if (isa? (LLVMIsAConstantTokenNone v)) 'none (operand st v)))

  (define (unwind-dest-form st ins)
    (let ([bb (LLVMGetUnwindDest ins)])
      (if (base:null-ptr? bb) 'caller (block-label st bb))))

  (define (instruction-form st ins)
    (let ([f (insn-form st ins)])
      (if (void-typed? ins)
          f
          `(= ,(local-name st ins) ,f))))

  ;; ---- functions -----------------------------------------------------------------------

  (define (check-function-decorations f nparams)
    ;; both the parser and LLVMAddFunction place functions in the
    ;; datalayout's program space (P); only functions THERE rebuild
    (unless (= (LLVMGetPointerAddressSpace (LLVMTypeOf f))
               (dl-program-addrspace
                 (base:cstring->string
                   (LLVMGetDataLayoutStr (LLVMGetGlobalParent f)))))
      (not-modeled "functions outside the datalayout's program address space"))
    (when (nz? (LLVMHasPrefixData f)) (not-modeled "function prefix data"))
    (when (nz? (LLVMHasPrologueData f)) (not-modeled "function prologue data"))
    (unless (zero? (LLVMGetFunctionCallConv f))
      (not-modeled "non-C calling conventions" (LLVMGetFunctionCallConv f)))
    (unless (zero? (LLVMGetVisibility f))
      (not-modeled "visibility (hidden/protected)"))
    (let ([s (base:cstring->string (LLVMGetSection f))])
      (when (and s (not (string=? s ""))) (not-modeled "sections")))
    ;; attribute indices: function (~0), return (0), params (1..n)
    (do ([i -1 (+ i 1)])
        ((> i nparams))
      (unless (zero? (LLVMGetAttributeCountAtIndex
                       f (if (= i -1) 4294967295 i)))
        (not-modeled "function/return/parameter attributes"))))

  (define (gc-attr f)
    (let ([s (ir:gc-name f)])
      (if (and s (not (string=? s ""))) `((gc ,s)) '())))

  (define (unbuild-function gnames f)
    (let* ([fnty (ir:function-type-of f)]
           [params (ir:function-params f)]
           [variadic (if (ir:type-vararg? fnty) '(variadic) '())]
           [gname (hashtable-ref gnames f #f)])
      (check-function-decorations f (length params))
      (let ([lk-part (let ([lk (ir:linkage f)])
                       (if (zero? lk) '()
                           (list (enum-name linkage-names lk "linkage"))))])
        (if (ir:declaration? f)
          `(declare ,@lk-part
                    ,(unbuild-type (ir:type-return-type fnty))
                    (,gname ,@(map unbuild-type (ir:type-param-types fnty))
                            ,@variadic)
                    ,@(align-attr f)
                    ,@(gc-attr f))
          (let ([st (make-ustate (function-names f) gnames f)])
            `(define ,@lk-part
               ,(unbuild-type (ir:type-return-type fnty))
               (,gname
                 ,@(map (lambda (p)
                          (list (unbuild-type (LLVMTypeOf p))
                                (local-name st p)))
                        params)
                 ,@variadic)
               ,@(align-attr f)
               ,@(gc-attr f)
               ;; the personality is any ptr constant: @fn, null, undef
               ,@(if (nz? (LLVMHasPersonalityFn f))
                     `((personality
                         ,@(group st (LLVMGetPersonalityFn f))))
                     '())
               ,@(map (lambda (bb)
                        `(label ,(local-name st bb)
                           ,@(map (lambda (ins) (instruction-form st ins))
                                  (ir:block-instructions bb))))
                      (ir:function-blocks f))))))))

  ;; ---- globals --------------------------------------------------------------------------

  (define (check-global-decorations g)
    (when (nz? (LLVMIsThreadLocal g)) (not-modeled "thread_local globals"))
    (unless (zero? (LLVMGetVisibility g))
      (not-modeled "visibility (hidden/protected)"))
    (let ([s (base:cstring->string (LLVMGetSection g))])
      (when (and s (not (string=? s ""))) (not-modeled "sections"))))

  (define (unbuild-global gnames g)
    (check-global-decorations g)
    (let* ([st (make-ustate (make-eqv-hashtable) gnames base:null-ptr)]
           [lk (ir:linkage g)]
           [init (LLVMGetInitializer g)]
           [align (LLVMGetAlignment g)])
      `(= ,(hashtable-ref gnames g #f)
          (,(if (nz? (LLVMIsGlobalConstant g)) 'constant 'global)
           ,@(let ([as (LLVMGetPointerAddressSpace (LLVMTypeOf g))])
               (if (zero? as) '() `((addrspace ,as))))
           ;; external is the default and stays implicit -- except on
           ;; declarations, where sll (like IR) spells it out
           ,@(if (zero? lk)
                 (if (base:null-ptr? init) '(external) '())
                 (list (enum-name linkage-names lk "linkage")))
           ,@(if (nz? (LLVMIsExternallyInitialized g))
                 '(externally_initialized) '())
           ,(unbuild-type (LLVMGlobalGetValueType g))
           ,@(if (base:null-ptr? init)
                 '()
                 (list (constant-form st init #t)))
           ,@(if (zero? align) '() `((align ,align)))))))

  ;; ---- the module ------------------------------------------------------------------------

  (define (module-target-items m)
    (let ([mp (ir:module-live-ptr m)])
      (append
        (let ([d (base:cstring->string (LLVMGetDataLayoutStr mp))])
          (if (and d (not (string=? d ""))) `((datalayout ,d)) '()))
        (let ([t (base:cstring->string (LLVMGetTarget mp))])
          (if (and t (not (string=? t ""))) `((triple ,t)) '()))
        (let ([a (out-string LLVMGetModuleInlineAsm mp)])
          (if (string=? a "") '() `((module-asm ,a)))))))

  (define (check-module-decorations m ignore-named-metadata?)
    (let ([mp (ir:module-live-ptr m)])
      (unless (or ignore-named-metadata?
                  (base:null-ptr? (LLVMGetFirstNamedMetadata mp)))
        (not-modeled "named module metadata"))
    ))

  ;; unnamed globals/functions get their print slot numbers, like locals
  (define (module-gnames m)
    (let ([tbl (make-eqv-hashtable)] [n 0])
      (define (add! v)
        (let ([given (ir:value-name v)])
          (when (and (not (string=? given "")) (all-digits? given))
            (not-modeled "values explicitly named with digit strings"))
          (hashtable-set! tbl v
            (sigil-symbol "@"
              (if (string=? given "")
                  (let ([s (number->string n)]) (set! n (+ n 1)) s)
                  given)))))
      (for-each add! (ir:module-globals m))
      (for-each add! (ir:module-aliases m))
      (for-each add! (ir:module-ifuncs m))
      (for-each add! (ir:module-functions m))
      tbl))

  ;; ---- aliases ----------------------------------------------------------------------

  (define (text-contains? s sub)
    (let ([n (string-length s)] [m (string-length sub)])
      (let loop ([i 0])
        (cond
          [(> (+ i m) n) #f]
          [(string=? (substring s i (+ i m)) sub) #t]
          [else (loop (+ i 1))]))))

  (define (unbuild-ifunc gnames i)
    (let ([st (make-ustate (make-eqv-hashtable) gnames base:null-ptr)]
          [lk (ir:linkage i)])
      `(= ,(hashtable-ref gnames i #f)
          (ifunc ,@(if (zero? lk) '()
                       (list (enum-name linkage-names lk "linkage")))
                 ,(unbuild-type (LLVMGlobalGetValueType i))
                 ,(group st (ir:ifunc-resolver i))))))

  (define (unbuild-alias gnames a)
    (unless (zero? (LLVMGetPointerAddressSpace (LLVMTypeOf a)))
      (not-modeled "aliases in non-zero address spaces"))
    ;; the thread-local accessors unwrap GlobalVariable, so an alias's
    ;; thread_local bit is only witnessed textually
    (when (text-contains? (ir:value->string a) " thread_local")
      (not-modeled "thread_local aliases (no C API accessor)"))
    (let ([st (make-ustate (make-eqv-hashtable) gnames base:null-ptr)]
          [lk (ir:linkage a)])
      `(= ,(hashtable-ref gnames a #f)
          (alias ,@(if (zero? lk) '()
                       (list (enum-name linkage-names lk "linkage")))
                 ,(unbuild-type (LLVMGlobalGetValueType a))
                 ,(group st (ir:alias-aliasee a))))))

  ;; every identified struct met during the walk becomes a (type ...) item;
  ;; emitting bodies can register further structs, so iterate to a fixpoint
  (define (type-items)
    (let loop ([done '()] [acc '()])
      (let* ([reg (struct-registry)]
             [pending (let-values ([(ks vs) (hashtable-entries reg)])
                        (filter (lambda (kv) (not (member kv done)))
                                (map cons (vector->list ks)
                                     (vector->list vs))))])
        (if (null? pending)
            (list-sort (lambda (a b) (string<? (symbol->string (cadr a))
                                               (symbol->string (cadr b))))
                       acc)
            (loop (append pending done)
                  (append
                    (map (lambda (kv)
                           (let ([ty (car kv)] [nm (cdr kv)])
                             `(type ,(sigil-symbol "%" nm)
                                    ,(if (nz? (LLVMIsOpaqueStruct ty))
                                         'opaque
                                         `(,(if (nz? (LLVMIsPackedStruct ty))
                                                'packed-struct 'struct)
                                           ,@(struct-fields ty))))))
                         pending)
                    acc))))))

  ;; module record -> sll program. opts: 'ignore-named-metadata makes the
  ;; walk tolerate named module metadata WITHOUT representing it (the
  ;; corpus harness strips it from the comparison; plain unbuild stays
  ;; strict so the tool never silently loses it).
  (define (unbuild m . opts)
    (parameterize ([struct-registry (make-eqv-hashtable)]
                   [anon-type-counter 0]
                   [md-node-forms (make-hashtable equal-hash equal?)]
                   [tolerate-folds (memq 'tolerate-builder-folds opts)])
      (check-module-decorations m (memq 'ignore-named-metadata opts))
      (let ([gnames (module-gnames m)])
        (let ([items
               (append
                 (map (lambda (g) (unbuild-global gnames g))
                      (ir:module-globals m))
                 (map (lambda (a) (unbuild-alias gnames a))
                      (ir:module-aliases m))
                 (map (lambda (i) (unbuild-ifunc gnames i))
                      (ir:module-ifuncs m))
                 (map (lambda (f) (unbuild-function gnames f))
                      (ir:module-functions m)))])
          ;; target strings first: the parser rejects `target` lines
          ;; after any other top-level entity
          (append (module-target-items m) (type-items) items))))))
