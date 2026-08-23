;;; (llvm ir) -- layer 1: safe handles and IR construction.
;;;
;;; Ownership model (see project/RULES.md):
;;;   - Owning handles (context, module, builder) are records with a mutable
;;;     state field: owned | borrowed | consumed | disposed. All use goes
;;;     through *-live-ptr accessors that raise instead of segfaulting.
;;;   - Types, values and basic blocks are borrowed pointers (raw addresses);
;;;     they live exactly as long as their context.
(library (llvm ir)
  (export
    ;; contexts
    context? make-context wrap-context context-dispose! context-live-ptr
    ;; modules
    module? make-module module-dispose! module-live-ptr module-consume!
    module-context module->string verify-module
    set-module-target-triple! set-module-data-layout!
    run-module-passes! parse-ir
    ;; walking built IR (observation / disassembly)
    module-functions function-blocks block-instructions
    instruction-opcode icmp-predicate fcmp-predicate
    ;; builders
    builder? make-builder builder-dispose! builder-live-ptr
    ;; types
    void-type int-type int1-type int8-type int16-type int32-type int64-type
    float-type double-type half-type bfloat-type fp128-type x86fp80-type
    ppcfp128-type
    pointer-type function-type struct-type array-type
    vector-type scalable-vector-type
    named-type create-named-struct struct-set-body! value->string
    type-kind type-int-width type-return-type type-param-types type-vararg?
    type->string
    ;; functions / values
    add-function named-function function-type-of
    function-param function-params value-name set-value-name! declaration?
    set-alignment!
    ;; instruction flags
    set-nsw! set-nuw! set-exact! set-nneg! set-disjoint! set-volatile!
    set-fast-math-flags! fast-math-flags can-use-fast-math-flags?
    gep-no-wrap-flags
    const-int const-real const-null undef-value poison-value
    const-vector block-address
    const-array const-struct const-named-struct const-string struct-name
    const-cast const-binop const-gep
    add-alias alias-aliasee alias-set-aliasee! module-aliases
    add-ifunc ifunc-resolver ifunc-set-resolver! module-ifuncs
    set-module-asm!
    metadata-type md-string md-node metadata-value
    value-address-space set-atomic-single-thread! set-externally-initialized!
    set-gc! gc-name set-target! set-data-layout!
    create-operand-bundle dispose-operand-bundle!
    build-call-bundles build-invoke-bundles
    packed-struct-type?
    ;; module-level globals
    add-global set-initializer! set-global-constant! set-linkage! linkage
    module-globals
    ;; basic blocks / positioning
    append-block position-at-end! insert-block
    ;; instructions
    build-ret build-ret-void build-br build-cond-br
    build-switch add-case! build-indirect-br add-destination!
    build-unreachable build-freeze build-va-arg
    build-invoke build-resume build-landingpad add-clause!
    set-landingpad-cleanup! set-personality-fn!
    build-catchswitch add-handler! build-catchpad build-cleanuppad
    build-catchret build-cleanupret
    build-callbr inline-asm token-type
    build-extractelement build-insertelement build-shufflevector
    build-extractvalue build-insertvalue
    build-fence build-atomicrmw build-cmpxchg
    set-ordering! instruction-ordering set-weak!
    atomicrmw-binop cmpxchg-success-ordering cmpxchg-failure-ordering
    build-add build-sub build-mul build-sdiv build-udiv build-srem build-urem
    build-and build-or build-xor build-shl build-lshr build-ashr
    build-fadd build-fsub build-fmul build-fdiv build-frem
    build-neg build-fneg build-not
    build-icmp build-fcmp build-select
    build-phi phi-add-incoming!
    build-call build-alloca build-array-alloca build-load build-store
    build-gep build-gep/flags
    set-tail-call-kind! tail-call-kind
    replace-all-uses! erase-instruction! delete-block!
    build-trunc build-zext build-sext
    build-si->fp build-ui->fp build-fp->si build-fp->ui
    build-fptrunc build-fpext build-ptr->int build-int->ptr build-bitcast
    build-addrspacecast)
  (import (chezscheme) (prefix (llvm raw) LLVM) (prefix (llvm base) base:))

  ;; ---- contexts -----------------------------------------------------------

  (define-record-type (context $make-context context?)
    (fields ptr (mutable state))
    (nongenerative llvm-context-v0))

  (define (make-context)
    ($make-context (LLVMContextCreate) 'owned))

  ;; Wrap a context pointer someone else owns (e.g. an ORC ThreadSafeContext).
  (define (wrap-context ptr)
    ($make-context ptr 'borrowed))

  (define (context-live-ptr ctx)
    (let ([s (context-state ctx)])
      (unless (memq s '(owned borrowed))
        (base:error 'context "context is no longer live" s))
      (context-ptr ctx)))

  (define (context-dispose! ctx)
    (case (context-state ctx)
      [(owned)
       (LLVMContextDispose (context-ptr ctx))
       (context-state-set! ctx 'disposed)]
      [(borrowed) (context-state-set! ctx 'disposed)] ; owner frees the C object
      [else (void)]))

  ;; ---- modules ------------------------------------------------------------

  ;; record-type name is llvm-module because `module` is a Chez keyword
  (define-record-type (llvm-module $make-module module?)
    (fields (immutable ptr module-ptr)
            (immutable context module-context)
            (mutable state module-state module-state-set!))
    (nongenerative llvm-module-v0))

  (define (make-module ctx name)
    ($make-module (LLVMModuleCreateWithNameInContext
                    name (context-live-ptr ctx))
                  ctx 'owned))

  (define (module-live-ptr m)
    (unless (eq? (module-state m) 'owned)
      (base:error 'module "module is no longer live (handed to JIT or disposed?)"
                  (module-state m)))
    (module-ptr m))

  ;; Called by (llvm jit) when ownership moves into a ThreadSafeModule.
  (define (module-consume! m)
    (module-live-ptr m)
    (module-state-set! m 'consumed))

  (define (module-dispose! m)
    (when (eq? (module-state m) 'owned)
      (LLVMDisposeModule (module-ptr m))
      (module-state-set! m 'disposed)))

  (define (module->string m)
    (base:cstring->string/dispose (LLVMPrintModuleToString (module-live-ptr m))))

  ;; Raises with LLVM's diagnostic if the module is invalid.
  (define (verify-module m)
    (let-values ([(failed msg-ptr)
                  (base:call-with-out-ptr
                    (lambda (out)
                      (LLVMVerifyModule (module-live-ptr m) 2 out)))]) ; 2 = return-status
      (let ([msg (base:cstring->string/dispose msg-ptr)])
        (base:check-bool 'ir:verify-module failed msg))))

  (define (set-module-target-triple! m triple)
    (LLVMSetTarget (module-live-ptr m) triple))

  (define (set-module-data-layout! m layout-string)
    (LLVMSetDataLayout (module-live-ptr m) layout-string))

  ;; Run new-pass-manager passes, e.g. (run-module-passes! m "default<O2>").
  (define (run-module-passes! m passes)
    (let ([opts (LLVMCreatePassBuilderOptions)])
      (let ([err (LLVMRunPasses (module-live-ptr m) passes base:null-ptr opts)])
        (LLVMDisposePassBuilderOptions opts)
        (base:check-error-ref 'ir:run-module-passes! err))))

  ;; Parse textual LLVM IR into a fresh module, using LLVM's own parser.
  ;; Raises with the parser's diagnostics on malformed IR.
  (define (parse-ir ctx name text)
    (let* ([bv (string->utf8 text)]
           [len (bytevector-length bv)]
           [buf (foreign-alloc (fxmax 1 len))])
      (do ([i 0 (fx+ i 1)])
          ((fx= i len))
        (foreign-set! 'unsigned-8 buf i (bytevector-u8-ref bv i)))
      (let ([membuf (LLVMCreateMemoryBufferWithMemoryRangeCopy buf len name)])
        (foreign-free buf)
        (let ([mod-out (foreign-alloc 8)])
          (foreign-set! 'unsigned-64 mod-out 0 0)
          ;; ParseIRInContext consumes membuf, success or not
          (let-values ([(failed msg-ptr)
                        (base:call-with-out-ptr
                          (lambda (err-out)
                            (LLVMParseIRInContext (context-live-ptr ctx)
                                                  membuf mod-out err-out)))])
            (let ([mp (foreign-ref 'unsigned-64 mod-out 0)])
              (foreign-free mod-out)
              (base:check-bool 'ir:parse-ir failed
                               (base:cstring->string/dispose msg-ptr))
              ($make-module mp ctx 'owned)))))))

  ;; ---- walking built IR ------------------------------------------------------

  (define (ptr-chain first next start)
    (let loop ([p (first start)] [acc '()])
      (if (base:null-ptr? p) (reverse acc) (loop (next p) (cons p acc)))))

  (define (module-functions m)
    (ptr-chain LLVMGetFirstFunction LLVMGetNextFunction (module-live-ptr m)))
  (define (function-blocks f)
    (ptr-chain LLVMGetFirstBasicBlock LLVMGetNextBasicBlock f))
  (define (block-instructions bb)
    (ptr-chain LLVMGetFirstInstruction LLVMGetNextInstruction bb))

  ;; raw LLVMOpcode / predicate enum values; interpretation is the caller's
  (define (instruction-opcode ins) (LLVMGetInstructionOpcode ins))
  (define (icmp-predicate ins) (LLVMGetICmpPredicate ins))
  (define (fcmp-predicate ins) (LLVMGetFCmpPredicate ins))

  ;; ---- builders -----------------------------------------------------------

  (define-record-type (builder $make-builder builder?)
    (fields ptr (mutable state))
    (nongenerative llvm-builder-v0))

  (define (make-builder ctx)
    ($make-builder (LLVMCreateBuilderInContext (context-live-ptr ctx)) 'owned))

  (define (builder-live-ptr b)
    (unless (eq? (builder-state b) 'owned)
      (base:error 'builder "builder is no longer live" (builder-state b)))
    (builder-ptr b))

  (define (builder-dispose! b)
    (when (eq? (builder-state b) 'owned)
      (LLVMDisposeBuilder (builder-ptr b))
      (builder-state-set! b 'disposed)))

  ;; ---- types ---------------------------------------------------------------

  (define (void-type ctx)   (LLVMVoidTypeInContext (context-live-ptr ctx)))
  (define (int1-type ctx)   (LLVMInt1TypeInContext (context-live-ptr ctx)))
  (define (int8-type ctx)   (LLVMInt8TypeInContext (context-live-ptr ctx)))
  (define (int16-type ctx)  (LLVMInt16TypeInContext (context-live-ptr ctx)))
  (define (int32-type ctx)  (LLVMInt32TypeInContext (context-live-ptr ctx)))
  (define (int64-type ctx)  (LLVMInt64TypeInContext (context-live-ptr ctx)))
  (define (int-type ctx bits) (LLVMIntTypeInContext (context-live-ptr ctx) bits))
  (define (float-type ctx)  (LLVMFloatTypeInContext (context-live-ptr ctx)))
  (define (double-type ctx) (LLVMDoubleTypeInContext (context-live-ptr ctx)))
  (define (half-type ctx)   (LLVMHalfTypeInContext (context-live-ptr ctx)))
  (define (bfloat-type ctx) (LLVMBFloatTypeInContext (context-live-ptr ctx)))
  (define (fp128-type ctx)  (LLVMFP128TypeInContext (context-live-ptr ctx)))
  (define (x86fp80-type ctx) (LLVMX86FP80TypeInContext (context-live-ptr ctx)))
  (define (ppcfp128-type ctx) (LLVMPPCFP128TypeInContext (context-live-ptr ctx)))

  (define pointer-type
    (case-lambda
      [(ctx) (pointer-type ctx 0)]
      [(ctx address-space)
       (LLVMPointerTypeInContext (context-live-ptr ctx) address-space)]))

  (define function-type
    (case-lambda
      [(ret params) (function-type ret params #f)]
      [(ret params vararg?)
       (base:call-with-pointer-array params
         (lambda (arr n) (LLVMFunctionType ret arr n (if vararg? 1 0))))]))

  (define struct-type
    (case-lambda
      [(ctx elems) (struct-type ctx elems #f)]
      [(ctx elems packed?)
       (base:call-with-pointer-array elems
         (lambda (arr n)
           (LLVMStructTypeInContext (context-live-ptr ctx) arr n
                                    (if packed? 1 0))))]))

  (define (array-type elem-type count) (LLVMArrayType2 elem-type count))

  (define (vector-type elem-type count) (LLVMVectorType elem-type count))

  (define (scalable-vector-type elem-type count)
    (LLVMScalableVectorType elem-type count))

  ;; named (identified) struct types, registered in the context by name
  (define (named-type ctx name)
    (let ([ty (LLVMGetTypeByName2 (context-live-ptr ctx) name)])
      (and (not (base:null-ptr? ty)) ty)))
  (define (create-named-struct ctx name)
    (LLVMStructCreateNamed (context-live-ptr ctx) name))
  (define (struct-set-body! ty elems packed?)
    (base:call-with-pointer-array elems
      (lambda (arr n) (LLVMStructSetBody ty arr n (if packed? 1 0)))))

  ;; Index order matches the LLVMTypeKind enum in llvm-c-19/Core.h.
  (define type-kinds
    '#(void half float double x86-fp80 fp128 ppc-fp128 label integer function
        struct array pointer vector metadata x86-mmx token scalable-vector
        bfloat x86-amx target-ext))

  (define (type-kind t)
    (let ([k (LLVMGetTypeKind t)])
      (if (fx< -1 k (vector-length type-kinds))
          (vector-ref type-kinds k)
          k)))

  (define (type-int-width t) (LLVMGetIntTypeWidth t))
  (define (type-return-type ft) (LLVMGetReturnType ft))
  (define (type-vararg? ft) (not (zero? (LLVMIsFunctionVarArg ft))))

  (define (type-param-types ft)
    (let* ([n (LLVMCountParamTypes ft)]
           [arr (foreign-alloc (fxmax 8 (fx* 8 n)))])
      (LLVMGetParamTypes ft arr)
      (let loop ([i (fx- n 1)] [acc '()])
        (if (fx< i 0)
            (begin (foreign-free arr) acc)
            (loop (fx- i 1)
                  (cons (foreign-ref 'unsigned-64 arr (fx* 8 i)) acc))))))

  (define (type->string t)
    (base:cstring->string/dispose (LLVMPrintTypeToString t)))

  ;; ---- functions / values ----------------------------------------------------

  (define (add-function m name ftype)
    (LLVMAddFunction (module-live-ptr m) name ftype))

  (define (named-function m name)
    (let ([f (LLVMGetNamedFunction (module-live-ptr m) name)])
      (and (not (base:null-ptr? f)) f)))

  ;; With opaque pointers, LLVMTypeOf on a function gives `ptr`; this gives
  ;; the actual function type.
  (define (function-type-of f) (LLVMGlobalGetValueType f))

  (define (function-param f i) (LLVMGetParam f i))

  (define (function-params f)
    (let ([n (LLVMCountParams f)])
      (let loop ([i (fx- n 1)] [acc '()])
        (if (fx< i 0) acc (loop (fx- i 1) (cons (LLVMGetParam f i) acc))))))

  (define (value-name v)
    (let-values ([(str-ptr len)
                  (base:call-with-out-ptr (lambda (out) (LLVMGetValueName2 v out)))])
      (base:cstring->string/len str-ptr len)))

  (define (set-value-name! v name)
    (LLVMSetValueName2 v name (bytevector-length (string->utf8 name))))

  (define (set-alignment! v bytes) (LLVMSetAlignment v bytes))

  ;; instruction flags: setters set the flag; getters return bitmasks/booleans
  (define (set-nsw! v) (LLVMSetNSW v 1))
  (define (set-nuw! v) (LLVMSetNUW v 1))
  (define (set-exact! v) (LLVMSetExact v 1))
  (define (set-nneg! v) (LLVMSetNNeg v 1))
  (define (set-disjoint! v) (LLVMSetIsDisjoint v 1))
  (define (set-volatile! v) (LLVMSetVolatile v 1))
  (define (set-fast-math-flags! v mask) (LLVMSetFastMathFlags v mask))
  (define (fast-math-flags v) (LLVMGetFastMathFlags v))
  (define (can-use-fast-math-flags? v)
    (not (zero? (LLVMCanValueUseFastMathFlags v))))
  (define (gep-no-wrap-flags v) (LLVMGEPGetNoWrapFlags v))

  (define (declaration? f) (not (zero? (LLVMIsDeclaration f))))

  (define (const-int ty n)
    (if (and (>= n (- (expt 2 63))) (< n (expt 2 64)))
        (LLVMConstInt ty (bitwise-and n #xFFFFFFFFFFFFFFFF) (if (< n 0) 1 0))
        ;; wider than the C API's uint64: go through decimal text
        (let ([s (number->string n)])
          (LLVMConstIntOfStringAndSize ty s (string-length s) 10))))

  (define (const-real ty x) (LLVMConstReal ty (inexact x)))
  (define (const-null ty) (LLVMConstNull ty))
  (define (undef-value ty) (LLVMGetUndef ty))
  (define (poison-value ty) (LLVMGetPoison ty))

  ;; scalars: a list of constant values, all of the same type
  (define (const-vector scalars)
    (base:call-with-pointer-array scalars
      (lambda (arr n) (LLVMConstVector arr n))))

  ;; the address of a (non-entry) basic block, as a ptr constant
  (define (block-address fn block) (LLVMBlockAddress fn block))

  (define (const-array elem-type constants)
    (base:call-with-pointer-array constants
      (lambda (arr n) (LLVMConstArray2 elem-type arr n))))

  ;; the name of an identified struct type, #f for literal structs
  (define (struct-name ty)
    (let ([s (base:cstring->string (LLVMGetStructName ty))])
      (and s (not (string=? s "")) s)))

  ;; ---- gc / module target strings ----------------------------------------

  (define (set-gc! f name) (LLVMSetGCString f name))
  (define (value-address-space v)   ; of a pointer-typed value
    (LLVMGetPointerAddressSpace (LLVMTypeOf v)))
  (define (set-atomic-single-thread! v) (LLVMSetAtomicSingleThread v 1))
  (define (set-externally-initialized! g) (LLVMSetExternallyInitialized g 1))
  (define (gc-name f) (base:cstring->string (LLVMGetGC f)))
  (define (set-target! m s) (LLVMSetTarget (module-live-ptr m) s))
  (define (set-data-layout! m s) (LLVMSetDataLayout (module-live-ptr m) s))

  ;; ---- operand bundles ------------------------------------------------------
  ;; created, passed to a bundle-aware builder (which copies them into
  ;; the instruction), then disposed by the caller

  (define (create-operand-bundle tag args)
    (base:call-with-pointer-array args
      (lambda (arr n)
        (LLVMCreateOperandBundle
          tag (bytevector-length (string->utf8 tag)) arr n))))
  (define (dispose-operand-bundle! b) (LLVMDisposeOperandBundle b))

  (define (build-call-bundles b fn-type fn args bundles name)
    (base:call-with-pointer-array args
      (lambda (aarr an)
        (base:call-with-pointer-array bundles
          (lambda (barr bn)
            (LLVMBuildCallWithOperandBundles
              (builder-live-ptr b) fn-type fn aarr an barr bn name))))))
  (define (build-invoke-bundles b fn-type fn args then-block unwind-block
                                bundles name)
    (base:call-with-pointer-array args
      (lambda (aarr an)
        (base:call-with-pointer-array bundles
          (lambda (barr bn)
            (LLVMBuildInvokeWithOperandBundles
              (builder-live-ptr b) fn-type fn aarr an then-block unwind-block
              barr bn name))))))

  ;; ---- metadata operands --------------------------------------------------
  ;; MetadataRef makers plus the Value wrapper for operand positions

  (define (metadata-type ctx)
    (LLVMMetadataTypeInContext (context-live-ptr ctx)))
  (define (md-string ctx s)   ; -> MetadataRef; the length is in BYTES
    (LLVMMDStringInContext2 (context-live-ptr ctx) s
                            (bytevector-length (string->utf8 s))))
  (define (md-node ctx mds)   ; MetadataRefs -> MetadataRef
    (base:call-with-pointer-array mds
      (lambda (arr n) (LLVMMDNodeInContext2 (context-live-ptr ctx) arr n))))
  (define (metadata-value ctx md)   ; MetadataRef -> ValueRef
    (LLVMMetadataAsValue2 (context-live-ptr ctx) md))

  ;; ---- global aliases ---------------------------------------------------

  (define (add-alias m value-ty aliasee name)
    (LLVMAddAlias2 (module-live-ptr m) value-ty 0 aliasee name))
  (define (alias-aliasee a) (LLVMAliasGetAliasee a))
  (define (alias-set-aliasee! a v) (LLVMAliasSetAliasee a v))
  (define (module-aliases m)
    (ptr-chain LLVMGetFirstGlobalAlias LLVMGetNextGlobalAlias
               (module-live-ptr m)))
  (define (add-ifunc m name fnty resolver)
    (LLVMAddGlobalIFunc (module-live-ptr m) name
                        (bytevector-length (string->utf8 name))
                        fnty 0 resolver))
  (define (ifunc-resolver i) (LLVMGetGlobalIFuncResolver i))
  (define (ifunc-set-resolver! i r) (LLVMSetGlobalIFuncResolver i r))
  (define (module-ifuncs m)
    (ptr-chain LLVMGetFirstGlobalIFunc LLVMGetNextGlobalIFunc
               (module-live-ptr m)))
  (define (set-module-asm! m s)
    (LLVMSetModuleInlineAsm2 (module-live-ptr m) s
                             (bytevector-length (string->utf8 s))))

  ;; ---- constant expressions -------------------------------------------
  ;; constructed via ConstantExpr::get, which folds symmetrically with
  ;; the parser (unlike the IRBuilder's instruction folding)

  (define (const-cast op v ty)
    ((case op
       [(trunc) LLVMConstTrunc]
       [(ptrtoint) LLVMConstPtrToInt]
       [(inttoptr) LLVMConstIntToPtr]
       [(bitcast) LLVMConstBitCast]
       [(addrspacecast) LLVMConstAddrSpaceCast]
       [else (base:error 'const-cast "not a constexpr cast opcode" op)])
     v ty))

  ;; the C API has no combined nuw+nsw constructors
  (define (const-binop op nuw? nsw? a b)
    ((case op
       [(add) (cond [nsw? LLVMConstNSWAdd] [nuw? LLVMConstNUWAdd]
                    [else LLVMConstAdd])]
       [(sub) (cond [nsw? LLVMConstNSWSub] [nuw? LLVMConstNUWSub]
                    [else LLVMConstSub])]
       [(mul) (cond [nsw? LLVMConstNSWMul] [nuw? LLVMConstNUWMul]
                    [else LLVMConstMul])]
       [(xor) LLVMConstXor]
       [else (base:error 'const-binop "not a constexpr binop opcode" op)])
     a b))

  (define (const-gep src-elem-ty ptr indices flags)
    (base:call-with-pointer-array indices
      (lambda (arr n)
        (LLVMConstGEPWithNoWrapFlags src-elem-ty ptr arr n flags))))

  (define (const-named-struct ty constants)
    (base:call-with-pointer-array constants
      (lambda (arr n) (LLVMConstNamedStruct ty arr n))))

  (define const-struct   ; literal (anonymous) struct constant
    (case-lambda
      [(ctx constants) (const-struct ctx constants #f)]
      [(ctx constants packed?)
       (base:call-with-pointer-array constants
         (lambda (arr n)
           (LLVMConstStructInContext (context-live-ptr ctx) arr n
                                     (if packed? 1 0))))]))

  (define (packed-struct-type? ty) (not (zero? (LLVMIsPackedStruct ty))))

  ;; bytes of s as an i8 array constant; null-terminate? adds the final \00
  (define (const-string ctx s null-terminate?)
    (LLVMConstStringInContext2 (context-live-ptr ctx) s
                               (bytevector-length (string->utf8 s))
                               (if null-terminate? 0 1)))

  ;; ---- module-level globals -------------------------------------------------

  (define add-global
    (case-lambda
      [(m ty name) (LLVMAddGlobal (module-live-ptr m) ty name)]
      [(m ty name addrspace)
       (LLVMAddGlobalInAddressSpace (module-live-ptr m) ty name addrspace)]))

  ;; a value's textual form, e.g. "i128 -5" (used for wide constants)
  (define (value->string v)
    (base:cstring->string/dispose (LLVMPrintValueToString v)))

  (define (set-initializer! g const) (LLVMSetInitializer g const))
  (define (set-global-constant! g) (LLVMSetGlobalConstant g 1))
  (define (set-linkage! g linkage-int) (LLVMSetLinkage g linkage-int))
  (define (linkage g) (LLVMGetLinkage g))

  (define (module-globals m)
    (ptr-chain LLVMGetFirstGlobal LLVMGetNextGlobal (module-live-ptr m)))

  ;; ---- basic blocks ------------------------------------------------------------

  (define (append-block ctx fn name)
    (LLVMAppendBasicBlockInContext (context-live-ptr ctx) fn name))

  (define (position-at-end! b block)
    (LLVMPositionBuilderAtEnd (builder-live-ptr b) block))

  (define (insert-block b) (LLVMGetInsertBlock (builder-live-ptr b)))

  ;; ---- instructions --------------------------------------------------------------

  (define (build-ret b v) (LLVMBuildRet (builder-live-ptr b) v))
  (define (build-ret-void b) (LLVMBuildRetVoid (builder-live-ptr b)))
  (define (build-br b block) (LLVMBuildBr (builder-live-ptr b) block))
  (define (build-cond-br b cond then-block else-block)
    (LLVMBuildCondBr (builder-live-ptr b) cond then-block else-block))

  (define (build-switch b v else-block ncases)
    (LLVMBuildSwitch (builder-live-ptr b) v else-block ncases))
  (define (add-case! switch on-const dest-block)
    (LLVMAddCase switch on-const dest-block))
  (define (build-indirect-br b addr ndests)
    (LLVMBuildIndirectBr (builder-live-ptr b) addr ndests))
  (define (add-destination! ibr dest-block)
    (LLVMAddDestination ibr dest-block))
  (define (build-unreachable b) (LLVMBuildUnreachable (builder-live-ptr b)))

  ;; ---- exception handling ---------------------------------------------------

  (define (build-invoke b fn-type fn args then-block unwind-block name)
    (base:call-with-pointer-array args
      (lambda (arr n)
        (LLVMBuildInvoke2 (builder-live-ptr b) fn-type fn arr n
                          then-block unwind-block name))))

  (define (build-resume b exn) (LLVMBuildResume (builder-live-ptr b) exn))

  (define (build-landingpad b ty nclauses name)
    (LLVMBuildLandingPad (builder-live-ptr b) ty base:null-ptr nclauses name))

  (define (add-clause! lp clause-const) (LLVMAddClause lp clause-const))
  (define (set-landingpad-cleanup! lp) (LLVMSetCleanup lp 1))
  (define (set-personality-fn! f pers) (LLVMSetPersonalityFn f pers))

  ;; unwind-block: #f = `unwind to caller`
  (define (build-catchswitch b parent-pad unwind-block nhandlers name)
    (LLVMBuildCatchSwitch (builder-live-ptr b) parent-pad
                          (or unwind-block base:null-ptr) nhandlers name))
  (define (add-handler! cs dest-block) (LLVMAddHandler cs dest-block))

  (define (build-catchpad b parent-pad args name)
    (base:call-with-pointer-array args
      (lambda (arr n)
        (LLVMBuildCatchPad (builder-live-ptr b) parent-pad arr n name))))
  (define (build-cleanuppad b parent-pad args name)
    (base:call-with-pointer-array args
      (lambda (arr n)
        (LLVMBuildCleanupPad (builder-live-ptr b) parent-pad arr n name))))

  (define (build-catchret b catchpad dest-block)
    (LLVMBuildCatchRet (builder-live-ptr b) catchpad dest-block))
  (define (build-cleanupret b cleanuppad unwind-block)
    (LLVMBuildCleanupRet (builder-live-ptr b) cleanuppad
                         (or unwind-block base:null-ptr)))

  (define (build-callbr b fn-type fn default-block indirect-blocks args name)
    (base:call-with-pointer-array indirect-blocks
      (lambda (dests ndests)
        (base:call-with-pointer-array args
          (lambda (arr n)
            (LLVMBuildCallBr (builder-live-ptr b) fn-type fn default-block
                             dests ndests arr n base:null-ptr 0 name))))))

  ;; a callable inline-asm value of the given function type
  (define (inline-asm fn-type asm-text constraints side-effects? align-stack?)
    (LLVMGetInlineAsm fn-type
                      asm-text (bytevector-length (string->utf8 asm-text))
                      constraints (bytevector-length (string->utf8 constraints))
                      (if side-effects? 1 0) (if align-stack? 1 0)
                      0    ; dialect: AT&T
                      0))  ; can-throw: no

  (define (token-type ctx) (LLVMTokenTypeInContext (context-live-ptr ctx)))

  (define build-freeze
    (case-lambda
      [(b v) (build-freeze b v "")]
      [(b v nm) (LLVMBuildFreeze (builder-live-ptr b) v nm)]))

  (define build-va-arg
    (case-lambda
      [(b va-list ty) (build-va-arg b va-list ty "")]
      [(b va-list ty nm) (LLVMBuildVAArg (builder-live-ptr b) va-list ty nm)]))

  (define build-extractelement
    (case-lambda
      [(b vec idx) (build-extractelement b vec idx "")]
      [(b vec idx nm) (LLVMBuildExtractElement (builder-live-ptr b) vec idx nm)]))
  (define build-insertelement
    (case-lambda
      [(b vec elt idx) (build-insertelement b vec elt idx "")]
      [(b vec elt idx nm)
       (LLVMBuildInsertElement (builder-live-ptr b) vec elt idx nm)]))
  (define build-shufflevector          ; mask: a constant vector of i32
    (case-lambda
      [(b v1 v2 mask) (build-shufflevector b v1 v2 mask "")]
      [(b v1 v2 mask nm)
       (LLVMBuildShuffleVector (builder-live-ptr b) v1 v2 mask nm)]))
  (define build-extractvalue
    (case-lambda
      [(b agg idx) (build-extractvalue b agg idx "")]
      [(b agg idx nm) (LLVMBuildExtractValue (builder-live-ptr b) agg idx nm)]))
  (define build-insertvalue
    (case-lambda
      [(b agg elt idx) (build-insertvalue b agg elt idx "")]
      [(b agg elt idx nm)
       (LLVMBuildInsertValue (builder-live-ptr b) agg elt idx nm)]))

  ;; atomics; ordering/rmw-op arguments are the C enum ints. The C builders
  ;; take no name, so we name the result afterwards.
  (define (build-fence b ordering)
    (LLVMBuildFence (builder-live-ptr b) ordering 0 ""))
  (define (build-atomicrmw b rmw-op ptr val ordering name)
    (let ([v (LLVMBuildAtomicRMW (builder-live-ptr b) rmw-op ptr val ordering 0)])
      (unless (string=? name "") (set-value-name! v name))
      v))
  (define (build-cmpxchg b ptr cmp new succ-ord fail-ord name)
    (let ([v (LLVMBuildAtomicCmpXchg (builder-live-ptr b) ptr cmp new
                                     succ-ord fail-ord 0)])
      (unless (string=? name "") (set-value-name! v name))
      v))

  (define (set-ordering! v ordering) (LLVMSetOrdering v ordering))
  (define (instruction-ordering v) (LLVMGetOrdering v))
  (define (set-weak! v) (LLVMSetWeak v 1))
  (define (atomicrmw-binop v) (LLVMGetAtomicRMWBinOp v))
  (define (cmpxchg-success-ordering v) (LLVMGetCmpXchgSuccessOrdering v))
  (define (cmpxchg-failure-ordering v) (LLVMGetCmpXchgFailureOrdering v))

  (define-syntax define-binop
    (syntax-rules ()
      [(_ name raw)
       (define name
         (case-lambda
           [(b x y) (name b x y "")]
           [(b x y nm) (raw (builder-live-ptr b) x y nm)]))]))

  (define-binop build-add LLVMBuildAdd)
  (define-binop build-sub LLVMBuildSub)
  (define-binop build-mul LLVMBuildMul)
  (define-binop build-sdiv LLVMBuildSDiv)
  (define-binop build-udiv LLVMBuildUDiv)
  (define-binop build-srem LLVMBuildSRem)
  (define-binop build-urem LLVMBuildURem)
  (define-binop build-and LLVMBuildAnd)
  (define-binop build-or LLVMBuildOr)
  (define-binop build-xor LLVMBuildXor)
  (define-binop build-shl LLVMBuildShl)
  (define-binop build-lshr LLVMBuildLShr)
  (define-binop build-ashr LLVMBuildAShr)
  (define-binop build-fadd LLVMBuildFAdd)
  (define-binop build-fsub LLVMBuildFSub)
  (define-binop build-fmul LLVMBuildFMul)
  (define-binop build-fdiv LLVMBuildFDiv)
  (define-binop build-frem LLVMBuildFRem)

  (define-syntax define-unop
    (syntax-rules ()
      [(_ name raw)
       (define name
         (case-lambda
           [(b x) (name b x "")]
           [(b x nm) (raw (builder-live-ptr b) x nm)]))]))

  (define-unop build-neg LLVMBuildNeg)
  (define-unop build-fneg LLVMBuildFNeg)
  (define-unop build-not LLVMBuildNot)

  ;; LLVMIntPredicate values from llvm-c-19/Core.h.
  (define (int-predicate->int pred)
    (case pred
      [(eq) 32] [(ne) 33]
      [(ugt) 34] [(uge) 35] [(ult) 36] [(ule) 37]
      [(sgt) 38] [(sge) 39] [(slt) 40] [(sle) 41]
      [else (base:error 'ir:build-icmp "unknown integer predicate" pred)]))

  ;; LLVMRealPredicate values from llvm-c-19/Core.h.
  (define (real-predicate->int pred)
    (case pred
      [(false) 0] [(oeq) 1] [(ogt) 2] [(oge) 3] [(olt) 4] [(ole) 5]
      [(one) 6] [(ord) 7] [(uno) 8] [(ueq) 9] [(ugt) 10] [(uge) 11]
      [(ult) 12] [(ule) 13] [(une) 14] [(true) 15]
      [else (base:error 'ir:build-fcmp "unknown real predicate" pred)]))

  (define build-icmp
    (case-lambda
      [(b pred x y) (build-icmp b pred x y "")]
      [(b pred x y nm)
       (LLVMBuildICmp (builder-live-ptr b) (int-predicate->int pred) x y nm)]))

  (define build-fcmp
    (case-lambda
      [(b pred x y) (build-fcmp b pred x y "")]
      [(b pred x y nm)
       (LLVMBuildFCmp (builder-live-ptr b) (real-predicate->int pred) x y nm)]))

  (define build-select
    (case-lambda
      [(b c t f) (build-select b c t f "")]
      [(b c t f nm) (LLVMBuildSelect (builder-live-ptr b) c t f nm)]))

  (define build-phi
    (case-lambda
      [(b ty) (build-phi b ty "")]
      [(b ty nm) (LLVMBuildPhi (builder-live-ptr b) ty nm)]))

  ;; incoming: list of (value . block) pairs.
  (define (phi-add-incoming! phi incoming)
    (base:call-with-pointer-array (map car incoming)
      (lambda (vals n)
        (base:call-with-pointer-array (map cdr incoming)
          (lambda (blocks n2)
            (LLVMAddIncoming phi vals blocks n))))))

  (define build-call
    (case-lambda
      [(b fn-type fn args) (build-call b fn-type fn args "")]
      [(b fn-type fn args nm)
       (base:call-with-pointer-array args
         (lambda (arr n)
           (LLVMBuildCall2 (builder-live-ptr b) fn-type fn arr n nm)))]))

  (define build-alloca
    (case-lambda
      [(b ty) (build-alloca b ty "")]
      [(b ty nm) (LLVMBuildAlloca (builder-live-ptr b) ty nm)]))

  (define build-array-alloca
    (case-lambda
      [(b ty count) (build-array-alloca b ty count "")]
      [(b ty count nm) (LLVMBuildArrayAlloca (builder-live-ptr b) ty count nm)]))

  ;; LLVMTailCallKind ints: 0 none, 1 tail, 2 musttail, 3 notail
  (define (set-tail-call-kind! call-inst kind) (LLVMSetTailCallKind call-inst kind))
  (define (tail-call-kind call-inst) (LLVMGetTailCallKind call-inst))

  ;; surgery used for forward-reference patching
  (define (replace-all-uses! old new) (LLVMReplaceAllUsesWith old new))
  (define (erase-instruction! inst) (LLVMInstructionEraseFromParent inst))
  (define (delete-block! bb) (LLVMDeleteBasicBlock bb))

  (define build-load
    (case-lambda
      [(b ty ptr) (build-load b ty ptr "")]
      [(b ty ptr nm) (LLVMBuildLoad2 (builder-live-ptr b) ty ptr nm)]))

  (define (build-store b v ptr)
    (LLVMBuildStore (builder-live-ptr b) v ptr))

  (define build-gep
    (case-lambda
      [(b elem-ty ptr indices) (build-gep b elem-ty ptr indices "")]
      [(b elem-ty ptr indices nm)
       (base:call-with-pointer-array indices
         (lambda (arr n)
           (LLVMBuildGEP2 (builder-live-ptr b) elem-ty ptr arr n nm)))]))

  ;; flags: LLVMGEPNoWrapFlags bitmask (inbounds/nusw/nuw)
  (define build-gep/flags
    (case-lambda
      [(b elem-ty ptr indices flags) (build-gep/flags b elem-ty ptr indices flags "")]
      [(b elem-ty ptr indices flags nm)
       (base:call-with-pointer-array indices
         (lambda (arr n)
           (LLVMBuildGEPWithNoWrapFlags (builder-live-ptr b)
                                        elem-ty ptr arr n nm flags)))]))

  (define-syntax define-cast
    (syntax-rules ()
      [(_ name raw)
       (define name
         (case-lambda
           [(b v ty) (name b v ty "")]
           [(b v ty nm) (raw (builder-live-ptr b) v ty nm)]))]))

  (define-cast build-trunc LLVMBuildTrunc)
  (define-cast build-zext LLVMBuildZExt)
  (define-cast build-sext LLVMBuildSExt)
  (define-cast build-si->fp LLVMBuildSIToFP)
  (define-cast build-ui->fp LLVMBuildUIToFP)
  (define-cast build-fp->si LLVMBuildFPToSI)
  (define-cast build-fp->ui LLVMBuildFPToUI)
  (define-cast build-fptrunc LLVMBuildFPTrunc)
  (define-cast build-fpext LLVMBuildFPExt)
  (define-cast build-ptr->int LLVMBuildPtrToInt)
  (define-cast build-int->ptr LLVMBuildIntToPtr)
  (define-cast build-bitcast LLVMBuildBitCast)
  (define-cast build-addrspacecast LLVMBuildAddrSpaceCast))
