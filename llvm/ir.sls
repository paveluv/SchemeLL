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
    run-module-passes!
    ;; builders
    builder? make-builder builder-dispose! builder-live-ptr
    ;; types
    void-type int-type int1-type int8-type int16-type int32-type int64-type
    float-type double-type pointer-type function-type struct-type array-type
    type-kind type-int-width type-return-type type-param-types type-vararg?
    type->string
    ;; functions / values
    add-function named-function function-type-of
    function-param function-params value-name set-value-name! declaration?
    set-alignment!
    const-int const-real const-null undef-value
    ;; basic blocks / positioning
    append-block position-at-end! insert-block
    ;; instructions
    build-ret build-ret-void build-br build-cond-br
    build-add build-sub build-mul build-sdiv build-udiv build-srem build-urem
    build-and build-or build-xor build-shl build-lshr build-ashr
    build-fadd build-fsub build-fmul build-fdiv build-frem
    build-neg build-fneg build-not
    build-icmp build-fcmp build-select
    build-phi phi-add-incoming!
    build-call build-alloca build-load build-store build-gep
    build-trunc build-zext build-sext
    build-si->fp build-ui->fp build-fp->si build-fp->ui
    build-fptrunc build-fpext build-ptr->int build-int->ptr build-bitcast)
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

  (define (declaration? f) (not (zero? (LLVMIsDeclaration f))))

  (define (const-int ty n)
    (LLVMConstInt ty (bitwise-and n #xFFFFFFFFFFFFFFFF) (if (< n 0) 1 0)))

  (define (const-real ty x) (LLVMConstReal ty (inexact x)))
  (define (const-null ty) (LLVMConstNull ty))
  (define (undef-value ty) (LLVMGetUndef ty))

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
  (define-cast build-bitcast LLVMBuildBitCast))
