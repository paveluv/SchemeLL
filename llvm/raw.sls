;;; (llvm raw) -- layer 0: 1:1 foreign-procedure bindings to the LLVM 19 C API.
;;;
;;; Conventions (see project/RULES.md):
;;;   LLVM*Ref            -> void*        (exact integer address, 0 = NULL)
;;;   const char* (in)    -> string
;;;   char* (caller frees)-> void*        (convert with cstring->string/dispose)
;;;   LLVMBool, enums     -> int
;;;   unsigned            -> unsigned-int
;;;   uint64_t            -> unsigned-64
;;;   size_t              -> size_t
;;;   out-params, arrays  -> void*        (foreign-alloc'd memory)
;;;
;;; Definitions drop the leading "LLVM"; the canonical import is
;;;   (prefix (llvm raw) LLVM)
;;; which reconstructs the exact C names at call sites (LLVMBuildAdd, ...),
;;; so the headers at /usr/include/llvm-c-19/llvm-c/ read side by side with
;;; calling code. The foreign-procedure entry strings keep the full C names,
;;; so grepping for a C name still finds this file. No logic in this file.
(library (llvm raw)
  (export
    ;; Core: context / module / builder lifecycle
    ContextCreate ContextDispose
    ModuleCreateWithNameInContext DisposeModule
    SetTarget SetDataLayout
    PrintModuleToString DisposeMessage
    CreateBuilderInContext DisposeBuilder
    ;; Core: types
    VoidTypeInContext
    Int1TypeInContext Int8TypeInContext Int16TypeInContext
    Int32TypeInContext Int64TypeInContext IntTypeInContext
    FloatTypeInContext DoubleTypeInContext
    PointerTypeInContext
    FunctionType StructTypeInContext ArrayType2
    GetTypeKind GetIntTypeWidth
    GetReturnType CountParamTypes GetParamTypes IsFunctionVarArg
    PrintTypeToString TypeOf GlobalGetValueType
    ;; Core: functions and values
    AddFunction GetNamedFunction
    GetParam CountParams
    GetFirstFunction GetNextFunction
    GetValueName2 IsDeclaration
    SetLinkage SetFunctionCallConv
    ;; Core: constants
    ConstInt ConstReal ConstNull ConstPointerNull GetUndef
    ;; Core: basic blocks
    AppendBasicBlockInContext GetInsertBlock PositionBuilderAtEnd
    ;; Core: instruction building
    BuildRet BuildRetVoid BuildBr BuildCondBr
    BuildAdd BuildSub BuildMul
    BuildSDiv BuildUDiv BuildSRem BuildURem
    BuildAnd BuildOr BuildXor
    BuildShl BuildLShr BuildAShr
    BuildFAdd BuildFSub BuildFMul BuildFDiv
    BuildNeg BuildFNeg BuildNot
    BuildICmp BuildFCmp BuildSelect
    BuildPhi AddIncoming
    BuildCall2
    BuildAlloca BuildLoad2 BuildStore BuildGEP2
    BuildTrunc BuildZExt BuildSExt
    BuildSIToFP BuildUIToFP BuildFPToSI BuildFPToUI
    BuildFPTrunc BuildFPExt
    BuildPtrToInt BuildIntToPtr BuildBitCast
    ;; Analysis
    VerifyModule VerifyFunction
    ;; Error.h
    GetErrorMessage DisposeErrorMessage ConsumeError
    ;; TargetMachine.h / Target.h
    GetDefaultTargetTriple GetHostCPUName GetHostCPUFeatures
    GetTargetFromTriple
    CreateTargetMachine DisposeTargetMachine
    TargetMachineEmitToFile TargetMachineEmitToMemoryBuffer
    CreateTargetDataLayout CopyStringRepOfTargetData DisposeTargetData
    GetBufferStart GetBufferSize DisposeMemoryBuffer
    ;; Transforms/PassBuilder.h (new pass manager)
    RunPasses CreatePassBuilderOptions DisposePassBuilderOptions
    ;; Orc.h / LLJIT.h
    OrcCreateNewThreadSafeContext OrcThreadSafeContextGetContext
    OrcDisposeThreadSafeContext
    OrcCreateNewThreadSafeModule OrcDisposeThreadSafeModule
    OrcCreateLLJITBuilder OrcDisposeLLJITBuilder
    OrcCreateLLJIT OrcDisposeLLJIT
    OrcLLJITGetMainJITDylib OrcLLJITAddLLVMIRModule OrcLLJITLookup)
  (import (chezscheme) (prefix (llvm config) config:))

  ;; Must run before any foreign-procedure below is evaluated.
  (define llvm-loaded (config:load!))

  ;; --- Core: context / module / builder ---------------------------------
  (define ContextCreate
    (foreign-procedure "LLVMContextCreate" () void*))
  (define ContextDispose
    (foreign-procedure "LLVMContextDispose" (void*) void))
  (define ModuleCreateWithNameInContext
    (foreign-procedure "LLVMModuleCreateWithNameInContext" (string void*) void*))
  (define DisposeModule
    (foreign-procedure "LLVMDisposeModule" (void*) void))
  (define SetTarget
    (foreign-procedure "LLVMSetTarget" (void* string) void))
  (define SetDataLayout
    (foreign-procedure "LLVMSetDataLayout" (void* string) void))
  (define PrintModuleToString          ; returns char*, dispose!
    (foreign-procedure "LLVMPrintModuleToString" (void*) void*))
  (define DisposeMessage
    (foreign-procedure "LLVMDisposeMessage" (void*) void))
  (define CreateBuilderInContext
    (foreign-procedure "LLVMCreateBuilderInContext" (void*) void*))
  (define DisposeBuilder
    (foreign-procedure "LLVMDisposeBuilder" (void*) void))

  ;; --- Core: types --------------------------------------------------------
  (define VoidTypeInContext
    (foreign-procedure "LLVMVoidTypeInContext" (void*) void*))
  (define Int1TypeInContext
    (foreign-procedure "LLVMInt1TypeInContext" (void*) void*))
  (define Int8TypeInContext
    (foreign-procedure "LLVMInt8TypeInContext" (void*) void*))
  (define Int16TypeInContext
    (foreign-procedure "LLVMInt16TypeInContext" (void*) void*))
  (define Int32TypeInContext
    (foreign-procedure "LLVMInt32TypeInContext" (void*) void*))
  (define Int64TypeInContext
    (foreign-procedure "LLVMInt64TypeInContext" (void*) void*))
  (define IntTypeInContext
    (foreign-procedure "LLVMIntTypeInContext" (void* unsigned-int) void*))
  (define FloatTypeInContext
    (foreign-procedure "LLVMFloatTypeInContext" (void*) void*))
  (define DoubleTypeInContext
    (foreign-procedure "LLVMDoubleTypeInContext" (void*) void*))
  (define PointerTypeInContext         ; (ctx, address-space)
    (foreign-procedure "LLVMPointerTypeInContext" (void* unsigned-int) void*))
  (define FunctionType                 ; (ret, param-array, count, vararg?)
    (foreign-procedure "LLVMFunctionType" (void* void* unsigned-int int) void*))
  (define StructTypeInContext          ; (ctx, elem-array, count, packed?)
    (foreign-procedure "LLVMStructTypeInContext" (void* void* unsigned-int int) void*))
  (define ArrayType2                   ; (elem-type, count)
    (foreign-procedure "LLVMArrayType2" (void* unsigned-64) void*))
  (define GetTypeKind
    (foreign-procedure "LLVMGetTypeKind" (void*) int))
  (define GetIntTypeWidth
    (foreign-procedure "LLVMGetIntTypeWidth" (void*) unsigned-int))
  (define GetReturnType
    (foreign-procedure "LLVMGetReturnType" (void*) void*))
  (define CountParamTypes
    (foreign-procedure "LLVMCountParamTypes" (void*) unsigned-int))
  (define GetParamTypes                ; (fn-type, dest-array)
    (foreign-procedure "LLVMGetParamTypes" (void* void*) void))
  (define IsFunctionVarArg
    (foreign-procedure "LLVMIsFunctionVarArg" (void*) int))
  (define PrintTypeToString            ; returns char*, dispose!
    (foreign-procedure "LLVMPrintTypeToString" (void*) void*))
  (define TypeOf
    (foreign-procedure "LLVMTypeOf" (void*) void*))
  (define GlobalGetValueType           ; function type of a fn (opaque ptrs!)
    (foreign-procedure "LLVMGlobalGetValueType" (void*) void*))

  ;; --- Core: functions and values ----------------------------------------
  (define AddFunction
    (foreign-procedure "LLVMAddFunction" (void* string void*) void*))
  (define GetNamedFunction
    (foreign-procedure "LLVMGetNamedFunction" (void* string) void*))
  (define GetParam
    (foreign-procedure "LLVMGetParam" (void* unsigned-int) void*))
  (define CountParams
    (foreign-procedure "LLVMCountParams" (void*) unsigned-int))
  (define GetFirstFunction
    (foreign-procedure "LLVMGetFirstFunction" (void*) void*))
  (define GetNextFunction
    (foreign-procedure "LLVMGetNextFunction" (void*) void*))
  (define GetValueName2                ; (value, size_t* out-len) -> const char* (borrowed)
    (foreign-procedure "LLVMGetValueName2" (void* void*) void*))
  (define IsDeclaration
    (foreign-procedure "LLVMIsDeclaration" (void*) int))
  (define SetLinkage
    (foreign-procedure "LLVMSetLinkage" (void* int) void))
  (define SetFunctionCallConv
    (foreign-procedure "LLVMSetFunctionCallConv" (void* unsigned-int) void))

  ;; --- Core: constants ----------------------------------------------------
  (define ConstInt                     ; (type, value, sign-extend?)
    (foreign-procedure "LLVMConstInt" (void* unsigned-64 int) void*))
  (define ConstReal
    (foreign-procedure "LLVMConstReal" (void* double) void*))
  (define ConstNull
    (foreign-procedure "LLVMConstNull" (void*) void*))
  (define ConstPointerNull
    (foreign-procedure "LLVMConstPointerNull" (void*) void*))
  (define GetUndef
    (foreign-procedure "LLVMGetUndef" (void*) void*))

  ;; --- Core: basic blocks --------------------------------------------------
  (define AppendBasicBlockInContext
    (foreign-procedure "LLVMAppendBasicBlockInContext" (void* void* string) void*))
  (define GetInsertBlock
    (foreign-procedure "LLVMGetInsertBlock" (void*) void*))
  (define PositionBuilderAtEnd
    (foreign-procedure "LLVMPositionBuilderAtEnd" (void* void*) void))

  ;; --- Core: instruction building ------------------------------------------
  (define BuildRet
    (foreign-procedure "LLVMBuildRet" (void* void*) void*))
  (define BuildRetVoid
    (foreign-procedure "LLVMBuildRetVoid" (void*) void*))
  (define BuildBr
    (foreign-procedure "LLVMBuildBr" (void* void*) void*))
  (define BuildCondBr
    (foreign-procedure "LLVMBuildCondBr" (void* void* void* void*) void*))

  (define BuildAdd
    (foreign-procedure "LLVMBuildAdd" (void* void* void* string) void*))
  (define BuildSub
    (foreign-procedure "LLVMBuildSub" (void* void* void* string) void*))
  (define BuildMul
    (foreign-procedure "LLVMBuildMul" (void* void* void* string) void*))
  (define BuildSDiv
    (foreign-procedure "LLVMBuildSDiv" (void* void* void* string) void*))
  (define BuildUDiv
    (foreign-procedure "LLVMBuildUDiv" (void* void* void* string) void*))
  (define BuildSRem
    (foreign-procedure "LLVMBuildSRem" (void* void* void* string) void*))
  (define BuildURem
    (foreign-procedure "LLVMBuildURem" (void* void* void* string) void*))
  (define BuildAnd
    (foreign-procedure "LLVMBuildAnd" (void* void* void* string) void*))
  (define BuildOr
    (foreign-procedure "LLVMBuildOr" (void* void* void* string) void*))
  (define BuildXor
    (foreign-procedure "LLVMBuildXor" (void* void* void* string) void*))
  (define BuildShl
    (foreign-procedure "LLVMBuildShl" (void* void* void* string) void*))
  (define BuildLShr
    (foreign-procedure "LLVMBuildLShr" (void* void* void* string) void*))
  (define BuildAShr
    (foreign-procedure "LLVMBuildAShr" (void* void* void* string) void*))
  (define BuildFAdd
    (foreign-procedure "LLVMBuildFAdd" (void* void* void* string) void*))
  (define BuildFSub
    (foreign-procedure "LLVMBuildFSub" (void* void* void* string) void*))
  (define BuildFMul
    (foreign-procedure "LLVMBuildFMul" (void* void* void* string) void*))
  (define BuildFDiv
    (foreign-procedure "LLVMBuildFDiv" (void* void* void* string) void*))
  (define BuildNeg
    (foreign-procedure "LLVMBuildNeg" (void* void* string) void*))
  (define BuildFNeg
    (foreign-procedure "LLVMBuildFNeg" (void* void* string) void*))
  (define BuildNot
    (foreign-procedure "LLVMBuildNot" (void* void* string) void*))

  (define BuildICmp                    ; (builder, predicate, lhs, rhs, name)
    (foreign-procedure "LLVMBuildICmp" (void* int void* void* string) void*))
  (define BuildFCmp
    (foreign-procedure "LLVMBuildFCmp" (void* int void* void* string) void*))
  (define BuildSelect
    (foreign-procedure "LLVMBuildSelect" (void* void* void* void* string) void*))
  (define BuildPhi
    (foreign-procedure "LLVMBuildPhi" (void* void* string) void*))
  (define AddIncoming                  ; (phi, value-array, block-array, count)
    (foreign-procedure "LLVMAddIncoming" (void* void* void* unsigned-int) void))
  (define BuildCall2                   ; (builder, fn-type, fn, arg-array, count, name)
    (foreign-procedure "LLVMBuildCall2" (void* void* void* void* unsigned-int string) void*))
  (define BuildAlloca
    (foreign-procedure "LLVMBuildAlloca" (void* void* string) void*))
  (define BuildLoad2                   ; (builder, elem-type, ptr, name)
    (foreign-procedure "LLVMBuildLoad2" (void* void* void* string) void*))
  (define BuildStore
    (foreign-procedure "LLVMBuildStore" (void* void* void*) void*))
  (define BuildGEP2                    ; (builder, elem-type, ptr, index-array, count, name)
    (foreign-procedure "LLVMBuildGEP2" (void* void* void* void* unsigned-int string) void*))

  (define BuildTrunc
    (foreign-procedure "LLVMBuildTrunc" (void* void* void* string) void*))
  (define BuildZExt
    (foreign-procedure "LLVMBuildZExt" (void* void* void* string) void*))
  (define BuildSExt
    (foreign-procedure "LLVMBuildSExt" (void* void* void* string) void*))
  (define BuildSIToFP
    (foreign-procedure "LLVMBuildSIToFP" (void* void* void* string) void*))
  (define BuildUIToFP
    (foreign-procedure "LLVMBuildUIToFP" (void* void* void* string) void*))
  (define BuildFPToSI
    (foreign-procedure "LLVMBuildFPToSI" (void* void* void* string) void*))
  (define BuildFPToUI
    (foreign-procedure "LLVMBuildFPToUI" (void* void* void* string) void*))
  (define BuildFPTrunc
    (foreign-procedure "LLVMBuildFPTrunc" (void* void* void* string) void*))
  (define BuildFPExt
    (foreign-procedure "LLVMBuildFPExt" (void* void* void* string) void*))
  (define BuildPtrToInt
    (foreign-procedure "LLVMBuildPtrToInt" (void* void* void* string) void*))
  (define BuildIntToPtr
    (foreign-procedure "LLVMBuildIntToPtr" (void* void* void* string) void*))
  (define BuildBitCast
    (foreign-procedure "LLVMBuildBitCast" (void* void* void* string) void*))

  ;; --- Analysis.h -----------------------------------------------------------
  ;; action: 0 = abort-process, 1 = print-message, 2 = return-status
  (define VerifyModule                 ; (module, action, char** out-msg) -> bool (true = broken)
    (foreign-procedure "LLVMVerifyModule" (void* int void*) int))
  (define VerifyFunction
    (foreign-procedure "LLVMVerifyFunction" (void* int) int))

  ;; --- Error.h ---------------------------------------------------------------
  (define GetErrorMessage              ; consumes the error, returns char* (dispose-error-message!)
    (foreign-procedure "LLVMGetErrorMessage" (void*) void*))
  (define DisposeErrorMessage
    (foreign-procedure "LLVMDisposeErrorMessage" (void*) void))
  (define ConsumeError
    (foreign-procedure "LLVMConsumeError" (void*) void))

  ;; --- Target.h / TargetMachine.h ----------------------------------------------
  (define GetDefaultTargetTriple       ; char*, dispose!
    (foreign-procedure "LLVMGetDefaultTargetTriple" () void*))
  (define GetHostCPUName               ; char*, dispose!
    (foreign-procedure "LLVMGetHostCPUName" () void*))
  (define GetHostCPUFeatures           ; char*, dispose!
    (foreign-procedure "LLVMGetHostCPUFeatures" () void*))
  (define GetTargetFromTriple          ; (triple, target*, char** err) -> bool (true = failed)
    (foreign-procedure "LLVMGetTargetFromTriple" (string void* void*) int))
  (define CreateTargetMachine          ; (target, triple, cpu, features, opt, reloc, code-model)
    (foreign-procedure "LLVMCreateTargetMachine"
                       (void* string string string int int int) void*))
  (define DisposeTargetMachine
    (foreign-procedure "LLVMDisposeTargetMachine" (void*) void))
  ;; file-type: 0 = assembly, 1 = object
  (define TargetMachineEmitToFile      ; (tm, module, path, file-type, char** err) -> bool (true = failed)
    (foreign-procedure "LLVMTargetMachineEmitToFile" (void* void* string int void*) int))
  (define TargetMachineEmitToMemoryBuffer ; (tm, module, file-type, char** err, membuf* out)
    (foreign-procedure "LLVMTargetMachineEmitToMemoryBuffer" (void* void* int void* void*) int))
  (define CreateTargetDataLayout
    (foreign-procedure "LLVMCreateTargetDataLayout" (void*) void*))
  (define CopyStringRepOfTargetData    ; char*, dispose!
    (foreign-procedure "LLVMCopyStringRepOfTargetData" (void*) void*))
  (define DisposeTargetData
    (foreign-procedure "LLVMDisposeTargetData" (void*) void))
  (define GetBufferStart
    (foreign-procedure "LLVMGetBufferStart" (void*) void*))
  (define GetBufferSize
    (foreign-procedure "LLVMGetBufferSize" (void*) size_t))
  (define DisposeMemoryBuffer
    (foreign-procedure "LLVMDisposeMemoryBuffer" (void*) void))

  ;; --- Transforms/PassBuilder.h ------------------------------------------------
  (define RunPasses                    ; (module, passes-string, tm-or-null, options) -> LLVMErrorRef
    (foreign-procedure "LLVMRunPasses" (void* string void* void*) void*))
  (define CreatePassBuilderOptions
    (foreign-procedure "LLVMCreatePassBuilderOptions" () void*))
  (define DisposePassBuilderOptions
    (foreign-procedure "LLVMDisposePassBuilderOptions" (void*) void))

  ;; --- Orc.h / LLJIT.h -----------------------------------------------------------
  (define OrcCreateNewThreadSafeContext
    (foreign-procedure "LLVMOrcCreateNewThreadSafeContext" () void*))
  (define OrcThreadSafeContextGetContext
    (foreign-procedure "LLVMOrcThreadSafeContextGetContext" (void*) void*))
  (define OrcDisposeThreadSafeContext
    (foreign-procedure "LLVMOrcDisposeThreadSafeContext" (void*) void))
  (define OrcCreateNewThreadSafeModule ; consumes module; tsctx stays ours
    (foreign-procedure "LLVMOrcCreateNewThreadSafeModule" (void* void*) void*))
  (define OrcDisposeThreadSafeModule   ; only if NOT handed to the JIT
    (foreign-procedure "LLVMOrcDisposeThreadSafeModule" (void*) void))
  (define OrcCreateLLJITBuilder
    (foreign-procedure "LLVMOrcCreateLLJITBuilder" () void*))
  (define OrcDisposeLLJITBuilder
    (foreign-procedure "LLVMOrcDisposeLLJITBuilder" (void*) void))
  (define OrcCreateLLJIT               ; (LLJIT* out, builder-or-null) -> LLVMErrorRef
    (foreign-procedure "LLVMOrcCreateLLJIT" (void* void*) void*))
  (define OrcDisposeLLJIT              ; -> LLVMErrorRef
    (foreign-procedure "LLVMOrcDisposeLLJIT" (void*) void*))
  (define OrcLLJITGetMainJITDylib
    (foreign-procedure "LLVMOrcLLJITGetMainJITDylib" (void*) void*))
  (define OrcLLJITAddLLVMIRModule      ; consumes TSM even on error -> LLVMErrorRef
    (foreign-procedure "LLVMOrcLLJITAddLLVMIRModule" (void* void* void*) void*))
  (define OrcLLJITLookup               ; (jit, uint64* out-addr, name) -> LLVMErrorRef
    (foreign-procedure "LLVMOrcLLJITLookup" (void* void* string) void*)))
