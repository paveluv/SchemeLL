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
;;; No logic in this file: names are the exact C names so the headers at
;;; /usr/include/llvm-c-19/llvm-c/ read side by side with this code.
(library (llvm raw)
  (export
   ;; Core: context / module / builder lifecycle
   LLVMContextCreate LLVMContextDispose
   LLVMModuleCreateWithNameInContext LLVMDisposeModule
   LLVMSetTarget LLVMSetDataLayout
   LLVMPrintModuleToString LLVMDisposeMessage
   LLVMCreateBuilderInContext LLVMDisposeBuilder
   ;; Core: types
   LLVMVoidTypeInContext
   LLVMInt1TypeInContext LLVMInt8TypeInContext LLVMInt16TypeInContext
   LLVMInt32TypeInContext LLVMInt64TypeInContext LLVMIntTypeInContext
   LLVMFloatTypeInContext LLVMDoubleTypeInContext
   LLVMPointerTypeInContext
   LLVMFunctionType LLVMStructTypeInContext LLVMArrayType2
   LLVMGetTypeKind LLVMGetIntTypeWidth
   LLVMGetReturnType LLVMCountParamTypes LLVMGetParamTypes LLVMIsFunctionVarArg
   LLVMPrintTypeToString LLVMTypeOf LLVMGlobalGetValueType
   ;; Core: functions and values
   LLVMAddFunction LLVMGetNamedFunction
   LLVMGetParam LLVMCountParams
   LLVMGetFirstFunction LLVMGetNextFunction
   LLVMGetValueName2 LLVMIsDeclaration
   LLVMSetLinkage LLVMSetFunctionCallConv
   ;; Core: constants
   LLVMConstInt LLVMConstReal LLVMConstNull LLVMConstPointerNull LLVMGetUndef
   ;; Core: basic blocks
   LLVMAppendBasicBlockInContext LLVMGetInsertBlock LLVMPositionBuilderAtEnd
   ;; Core: instruction building
   LLVMBuildRet LLVMBuildRetVoid LLVMBuildBr LLVMBuildCondBr
   LLVMBuildAdd LLVMBuildSub LLVMBuildMul
   LLVMBuildSDiv LLVMBuildUDiv LLVMBuildSRem LLVMBuildURem
   LLVMBuildAnd LLVMBuildOr LLVMBuildXor
   LLVMBuildShl LLVMBuildLShr LLVMBuildAShr
   LLVMBuildFAdd LLVMBuildFSub LLVMBuildFMul LLVMBuildFDiv
   LLVMBuildNeg LLVMBuildFNeg LLVMBuildNot
   LLVMBuildICmp LLVMBuildFCmp LLVMBuildSelect
   LLVMBuildPhi LLVMAddIncoming
   LLVMBuildCall2
   LLVMBuildAlloca LLVMBuildLoad2 LLVMBuildStore LLVMBuildGEP2
   LLVMBuildTrunc LLVMBuildZExt LLVMBuildSExt
   LLVMBuildSIToFP LLVMBuildUIToFP LLVMBuildFPToSI LLVMBuildFPToUI
   LLVMBuildFPTrunc LLVMBuildFPExt
   LLVMBuildPtrToInt LLVMBuildIntToPtr LLVMBuildBitCast
   ;; Analysis
   LLVMVerifyModule LLVMVerifyFunction
   ;; Error.h
   LLVMGetErrorMessage LLVMDisposeErrorMessage LLVMConsumeError
   ;; TargetMachine.h / Target.h
   LLVMGetDefaultTargetTriple LLVMGetHostCPUName LLVMGetHostCPUFeatures
   LLVMGetTargetFromTriple
   LLVMCreateTargetMachine LLVMDisposeTargetMachine
   LLVMTargetMachineEmitToFile LLVMTargetMachineEmitToMemoryBuffer
   LLVMCreateTargetDataLayout LLVMCopyStringRepOfTargetData LLVMDisposeTargetData
   LLVMGetBufferStart LLVMGetBufferSize LLVMDisposeMemoryBuffer
   ;; Transforms/PassBuilder.h (new pass manager)
   LLVMRunPasses LLVMCreatePassBuilderOptions LLVMDisposePassBuilderOptions
   ;; Orc.h / LLJIT.h
   LLVMOrcCreateNewThreadSafeContext LLVMOrcThreadSafeContextGetContext
   LLVMOrcDisposeThreadSafeContext
   LLVMOrcCreateNewThreadSafeModule LLVMOrcDisposeThreadSafeModule
   LLVMOrcCreateLLJITBuilder LLVMOrcDisposeLLJITBuilder
   LLVMOrcCreateLLJIT LLVMOrcDisposeLLJIT
   LLVMOrcLLJITGetMainJITDylib LLVMOrcLLJITAddLLVMIRModule LLVMOrcLLJITLookup)
  (import (chezscheme) (llvm config))

  ;; Must run before any foreign-procedure below is evaluated.
  (define llvm-loaded (load-llvm!))

  ;; --- Core: context / module / builder ---------------------------------
  (define LLVMContextCreate
    (foreign-procedure "LLVMContextCreate" () void*))
  (define LLVMContextDispose
    (foreign-procedure "LLVMContextDispose" (void*) void))
  (define LLVMModuleCreateWithNameInContext
    (foreign-procedure "LLVMModuleCreateWithNameInContext" (string void*) void*))
  (define LLVMDisposeModule
    (foreign-procedure "LLVMDisposeModule" (void*) void))
  (define LLVMSetTarget
    (foreign-procedure "LLVMSetTarget" (void* string) void))
  (define LLVMSetDataLayout
    (foreign-procedure "LLVMSetDataLayout" (void* string) void))
  (define LLVMPrintModuleToString          ; returns char*, dispose!
    (foreign-procedure "LLVMPrintModuleToString" (void*) void*))
  (define LLVMDisposeMessage
    (foreign-procedure "LLVMDisposeMessage" (void*) void))
  (define LLVMCreateBuilderInContext
    (foreign-procedure "LLVMCreateBuilderInContext" (void*) void*))
  (define LLVMDisposeBuilder
    (foreign-procedure "LLVMDisposeBuilder" (void*) void))

  ;; --- Core: types --------------------------------------------------------
  (define LLVMVoidTypeInContext
    (foreign-procedure "LLVMVoidTypeInContext" (void*) void*))
  (define LLVMInt1TypeInContext
    (foreign-procedure "LLVMInt1TypeInContext" (void*) void*))
  (define LLVMInt8TypeInContext
    (foreign-procedure "LLVMInt8TypeInContext" (void*) void*))
  (define LLVMInt16TypeInContext
    (foreign-procedure "LLVMInt16TypeInContext" (void*) void*))
  (define LLVMInt32TypeInContext
    (foreign-procedure "LLVMInt32TypeInContext" (void*) void*))
  (define LLVMInt64TypeInContext
    (foreign-procedure "LLVMInt64TypeInContext" (void*) void*))
  (define LLVMIntTypeInContext
    (foreign-procedure "LLVMIntTypeInContext" (void* unsigned-int) void*))
  (define LLVMFloatTypeInContext
    (foreign-procedure "LLVMFloatTypeInContext" (void*) void*))
  (define LLVMDoubleTypeInContext
    (foreign-procedure "LLVMDoubleTypeInContext" (void*) void*))
  (define LLVMPointerTypeInContext         ; (ctx, address-space)
    (foreign-procedure "LLVMPointerTypeInContext" (void* unsigned-int) void*))
  (define LLVMFunctionType                 ; (ret, param-array, count, vararg?)
    (foreign-procedure "LLVMFunctionType" (void* void* unsigned-int int) void*))
  (define LLVMStructTypeInContext          ; (ctx, elem-array, count, packed?)
    (foreign-procedure "LLVMStructTypeInContext" (void* void* unsigned-int int) void*))
  (define LLVMArrayType2                   ; (elem-type, count)
    (foreign-procedure "LLVMArrayType2" (void* unsigned-64) void*))
  (define LLVMGetTypeKind
    (foreign-procedure "LLVMGetTypeKind" (void*) int))
  (define LLVMGetIntTypeWidth
    (foreign-procedure "LLVMGetIntTypeWidth" (void*) unsigned-int))
  (define LLVMGetReturnType
    (foreign-procedure "LLVMGetReturnType" (void*) void*))
  (define LLVMCountParamTypes
    (foreign-procedure "LLVMCountParamTypes" (void*) unsigned-int))
  (define LLVMGetParamTypes                ; (fn-type, dest-array)
    (foreign-procedure "LLVMGetParamTypes" (void* void*) void))
  (define LLVMIsFunctionVarArg
    (foreign-procedure "LLVMIsFunctionVarArg" (void*) int))
  (define LLVMPrintTypeToString            ; returns char*, dispose!
    (foreign-procedure "LLVMPrintTypeToString" (void*) void*))
  (define LLVMTypeOf
    (foreign-procedure "LLVMTypeOf" (void*) void*))
  (define LLVMGlobalGetValueType           ; function type of a fn (opaque ptrs!)
    (foreign-procedure "LLVMGlobalGetValueType" (void*) void*))

  ;; --- Core: functions and values ----------------------------------------
  (define LLVMAddFunction
    (foreign-procedure "LLVMAddFunction" (void* string void*) void*))
  (define LLVMGetNamedFunction
    (foreign-procedure "LLVMGetNamedFunction" (void* string) void*))
  (define LLVMGetParam
    (foreign-procedure "LLVMGetParam" (void* unsigned-int) void*))
  (define LLVMCountParams
    (foreign-procedure "LLVMCountParams" (void*) unsigned-int))
  (define LLVMGetFirstFunction
    (foreign-procedure "LLVMGetFirstFunction" (void*) void*))
  (define LLVMGetNextFunction
    (foreign-procedure "LLVMGetNextFunction" (void*) void*))
  (define LLVMGetValueName2                ; (value, size_t* out-len) -> const char* (borrowed)
    (foreign-procedure "LLVMGetValueName2" (void* void*) void*))
  (define LLVMIsDeclaration
    (foreign-procedure "LLVMIsDeclaration" (void*) int))
  (define LLVMSetLinkage
    (foreign-procedure "LLVMSetLinkage" (void* int) void))
  (define LLVMSetFunctionCallConv
    (foreign-procedure "LLVMSetFunctionCallConv" (void* unsigned-int) void))

  ;; --- Core: constants ----------------------------------------------------
  (define LLVMConstInt                     ; (type, value, sign-extend?)
    (foreign-procedure "LLVMConstInt" (void* unsigned-64 int) void*))
  (define LLVMConstReal
    (foreign-procedure "LLVMConstReal" (void* double) void*))
  (define LLVMConstNull
    (foreign-procedure "LLVMConstNull" (void*) void*))
  (define LLVMConstPointerNull
    (foreign-procedure "LLVMConstPointerNull" (void*) void*))
  (define LLVMGetUndef
    (foreign-procedure "LLVMGetUndef" (void*) void*))

  ;; --- Core: basic blocks --------------------------------------------------
  (define LLVMAppendBasicBlockInContext
    (foreign-procedure "LLVMAppendBasicBlockInContext" (void* void* string) void*))
  (define LLVMGetInsertBlock
    (foreign-procedure "LLVMGetInsertBlock" (void*) void*))
  (define LLVMPositionBuilderAtEnd
    (foreign-procedure "LLVMPositionBuilderAtEnd" (void* void*) void))

  ;; --- Core: instruction building ------------------------------------------
  (define LLVMBuildRet
    (foreign-procedure "LLVMBuildRet" (void* void*) void*))
  (define LLVMBuildRetVoid
    (foreign-procedure "LLVMBuildRetVoid" (void*) void*))
  (define LLVMBuildBr
    (foreign-procedure "LLVMBuildBr" (void* void*) void*))
  (define LLVMBuildCondBr
    (foreign-procedure "LLVMBuildCondBr" (void* void* void* void*) void*))

  (define LLVMBuildAdd
    (foreign-procedure "LLVMBuildAdd" (void* void* void* string) void*))
  (define LLVMBuildSub
    (foreign-procedure "LLVMBuildSub" (void* void* void* string) void*))
  (define LLVMBuildMul
    (foreign-procedure "LLVMBuildMul" (void* void* void* string) void*))
  (define LLVMBuildSDiv
    (foreign-procedure "LLVMBuildSDiv" (void* void* void* string) void*))
  (define LLVMBuildUDiv
    (foreign-procedure "LLVMBuildUDiv" (void* void* void* string) void*))
  (define LLVMBuildSRem
    (foreign-procedure "LLVMBuildSRem" (void* void* void* string) void*))
  (define LLVMBuildURem
    (foreign-procedure "LLVMBuildURem" (void* void* void* string) void*))
  (define LLVMBuildAnd
    (foreign-procedure "LLVMBuildAnd" (void* void* void* string) void*))
  (define LLVMBuildOr
    (foreign-procedure "LLVMBuildOr" (void* void* void* string) void*))
  (define LLVMBuildXor
    (foreign-procedure "LLVMBuildXor" (void* void* void* string) void*))
  (define LLVMBuildShl
    (foreign-procedure "LLVMBuildShl" (void* void* void* string) void*))
  (define LLVMBuildLShr
    (foreign-procedure "LLVMBuildLShr" (void* void* void* string) void*))
  (define LLVMBuildAShr
    (foreign-procedure "LLVMBuildAShr" (void* void* void* string) void*))
  (define LLVMBuildFAdd
    (foreign-procedure "LLVMBuildFAdd" (void* void* void* string) void*))
  (define LLVMBuildFSub
    (foreign-procedure "LLVMBuildFSub" (void* void* void* string) void*))
  (define LLVMBuildFMul
    (foreign-procedure "LLVMBuildFMul" (void* void* void* string) void*))
  (define LLVMBuildFDiv
    (foreign-procedure "LLVMBuildFDiv" (void* void* void* string) void*))
  (define LLVMBuildNeg
    (foreign-procedure "LLVMBuildNeg" (void* void* string) void*))
  (define LLVMBuildFNeg
    (foreign-procedure "LLVMBuildFNeg" (void* void* string) void*))
  (define LLVMBuildNot
    (foreign-procedure "LLVMBuildNot" (void* void* string) void*))

  (define LLVMBuildICmp                    ; (builder, predicate, lhs, rhs, name)
    (foreign-procedure "LLVMBuildICmp" (void* int void* void* string) void*))
  (define LLVMBuildFCmp
    (foreign-procedure "LLVMBuildFCmp" (void* int void* void* string) void*))
  (define LLVMBuildSelect
    (foreign-procedure "LLVMBuildSelect" (void* void* void* void* string) void*))
  (define LLVMBuildPhi
    (foreign-procedure "LLVMBuildPhi" (void* void* string) void*))
  (define LLVMAddIncoming                  ; (phi, value-array, block-array, count)
    (foreign-procedure "LLVMAddIncoming" (void* void* void* unsigned-int) void))
  (define LLVMBuildCall2                   ; (builder, fn-type, fn, arg-array, count, name)
    (foreign-procedure "LLVMBuildCall2" (void* void* void* void* unsigned-int string) void*))
  (define LLVMBuildAlloca
    (foreign-procedure "LLVMBuildAlloca" (void* void* string) void*))
  (define LLVMBuildLoad2                   ; (builder, elem-type, ptr, name)
    (foreign-procedure "LLVMBuildLoad2" (void* void* void* string) void*))
  (define LLVMBuildStore
    (foreign-procedure "LLVMBuildStore" (void* void* void*) void*))
  (define LLVMBuildGEP2                    ; (builder, elem-type, ptr, index-array, count, name)
    (foreign-procedure "LLVMBuildGEP2" (void* void* void* void* unsigned-int string) void*))

  (define LLVMBuildTrunc
    (foreign-procedure "LLVMBuildTrunc" (void* void* void* string) void*))
  (define LLVMBuildZExt
    (foreign-procedure "LLVMBuildZExt" (void* void* void* string) void*))
  (define LLVMBuildSExt
    (foreign-procedure "LLVMBuildSExt" (void* void* void* string) void*))
  (define LLVMBuildSIToFP
    (foreign-procedure "LLVMBuildSIToFP" (void* void* void* string) void*))
  (define LLVMBuildUIToFP
    (foreign-procedure "LLVMBuildUIToFP" (void* void* void* string) void*))
  (define LLVMBuildFPToSI
    (foreign-procedure "LLVMBuildFPToSI" (void* void* void* string) void*))
  (define LLVMBuildFPToUI
    (foreign-procedure "LLVMBuildFPToUI" (void* void* void* string) void*))
  (define LLVMBuildFPTrunc
    (foreign-procedure "LLVMBuildFPTrunc" (void* void* void* string) void*))
  (define LLVMBuildFPExt
    (foreign-procedure "LLVMBuildFPExt" (void* void* void* string) void*))
  (define LLVMBuildPtrToInt
    (foreign-procedure "LLVMBuildPtrToInt" (void* void* void* string) void*))
  (define LLVMBuildIntToPtr
    (foreign-procedure "LLVMBuildIntToPtr" (void* void* void* string) void*))
  (define LLVMBuildBitCast
    (foreign-procedure "LLVMBuildBitCast" (void* void* void* string) void*))

  ;; --- Analysis.h -----------------------------------------------------------
  ;; action: 0 = abort-process, 1 = print-message, 2 = return-status
  (define LLVMVerifyModule                 ; (module, action, char** out-msg) -> bool (true = broken)
    (foreign-procedure "LLVMVerifyModule" (void* int void*) int))
  (define LLVMVerifyFunction
    (foreign-procedure "LLVMVerifyFunction" (void* int) int))

  ;; --- Error.h ---------------------------------------------------------------
  (define LLVMGetErrorMessage              ; consumes the error, returns char* (dispose-error-message!)
    (foreign-procedure "LLVMGetErrorMessage" (void*) void*))
  (define LLVMDisposeErrorMessage
    (foreign-procedure "LLVMDisposeErrorMessage" (void*) void))
  (define LLVMConsumeError
    (foreign-procedure "LLVMConsumeError" (void*) void))

  ;; --- Target.h / TargetMachine.h ----------------------------------------------
  (define LLVMGetDefaultTargetTriple       ; char*, dispose!
    (foreign-procedure "LLVMGetDefaultTargetTriple" () void*))
  (define LLVMGetHostCPUName               ; char*, dispose!
    (foreign-procedure "LLVMGetHostCPUName" () void*))
  (define LLVMGetHostCPUFeatures           ; char*, dispose!
    (foreign-procedure "LLVMGetHostCPUFeatures" () void*))
  (define LLVMGetTargetFromTriple          ; (triple, target*, char** err) -> bool (true = failed)
    (foreign-procedure "LLVMGetTargetFromTriple" (string void* void*) int))
  (define LLVMCreateTargetMachine          ; (target, triple, cpu, features, opt, reloc, code-model)
    (foreign-procedure "LLVMCreateTargetMachine"
                       (void* string string string int int int) void*))
  (define LLVMDisposeTargetMachine
    (foreign-procedure "LLVMDisposeTargetMachine" (void*) void))
  ;; file-type: 0 = assembly, 1 = object
  (define LLVMTargetMachineEmitToFile      ; (tm, module, path, file-type, char** err) -> bool (true = failed)
    (foreign-procedure "LLVMTargetMachineEmitToFile" (void* void* string int void*) int))
  (define LLVMTargetMachineEmitToMemoryBuffer ; (tm, module, file-type, char** err, membuf* out)
    (foreign-procedure "LLVMTargetMachineEmitToMemoryBuffer" (void* void* int void* void*) int))
  (define LLVMCreateTargetDataLayout
    (foreign-procedure "LLVMCreateTargetDataLayout" (void*) void*))
  (define LLVMCopyStringRepOfTargetData    ; char*, dispose!
    (foreign-procedure "LLVMCopyStringRepOfTargetData" (void*) void*))
  (define LLVMDisposeTargetData
    (foreign-procedure "LLVMDisposeTargetData" (void*) void))
  (define LLVMGetBufferStart
    (foreign-procedure "LLVMGetBufferStart" (void*) void*))
  (define LLVMGetBufferSize
    (foreign-procedure "LLVMGetBufferSize" (void*) size_t))
  (define LLVMDisposeMemoryBuffer
    (foreign-procedure "LLVMDisposeMemoryBuffer" (void*) void))

  ;; --- Transforms/PassBuilder.h ------------------------------------------------
  (define LLVMRunPasses                    ; (module, passes-string, tm-or-null, options) -> LLVMErrorRef
    (foreign-procedure "LLVMRunPasses" (void* string void* void*) void*))
  (define LLVMCreatePassBuilderOptions
    (foreign-procedure "LLVMCreatePassBuilderOptions" () void*))
  (define LLVMDisposePassBuilderOptions
    (foreign-procedure "LLVMDisposePassBuilderOptions" (void*) void))

  ;; --- Orc.h / LLJIT.h -----------------------------------------------------------
  (define LLVMOrcCreateNewThreadSafeContext
    (foreign-procedure "LLVMOrcCreateNewThreadSafeContext" () void*))
  (define LLVMOrcThreadSafeContextGetContext
    (foreign-procedure "LLVMOrcThreadSafeContextGetContext" (void*) void*))
  (define LLVMOrcDisposeThreadSafeContext
    (foreign-procedure "LLVMOrcDisposeThreadSafeContext" (void*) void))
  (define LLVMOrcCreateNewThreadSafeModule ; consumes module; tsctx stays ours
    (foreign-procedure "LLVMOrcCreateNewThreadSafeModule" (void* void*) void*))
  (define LLVMOrcDisposeThreadSafeModule   ; only if NOT handed to the JIT
    (foreign-procedure "LLVMOrcDisposeThreadSafeModule" (void*) void))
  (define LLVMOrcCreateLLJITBuilder
    (foreign-procedure "LLVMOrcCreateLLJITBuilder" () void*))
  (define LLVMOrcDisposeLLJITBuilder
    (foreign-procedure "LLVMOrcDisposeLLJITBuilder" (void*) void))
  (define LLVMOrcCreateLLJIT               ; (LLJIT* out, builder-or-null) -> LLVMErrorRef
    (foreign-procedure "LLVMOrcCreateLLJIT" (void* void*) void*))
  (define LLVMOrcDisposeLLJIT              ; -> LLVMErrorRef
    (foreign-procedure "LLVMOrcDisposeLLJIT" (void*) void*))
  (define LLVMOrcLLJITGetMainJITDylib
    (foreign-procedure "LLVMOrcLLJITGetMainJITDylib" (void*) void*))
  (define LLVMOrcLLJITAddLLVMIRModule      ; consumes TSM even on error -> LLVMErrorRef
    (foreign-procedure "LLVMOrcLLJITAddLLVMIRModule" (void* void* void*) void*))
  (define LLVMOrcLLJITLookup               ; (jit, uint64* out-addr, name) -> LLVMErrorRef
    (foreign-procedure "LLVMOrcLLJITLookup" (void* void* string) void*)))
