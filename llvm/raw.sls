;;; (llvm raw) -- layer 0: foreign-procedure bindings to the selected LLVM C
;;; API.
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
[library
 (llvm raw)
 [export
  ;; Core: context / module / builder lifecycle
  ContextCreate
  ContextDispose
  ModuleCreateWithNameInContext
  DisposeModule
  SetTarget
  SetDataLayout
  PrintModuleToString
  DisposeMessage
  CreateBuilderInContext
  DisposeBuilder
  ;; Core: types
  VoidTypeInContext
  Int1TypeInContext
  Int8TypeInContext
  Int16TypeInContext
  Int32TypeInContext
  Int64TypeInContext
  IntTypeInContext
  FloatTypeInContext
  DoubleTypeInContext
  PointerTypeInContext
  FunctionType
  StructTypeInContext
  ArrayType2
  VectorType
  GetTypeKind
  GetIntTypeWidth
  GetReturnType
  CountParamTypes
  GetParamTypes
  IsFunctionVarArg
  PrintTypeToString
  TypeOf
  GlobalGetValueType
  ;; predecessors and extras for the LLVM 16 qualification
  ArrayType
  ConstArray
  GetArrayLength
  ConstStringInContext
  ConstStringInContext/bytes
  BuildInBoundsGEP2
  IsInBounds
  SetTailCall
  IsTailCall
  ContextSetOpaquePointers
  PointerType
  PointerTypeIsOpaque
  WriteBitcodeToMemoryBuffer
  AddNamedMetadataOperand
  ;; Core: functions and values
  AddFunction
  GetNamedFunction
  GetParam
  CountParams
  GetFirstFunction
  GetNextFunction
  GetFirstBasicBlock
  GetNextBasicBlock
  GetFirstInstruction
  GetNextInstruction
  GetInstructionOpcode
  GetICmpPredicate
  GetFCmpPredicate
  GetInstructionParent
  SetOperand
  PositionBuilderBefore
  GetValueName2
  SetValueName2
  IsDeclaration
  SetLinkage
  SetFunctionCallConv
  SetAlignment
  SetTailCallKind
  GetTailCallKind
  ReplaceAllUsesWith
  InstructionEraseFromParent
  DeleteBasicBlock
  ;; instruction flags (setters + getters)
  SetNSW
  GetNSW
  SetNUW
  GetNUW
  SetExact
  GetExact
  SetNNeg
  GetNNeg
  SetIsDisjoint
  GetIsDisjoint
  SetVolatile
  GetVolatile
  SetFastMathFlags
  GetFastMathFlags
  CanValueUseFastMathFlags
  GEPGetNoWrapFlags
  ;; Core: constants
  ConstInt
  ConstReal
  ConstNull
  ConstPointerNull
  GetUndef
  ConstVector
  BlockAddress
  ConstArray2
  ConstStructInContext
  ConstStringInContext2
  ConstStringInContext2/bytes
  ;; module-level globals
  AddGlobal
  GetFirstGlobal
  GetNextGlobal
  SetInitializer
  SetGlobalConstant
  GetLinkage
  ;; Core: basic blocks
  AppendBasicBlockInContext
  GetInsertBlock
  PositionBuilderAtEnd
  ;; Core: instruction building
  BuildRet
  BuildRetVoid
  BuildBr
  BuildCondBr
  BuildSwitch
  AddCase
  BuildIndirectBr
  AddDestination
  BuildUnreachable
  ;; exception handling
  BuildInvoke2
  BuildResume
  BuildLandingPad
  AddClause
  SetCleanup
  SetPersonalityFn
  BuildCatchSwitch
  AddHandler
  BuildCatchPad
  BuildCleanupPad
  BuildCatchRet
  BuildCleanupRet
  BuildCallBr
  GetInlineAsm
  TokenTypeInContext
  BuildAdd
  BuildSub
  BuildMul
  BuildSDiv
  BuildUDiv
  BuildSRem
  BuildURem
  BuildAnd
  BuildOr
  BuildXor
  BuildShl
  BuildLShr
  BuildAShr
  BuildFAdd
  BuildFSub
  BuildFMul
  BuildFDiv
  BuildFRem
  BuildNeg
  BuildFNeg
  BuildNot
  BuildICmp
  BuildFCmp
  BuildSelect
  BuildPhi
  AddIncoming
  BuildCall2
  BuildAlloca
  BuildArrayAlloca
  BuildLoad2
  BuildStore
  BuildGEP2
  BuildGEPWithNoWrapFlags
  BuildTrunc
  BuildZExt
  BuildSExt
  BuildSIToFP
  BuildUIToFP
  BuildFPToSI
  BuildFPToUI
  BuildFPTrunc
  BuildFPExt
  BuildPtrToInt
  BuildIntToPtr
  BuildBitCast
  BuildAddrSpaceCast
  BuildFreeze
  BuildVAArg
  BuildExtractElement
  BuildInsertElement
  BuildShuffleVector
  BuildExtractValue
  BuildInsertValue
  BuildFence
  BuildAtomicRMW
  BuildAtomicCmpXchg
  SetOrdering
  GetOrdering
  SetWeak
  GetWeak
  GetAtomicRMWBinOp
  GetCmpXchgSuccessOrdering
  GetCmpXchgFailureOrdering
  ;; Analysis
  VerifyModule
  VerifyFunction
  ;; Error.h
  GetErrorMessage
  DisposeErrorMessage
  ConsumeError
  CreateStringError
  GetModuleContext
  GetModuleFlag
  AddModuleFlag
  OrcLLJITGetIRTransformLayer
  OrcIRTransformLayerSetTransform
  OrcThreadSafeModuleWithModuleDo
  ;; TargetMachine.h / Target.h
  GetDefaultTargetTriple
  GetHostCPUName
  GetHostCPUFeatures
  GetTargetFromTriple
  CreateTargetMachine
  DisposeTargetMachine
  TargetMachineEmitToFile
  TargetMachineEmitToMemoryBuffer
  CreateTargetDataLayout
  CopyStringRepOfTargetData
  DisposeTargetData
  GetBufferStart
  GetBufferSize
  DisposeMemoryBuffer
  ;; generic value/type inspection (read-only; used by sll:unbuild)
  GetOperand
  GetNumOperands
  GetNumArgOperands
  IsAInstruction
  IsAArgument
  IsAFunction
  IsAGlobalVariable
  IsAGlobalAlias
  DeleteFunction
  GetFirstUse
  GetNextUse
  GetUser
  IsAMDNode
  IsAMDString
  IsAValueAsMetadata
  MDStringInContext2
  MDNodeInContext2
  MetadataAsValue2
  ValueAsMetadata
  GetMetadataKind
  GetMDString
  GetMDNodeNumOperands
  GetMDNodeOperands
  MetadataTypeInContext
  X86MMXTypeInContext
  X86AMXTypeInContext
  TargetExtTypeInContext
  GetTargetExtTypeName
  GetTargetExtTypeNumTypeParams
  GetTargetExtTypeTypeParam
  GetTargetExtTypeNumIntParams
  GetTargetExtTypeIntParam
  IsAConstantInt
  IsAConstantFP
  IsAConstantExpr
  IsAConstantPointerNull
  IsAConstantAggregateZero
  IsAConstantDataArray
  IsAConstantArray
  IsAConstantStruct
  IsAConstantVector
  IsAConstantDataVector
  IsAInlineAsm
  IsABlockAddress
  IsAConstantTokenNone
  IsUndef
  IsPoison
  GetPoison
  ConstIntGetSExtValue
  ConstIntGetZExtValue
  ConstRealGetDouble
  GetAggregateElement
  IsConstantString
  GetAsString
  GetConstOpcode
  GetElementType
  GetArrayLength2
  GetVectorSize
  CountStructElementTypes
  StructGetTypeAtIndex
  GetStructName
  GetPointerAddressSpace
  HalfTypeInContext
  BFloatTypeInContext
  FP128TypeInContext
  X86FP80TypeInContext
  PPCFP128TypeInContext
  GetAlignment
  GetAllocatedType
  GetGEPSourceElementType
  CountIncoming
  GetIncomingValue
  GetIncomingBlock
  GetCalledValue
  GetCalledFunctionType
  GetNormalDest
  GetUnwindDest
  GetNumSuccessors
  GetSuccessor
  GetNumClauses
  GetClause
  IsCleanup
  GetNumHandlers
  GetHandlers
  GetParentCatchSwitch
  GetNumIndices
  GetIndices
  GetNumMaskElements
  GetMaskValue
  GetUndefMaskElem
  GetInlineAsmAsmString
  GetInlineAsmConstraintString
  GetInlineAsmHasSideEffects
  GetInlineAsmNeedsAlignedStack
  GetInlineAsmDialect
  GetInlineAsmCanUnwind
  GetBlockAddressFunction
  GetBlockAddressBasicBlock
  HasPersonalityFn
  GetPersonalityFn
  GetInitializer
  GetGlobalParent
  GetTypeContext
  IsGlobalConstant
  ContextSetDiagnosticHandler
  GetDiagInfoDescription
  GetDiagInfoSeverity
  HasMetadata
  GetFunctionCallConv
  GetAttributeCountAtIndex
  GetVisibility
  IsThreadLocal
  GetSection
  GetNumOperandBundles
  IsAtomicSingleThread
  IsPackedStruct
  GetBasicBlockName
  GetFirstGlobalAlias
  GetNextGlobalAlias
  AddAlias2
  AliasGetAliasee
  AliasSetAliasee
  GetFirstGlobalIFunc
  GetNextGlobalIFunc
  AddGlobalIFunc
  GetGlobalIFuncResolver
  SetGlobalIFuncResolver
  SetModuleInlineAsm2
  GetFirstNamedMetadata
  GetModuleInlineAsm
  GetTarget
  GetDataLayoutStr
  ;; normalization (stripping constructs sll does not model)
  StripModuleDebugInfo
  InstructionGetAllMetadataOtherThanDebugLoc
  ValueMetadataEntriesGetKind
  DisposeValueMetadataEntries
  SetMetadata
  GlobalClearMetadata
  GetMetadata
  GetMDKindIDInContext
  GetAttributesAtIndex
  IsEnumAttribute
  IsStringAttribute
  GetEnumAttributeKind
  GetStringAttributeKind
  GetEnumAttributeKindForName
  CreateEnumAttribute
  CreateStringAttribute
  AddAttributeAtIndex
  AddCallSiteAttribute
  GetEnumAttributeValue
  GetStringAttributeValue
  IsTypeAttribute
  RemoveEnumAttributeAtIndex
  RemoveStringAttributeAtIndex
  GetCallSiteAttributeCount
  GetCallSiteAttributes
  RemoveCallSiteEnumAttribute
  RemoveCallSiteStringAttribute
  SetInstructionCallConv
  GetInstructionCallConv
  SetUnnamedAddress
  SetVisibility
  SetSection
  SetThreadLocal
  ;; named struct types
  StructCreateNamed
  StructSetBody
  ;; constant expressions
  ConstGEP2
  ConstInBoundsGEP2
  ConstGEPWithNoWrapFlags
  ConstPtrToInt
  ConstIntToPtr
  ConstBitCast
  ConstAddrSpaceCast
  ConstTrunc
  ConstAdd
  ConstNSWAdd
  ConstNUWAdd
  ConstSub
  ConstNSWSub
  ConstNUWSub
  ConstMul
  ConstNSWMul
  ConstNUWMul
  ConstXor
  ConstExtractElement
  ConstInsertElement
  ConstShuffleVector
  IsAConstant
  IsExternallyInitialized
  HasPrefixData
  HasPrologueData
  SetGC
  SetGCString
  GetGC
  SetAtomicSingleThread
  SetExternallyInitialized
  CreateOperandBundle
  DisposeOperandBundle
  GetOperandBundleAtIndex
  GetOperandBundleTag
  GetNumOperandBundleArgs
  GetOperandBundleArgAtIndex
  BuildCallWithOperandBundles
  BuildInvokeWithOperandBundles
  GetTypeByName2
  IsOpaqueStruct
  IsLiteralStruct
  ScalableVectorType
  ConstIntOfStringAndSize
  PrintValueToString
  AddGlobalInAddressSpace
  SetComdat
  SetDLLStorageClass
  ConstNamedStruct
  ;; IRReader.h + memory buffers from bytes
  ParseIRInContext
  CreateMemoryBufferWithMemoryRangeCopy
  ;; Transforms/PassBuilder.h (new pass manager)
  RunPasses
  CreatePassBuilderOptions
  DisposePassBuilderOptions
  ;; Orc.h / LLJIT.h
  OrcCreateNewThreadSafeContext
  OrcThreadSafeContextGetContext
  OrcDisposeThreadSafeContext
  OrcCreateNewThreadSafeModule
  OrcDisposeThreadSafeModule
  OrcCreateLLJITBuilder
  OrcDisposeLLJITBuilder
  OrcJITTargetMachineBuilderCreateFromTargetMachine
  OrcLLJITBuilderSetJITTargetMachineBuilder
  OrcCreateLLJIT
  OrcDisposeLLJIT
  OrcLLJITGetMainJITDylib
  OrcLLJITGetTripleString
  OrcLLJITGetDataLayoutStr
  OrcLLJITAddLLVMIRModule
  OrcLLJITLookup
  OrcLLJITGetGlobalPrefix
  OrcCreateDynamicLibrarySearchGeneratorForProcess
  OrcJITDylibAddGenerator]
 (import (chezscheme) (prefix (llvm config) config:))

 ;; Must run before any foreign-procedure below is evaluated.
 (define llvm-loaded (config:load!))

 ;; C entries that exist only in some qualified releases, each with the
 ;; capability that names it (see config:capability?). define-getter binds an
 ;; entry through bind-entry: when its capability is off, the binding refuses
 ;; with that capability instead of resolving a missing C symbol while the
 ;; library loads. tests/test-version.ss checks that every entry listed here is
 ;; present exactly when its capability is on.
 [define
  optional-entries
  '[("LLVMContextSetOpaquePointers"      . typed-pointers              )
    ("LLVMArrayType2"                    . array-length-64             )
    ("LLVMConstArray2"                   . array-length-64             )
    ("LLVMGetArrayLength2"               . array-length-64             )
    ("LLVMGetTargetExtTypeName"          . target-ext-types            )
    ("LLVMGetTargetExtTypeNumTypeParams" . target-ext-types            )
    ("LLVMGetTargetExtTypeTypeParam"     . target-ext-types            )
    ("LLVMGetTargetExtTypeNumIntParams"  . target-ext-types            )
    ("LLVMGetTargetExtTypeIntParam"      . target-ext-types            )
    ("LLVMIsAValueAsMetadata"            . value-as-metadata-inspection)
    ("LLVMSetNSW"                        . flag-accessors              )
    ("LLVMGetNSW"                        . flag-accessors              )
    ("LLVMSetNUW"                        . flag-accessors              )
    ("LLVMGetNUW"                        . flag-accessors              )
    ("LLVMSetExact"                      . flag-accessors              )
    ("LLVMGetExact"                      . flag-accessors              )
    ("LLVMSetNNeg"                       . flag-accessors              )
    ("LLVMGetNNeg"                       . flag-accessors              )
    ("LLVMSetIsDisjoint"                 . flag-accessors              )
    ("LLVMGetIsDisjoint"                 . flag-accessors              )
    ("LLVMSetFastMathFlags"              . flag-accessors              )
    ("LLVMGetFastMathFlags"              . flag-accessors              )
    ("LLVMCanValueUseFastMathFlags"      . flag-accessors              )
    ("LLVMSetTailCallKind"               . tail-call-kinds             )
    ("LLVMGetTailCallKind"               . tail-call-kinds             )
    ("LLVMCreateOperandBundle"           . operand-bundles             )
    ("LLVMDisposeOperandBundle"          . operand-bundles             )
    ("LLVMGetNumOperandBundles"          . operand-bundles             )
    ("LLVMGetOperandBundleAtIndex"       . operand-bundles             )
    ("LLVMGetOperandBundleTag"           . operand-bundles             )
    ("LLVMGetNumOperandBundleArgs"       . operand-bundles             )
    ("LLVMGetOperandBundleArgAtIndex"    . operand-bundles             )
    ("LLVMBuildCallWithOperandBundles"   . operand-bundles             )
    ("LLVMBuildInvokeWithOperandBundles" . operand-bundles             )
    ("LLVMGetInlineAsmAsmString"         . inline-asm-inspection       )
    ("LLVMGetInlineAsmConstraintString"  . inline-asm-inspection       )
    ("LLVMGetInlineAsmDialect"           . inline-asm-inspection       )
    ("LLVMGetInlineAsmHasSideEffects"    . inline-asm-inspection       )
    ("LLVMGetInlineAsmNeedsAlignedStack" . inline-asm-inspection       )
    ("LLVMGetInlineAsmCanUnwind"         . inline-asm-inspection       )
    ("LLVMHasPrefixData"                 . prefix-data-inspection      )
    ("LLVMHasPrologueData"               . prefix-data-inspection      )
    ("LLVMConstStringInContext2"         . sized-string-constants      )
    ("LLVMBuildCallBr"                   . callbr                      )
    ("LLVMBuildGEPWithNoWrapFlags"       . gep-no-wrap-flags           )
    ("LLVMConstGEPWithNoWrapFlags"       . gep-no-wrap-flags           )
    ("LLVMGEPGetNoWrapFlags"             . gep-no-wrap-flags           )
    ("LLVMGetBlockAddressBasicBlock"     . blockaddress-inspection     )
    ("LLVMGetBlockAddressFunction"       . blockaddress-inspection     )
    ("LLVMX86MMXTypeInContext"           . x86-mmx                     )]]

 [define
  (bind-entry c-name make)
  [let
   ((entry (assoc c-name optional-entries)))
   [if
    (and entry (not (config:capability? (cdr entry))))
    (lambda args (config:require-capability! (cdr entry)))
    (make)]]]

 ;; (define-getter name "LLVMName" (types) ret): a binding, optional ones
 ;; through bind-entry
 [define-syntax
  define-getter
  [syntax-rules
   ()
   [(_ name c-name (t ...) r)
    [define
     name
     (bind-entry c-name (lambda () (foreign-procedure c-name (t ...) r)))]]]]

 [define
  CreateStringError
  (foreign-procedure "LLVMCreateStringError" (string) void*)]
 [define
  GetModuleContext
  (foreign-procedure "LLVMGetModuleContext" (void*) void*)]
 [define
  GetModuleFlag
  (foreign-procedure "LLVMGetModuleFlag" (void* string size_t) void*)]
 [define
  AddModuleFlag
  (foreign-procedure "LLVMAddModuleFlag" (void* int string size_t void*) void)]
 [define
  OrcLLJITGetIRTransformLayer
  (foreign-procedure "LLVMOrcLLJITGetIRTransformLayer" (void*) void*)]
 [define
  OrcIRTransformLayerSetTransform
  [foreign-procedure
   "LLVMOrcIRTransformLayerSetTransform"
   (void* void* void*)
   void]]
 [define
  OrcThreadSafeModuleWithModuleDo
  [foreign-procedure
   "LLVMOrcThreadSafeModuleWithModuleDo"
   (void* void* void*)
   void*]]

 ;; --- Core: context / module / builder ---------------------------------
 (define ContextCreate (foreign-procedure "LLVMContextCreate" () void*))
 (define ContextDispose (foreign-procedure "LLVMContextDispose" (void*) void))
 [define
  ModuleCreateWithNameInContext
  (foreign-procedure "LLVMModuleCreateWithNameInContext" (string void*) void*)]
 (define DisposeModule (foreign-procedure "LLVMDisposeModule" (void*) void))
 (define SetTarget (foreign-procedure "LLVMSetTarget" (void* string) void))
 [define
  SetDataLayout
  (foreign-procedure "LLVMSetDataLayout" (void* string) void)]
 [define
  PrintModuleToString           ; returns char*, dispose!
  (foreign-procedure "LLVMPrintModuleToString" (void*) void*)]
 (define DisposeMessage (foreign-procedure "LLVMDisposeMessage" (void*) void))
 [define
  CreateBuilderInContext
  (foreign-procedure "LLVMCreateBuilderInContext" (void*) void*)]
 (define DisposeBuilder (foreign-procedure "LLVMDisposeBuilder" (void*) void))

 ;; --- Core: types --------------------------------------------------------
 [define
  VoidTypeInContext
  (foreign-procedure "LLVMVoidTypeInContext" (void*) void*)]
 [define
  Int1TypeInContext
  (foreign-procedure "LLVMInt1TypeInContext" (void*) void*)]
 [define
  Int8TypeInContext
  (foreign-procedure "LLVMInt8TypeInContext" (void*) void*)]
 [define
  Int16TypeInContext
  (foreign-procedure "LLVMInt16TypeInContext" (void*) void*)]
 [define
  Int32TypeInContext
  (foreign-procedure "LLVMInt32TypeInContext" (void*) void*)]
 [define
  Int64TypeInContext
  (foreign-procedure "LLVMInt64TypeInContext" (void*) void*)]
 [define
  IntTypeInContext
  (foreign-procedure "LLVMIntTypeInContext" (void* unsigned-int) void*)]
 [define
  FloatTypeInContext
  (foreign-procedure "LLVMFloatTypeInContext" (void*) void*)]
 [define
  DoubleTypeInContext
  (foreign-procedure "LLVMDoubleTypeInContext" (void*) void*)]
 [define
  PointerTypeInContext          ; (ctx, address-space)
  (foreign-procedure "LLVMPointerTypeInContext" (void* unsigned-int) void*)]
 ;; typed pointers: (element-type, address-space); the element type is ignored
 ;; by opaque-pointer releases. LLVM 16 can still switch a context to typed
 ;; pointers (optional entry, removed in 17).
 (define-getter PointerType "LLVMPointerType" (void* unsigned-int) void*)
 (define-getter PointerTypeIsOpaque "LLVMPointerTypeIsOpaque" (void*) int)
 [define-getter
  ContextSetOpaquePointers      ; (ctx, opaque?) -- before any type is created
  "LLVMContextSetOpaquePointers"
  (void* int)
  void]
 [define
  FunctionType                  ; (ret, param-array, count, vararg?)
  (foreign-procedure "LLVMFunctionType" (void* void* unsigned-int int) void*)]
 [define
  StructTypeInContext           ; (ctx, elem-array, count, packed?)
  [foreign-procedure
   "LLVMStructTypeInContext"
   (void* void* unsigned-int int)
   void*]]
 (define-getter ArrayType2 "LLVMArrayType2" (void* unsigned-64) void*)
 ;; the 32-bit-length predecessor, for releases before LLVM 17
 (define-getter ArrayType "LLVMArrayType" (void* unsigned-int) void*)
 [define
  VectorType                    ; (elem-type, count)
  (foreign-procedure "LLVMVectorType" (void* unsigned-int) void*)]
 (define GetTypeKind (foreign-procedure "LLVMGetTypeKind" (void*) int))
 [define
  GetIntTypeWidth
  (foreign-procedure "LLVMGetIntTypeWidth" (void*) unsigned-int)]
 (define GetReturnType (foreign-procedure "LLVMGetReturnType" (void*) void*))
 [define
  CountParamTypes
  (foreign-procedure "LLVMCountParamTypes" (void*) unsigned-int)]
 [define
  GetParamTypes                 ; (fn-type, dest-array)
  (foreign-procedure "LLVMGetParamTypes" (void* void*) void)]
 [define
  IsFunctionVarArg
  (foreign-procedure "LLVMIsFunctionVarArg" (void*) int)]
 [define
  PrintTypeToString             ; returns char*, dispose!
  (foreign-procedure "LLVMPrintTypeToString" (void*) void*)]
 (define TypeOf (foreign-procedure "LLVMTypeOf" (void*) void*))
 [define
  GlobalGetValueType            ; function type of a fn (opaque ptrs!)
  (foreign-procedure "LLVMGlobalGetValueType" (void*) void*)]

 ;; --- Core: functions and values ----------------------------------------
 [define
  AddFunction
  (foreign-procedure "LLVMAddFunction" (void* string void*) void*)]
 [define
  GetNamedFunction
  (foreign-procedure "LLVMGetNamedFunction" (void* string) void*)]
 (define GetParam (foreign-procedure "LLVMGetParam" (void* unsigned-int) void*))
 (define CountParams (foreign-procedure "LLVMCountParams" (void*) unsigned-int))
 [define
  GetFirstFunction
  (foreign-procedure "LLVMGetFirstFunction" (void*) void*)]
 [define
  GetNextFunction
  (foreign-procedure "LLVMGetNextFunction" (void*) void*)]
 [define
  GetFirstBasicBlock
  (foreign-procedure "LLVMGetFirstBasicBlock" (void*) void*)]
 [define
  GetNextBasicBlock
  (foreign-procedure "LLVMGetNextBasicBlock" (void*) void*)]
 [define
  GetFirstInstruction
  (foreign-procedure "LLVMGetFirstInstruction" (void*) void*)]
 [define
  GetNextInstruction
  (foreign-procedure "LLVMGetNextInstruction" (void*) void*)]
 [define
  GetInstructionOpcode          ; LLVMOpcode enum value
  (foreign-procedure "LLVMGetInstructionOpcode" (void*) int)]
 [define
  GetInstructionParent          ; instruction -> basic block
  (foreign-procedure "LLVMGetInstructionParent" (void*) void*)]
 [define
  SetOperand                    ; (user, index, new-value)
  (foreign-procedure "LLVMSetOperand" (void* unsigned-int void*) void)]
 [define
  PositionBuilderBefore         ; insert point: before INSTR
  (foreign-procedure "LLVMPositionBuilderBefore" (void* void*) void)]
 [define
  GetICmpPredicate              ; only meaningful on icmp instructions
  (foreign-procedure "LLVMGetICmpPredicate" (void*) int)]
 [define
  GetFCmpPredicate              ; only meaningful on fcmp instructions
  (foreign-procedure "LLVMGetFCmpPredicate" (void*) int)]
 [define
  GetValueName2                 ; (value, size_t* out-len) -> const char*
                                ; (borrowed)
  (foreign-procedure "LLVMGetValueName2" (void* void*) void*)]
 [define
  SetValueName2                 ; (value, name, byte-length)
  (foreign-procedure "LLVMSetValueName2" (void* string size_t) void)]
 (define IsDeclaration (foreign-procedure "LLVMIsDeclaration" (void*) int))
 (define SetLinkage (foreign-procedure "LLVMSetLinkage" (void* int) void))
 [define
  SetFunctionCallConv
  (foreign-procedure "LLVMSetFunctionCallConv" (void* unsigned-int) void)]
 [define
  SetAlignment                  ; (load/store/alloca/global, bytes)
  (foreign-procedure "LLVMSetAlignment" (void* unsigned-int) void)]

 ;; instruction flags; each setter is only valid on the instruction kinds that
 ;; carry the flag (add/sub/mul/shl for nsw/nuw, div/shr for exact, or for
 ;; disjoint, zext for nneg, load/store for volatile) (the accessors are LLVM
 ;; 18; before that only volatile has one, and getelementptr inbounds has
 ;; LLVMIsInBounds)
 (define-getter SetNSW "LLVMSetNSW" (void* int) void)
 (define-getter GetNSW "LLVMGetNSW" (void*) int)
 (define-getter SetNUW "LLVMSetNUW" (void* int) void)
 (define-getter GetNUW "LLVMGetNUW" (void*) int)
 (define-getter SetExact "LLVMSetExact" (void* int) void)
 (define-getter GetExact "LLVMGetExact" (void*) int)
 (define-getter SetNNeg "LLVMSetNNeg" (void* int) void)
 (define-getter GetNNeg "LLVMGetNNeg" (void*) int)
 (define-getter SetIsDisjoint "LLVMSetIsDisjoint" (void* int) void)
 (define-getter GetIsDisjoint "LLVMGetIsDisjoint" (void*) int)
 (define SetVolatile (foreign-procedure "LLVMSetVolatile" (void* int) void))
 (define GetVolatile (foreign-procedure "LLVMGetVolatile" (void*) int))
 [define-getter
  SetFastMathFlags              ; LLVMFastMathFlags bitmask
  "LLVMSetFastMathFlags"
  (void* unsigned-int)
  void]
 (define-getter GetFastMathFlags "LLVMGetFastMathFlags" (void*) unsigned-int)
 [define-getter
  CanValueUseFastMathFlags      ; is this an FPMathOperator?
  "LLVMCanValueUseFastMathFlags"
  (void*)
  int]
 [define-getter
  GEPGetNoWrapFlags             ; LLVMGEPNoWrapFlags bitmask
  "LLVMGEPGetNoWrapFlags"
  (void*)
  unsigned-int]
 (define-getter IsInBounds "LLVMIsInBounds" (void*) int)
 [define-getter
  SetTailCallKind               ; LLVMTailCallKind: 0 none, 1 tail, 2 musttail,
                                ; 3 notail
  "LLVMSetTailCallKind"
  (void* int)
  void]
 (define-getter GetTailCallKind "LLVMGetTailCallKind" (void*) int)
 ;; the boolean predecessors: `tail` only
 (define-getter SetTailCall "LLVMSetTailCall" (void* int) void)
 (define-getter IsTailCall "LLVMIsTailCall" (void*) int)
 [define
  ReplaceAllUsesWith            ; (old-value, new-value)
  (foreign-procedure "LLVMReplaceAllUsesWith" (void* void*) void)]
 [define
  InstructionEraseFromParent
  (foreign-procedure "LLVMInstructionEraseFromParent" (void*) void)]
 [define
  DeleteBasicBlock
  (foreign-procedure "LLVMDeleteBasicBlock" (void*) void)]

 ;; --- Core: constants ----------------------------------------------------
 [define
  ConstInt                      ; (type, value, sign-extend?)
  (foreign-procedure "LLVMConstInt" (void* unsigned-64 int) void*)]
 (define ConstReal (foreign-procedure "LLVMConstReal" (void* double) void*))
 (define ConstNull (foreign-procedure "LLVMConstNull" (void*) void*))
 [define
  ConstPointerNull
  (foreign-procedure "LLVMConstPointerNull" (void*) void*)]
 (define GetUndef (foreign-procedure "LLVMGetUndef" (void*) void*))
 [define
  ConstVector                   ; (scalar-constant-array, count)
  (foreign-procedure "LLVMConstVector" (void* unsigned-int) void*)]
 [define
  BlockAddress                  ; (function, basic-block)
  (foreign-procedure "LLVMBlockAddress" (void* void*) void*)]
 [define-getter
  ConstArray2                   ; (elem-type, constant-array, count)
  "LLVMConstArray2"
  (void* void* unsigned-64)
  void*]
 (define-getter ConstArray "LLVMConstArray" (void* void* unsigned-int) void*)
 [define
  ConstStructInContext          ; (ctx, constant-array, count, packed?)
  [foreign-procedure
   "LLVMConstStructInContext"
   (void* void* unsigned-int int)
   void*]]
 [define-getter
  ConstStringInContext2         ; (ctx, bytes, length, dont-null-terminate?)
  "LLVMConstStringInContext2"
  (void* string size_t int)
  void*]
 [define-getter
  ConstStringInContext2/bytes   ; the same over a bytevector's bytes as they are
  "LLVMConstStringInContext2"
  (void* u8* size_t int)
  void*]
 ;; the unsigned-length predecessors, for releases before LLVM 18
 [define-getter
  ConstStringInContext
  "LLVMConstStringInContext"
  (void* string unsigned-int int)
  void*]
 [define-getter
  ConstStringInContext/bytes
  "LLVMConstStringInContext"
  (void* u8* unsigned-int int)
  void*]

 ;; --- module-level globals ------------------------------------------------
 [define
  AddGlobal                     ; created with external linkage, no init
  (foreign-procedure "LLVMAddGlobal" (void* void* string) void*)]
 (define GetFirstGlobal (foreign-procedure "LLVMGetFirstGlobal" (void*) void*))
 (define GetNextGlobal (foreign-procedure "LLVMGetNextGlobal" (void*) void*))
 [define
  SetInitializer                ; (global, constant)
  (foreign-procedure "LLVMSetInitializer" (void* void*) void)]
 [define
  SetGlobalConstant
  (foreign-procedure "LLVMSetGlobalConstant" (void* int) void)]
 [define
  GetLinkage                    ; LLVMLinkage enum value
  (foreign-procedure "LLVMGetLinkage" (void*) int)]

 ;; --- Core: basic blocks --------------------------------------------------
 [define
  AppendBasicBlockInContext
  [foreign-procedure
   "LLVMAppendBasicBlockInContext"
   (void* void* string)
   void*]]
 (define GetInsertBlock (foreign-procedure "LLVMGetInsertBlock" (void*) void*))
 [define
  PositionBuilderAtEnd
  (foreign-procedure "LLVMPositionBuilderAtEnd" (void* void*) void)]

 ;; --- Core: instruction building ------------------------------------------
 (define BuildRet (foreign-procedure "LLVMBuildRet" (void* void*) void*))
 (define BuildRetVoid (foreign-procedure "LLVMBuildRetVoid" (void*) void*))
 (define BuildBr (foreign-procedure "LLVMBuildBr" (void* void*) void*))
 [define
  BuildCondBr
  (foreign-procedure "LLVMBuildCondBr" (void* void* void* void*) void*)]
 [define
  BuildSwitch                   ; (builder, value, else-block, ncases-hint)
  (foreign-procedure "LLVMBuildSwitch" (void* void* void* unsigned-int) void*)]
 [define
  AddCase                       ; (switch, on-const, dest-block)
  (foreign-procedure "LLVMAddCase" (void* void* void*) void)]
 [define
  BuildIndirectBr               ; (builder, address, ndests-hint)
  (foreign-procedure "LLVMBuildIndirectBr" (void* void* unsigned-int) void*)]
 [define
  AddDestination                ; (indirectbr, dest-block)
  (foreign-procedure "LLVMAddDestination" (void* void*) void)]
 [define
  BuildUnreachable
  (foreign-procedure "LLVMBuildUnreachable" (void*) void*)]

 ;; exception handling
 [define
  BuildInvoke2                  ; (builder, fn-type, fn, arg-array, count,
                                ; then-bb, unwind-bb, name)
  [foreign-procedure
   "LLVMBuildInvoke2"
   (void* void* void* void* unsigned-int void* void* string)
   void*]]
 (define BuildResume (foreign-procedure "LLVMBuildResume" (void* void*) void*))
 [define
  BuildLandingPad               ; (builder, type, legacy-pers-fn (pass 0),
                                ; nclauses-hint, name)
  [foreign-procedure
   "LLVMBuildLandingPad"
   (void* void* void* unsigned-int string)
   void*]]
 [define
  AddClause                     ; catch if pointer-typed constant, filter if
                                ; array
  (foreign-procedure "LLVMAddClause" (void* void*) void)]
 (define SetCleanup (foreign-procedure "LLVMSetCleanup" (void* int) void))
 [define
  SetPersonalityFn
  (foreign-procedure "LLVMSetPersonalityFn" (void* void*) void)]
 [define
  BuildCatchSwitch              ; (builder, parent-pad, unwind-bb (0 = to
                                ; caller), nhandlers-hint, name)
  [foreign-procedure
   "LLVMBuildCatchSwitch"
   (void* void* void* unsigned-int string)
   void*]]
 (define AddHandler (foreign-procedure "LLVMAddHandler" (void* void*) void))
 [define
  BuildCatchPad                 ; (builder, parent-pad, arg-array, count, name)
  [foreign-procedure
   "LLVMBuildCatchPad"
   (void* void* void* unsigned-int string)
   void*]]
 [define
  BuildCleanupPad
  [foreign-procedure
   "LLVMBuildCleanupPad"
   (void* void* void* unsigned-int string)
   void*]]
 [define
  BuildCatchRet                 ; (builder, catchpad, dest-bb)
  (foreign-procedure "LLVMBuildCatchRet" (void* void* void*) void*)]
 [define
  BuildCleanupRet               ; (builder, cleanuppad, unwind-bb (0 = to
                                ; caller))
  (foreign-procedure "LLVMBuildCleanupRet" (void* void* void*) void*)]
 [define-getter
  BuildCallBr                   ; (builder, fn-type, fn, default-bb, dest-array,
                                ; ndests, arg-array, nargs, bundles, nbundles,
                                ; name)
  "LLVMBuildCallBr"
  [void*
   void*
   void*
   void*
   void*
   unsigned-int
   void*
   unsigned-int
   void*
   unsigned-int
   string]
  void*]
 [define
  GetInlineAsm                  ; (fn-type, asm, len, constraints, len,
                                ; side-effects?, align-stack?, dialect,
                                ; can-throw?)
  [foreign-procedure
   "LLVMGetInlineAsm"
   (void* string size_t string size_t int int int int)
   void*]]
 [define
  TokenTypeInContext            ; ConstNull of this = `none` parent pad
  (foreign-procedure "LLVMTokenTypeInContext" (void*) void*)]

 [define
  BuildAdd
  (foreign-procedure "LLVMBuildAdd" (void* void* void* string) void*)]
 [define
  BuildSub
  (foreign-procedure "LLVMBuildSub" (void* void* void* string) void*)]
 [define
  BuildMul
  (foreign-procedure "LLVMBuildMul" (void* void* void* string) void*)]
 [define
  BuildSDiv
  (foreign-procedure "LLVMBuildSDiv" (void* void* void* string) void*)]
 [define
  BuildUDiv
  (foreign-procedure "LLVMBuildUDiv" (void* void* void* string) void*)]
 [define
  BuildSRem
  (foreign-procedure "LLVMBuildSRem" (void* void* void* string) void*)]
 [define
  BuildURem
  (foreign-procedure "LLVMBuildURem" (void* void* void* string) void*)]
 [define
  BuildAnd
  (foreign-procedure "LLVMBuildAnd" (void* void* void* string) void*)]
 [define
  BuildOr
  (foreign-procedure "LLVMBuildOr" (void* void* void* string) void*)]
 [define
  BuildXor
  (foreign-procedure "LLVMBuildXor" (void* void* void* string) void*)]
 [define
  BuildShl
  (foreign-procedure "LLVMBuildShl" (void* void* void* string) void*)]
 [define
  BuildLShr
  (foreign-procedure "LLVMBuildLShr" (void* void* void* string) void*)]
 [define
  BuildAShr
  (foreign-procedure "LLVMBuildAShr" (void* void* void* string) void*)]
 [define
  BuildFAdd
  (foreign-procedure "LLVMBuildFAdd" (void* void* void* string) void*)]
 [define
  BuildFSub
  (foreign-procedure "LLVMBuildFSub" (void* void* void* string) void*)]
 [define
  BuildFMul
  (foreign-procedure "LLVMBuildFMul" (void* void* void* string) void*)]
 [define
  BuildFDiv
  (foreign-procedure "LLVMBuildFDiv" (void* void* void* string) void*)]
 [define
  BuildFRem
  (foreign-procedure "LLVMBuildFRem" (void* void* void* string) void*)]
 (define BuildNeg (foreign-procedure "LLVMBuildNeg" (void* void* string) void*))
 [define
  BuildFNeg
  (foreign-procedure "LLVMBuildFNeg" (void* void* string) void*)]
 (define BuildNot (foreign-procedure "LLVMBuildNot" (void* void* string) void*))

 [define
  BuildICmp                     ; (builder, predicate, lhs, rhs, name)
  (foreign-procedure "LLVMBuildICmp" (void* int void* void* string) void*)]
 [define
  BuildFCmp
  (foreign-procedure "LLVMBuildFCmp" (void* int void* void* string) void*)]
 [define
  BuildSelect
  (foreign-procedure "LLVMBuildSelect" (void* void* void* void* string) void*)]
 (define BuildPhi (foreign-procedure "LLVMBuildPhi" (void* void* string) void*))
 [define
  AddIncoming                   ; (phi, value-array, block-array, count)
  (foreign-procedure "LLVMAddIncoming" (void* void* void* unsigned-int) void)]
 [define
  BuildCall2                    ; (builder, fn-type, fn, arg-array, count, name)
  [foreign-procedure
   "LLVMBuildCall2"
   (void* void* void* void* unsigned-int string)
   void*]]
 [define
  BuildAlloca
  (foreign-procedure "LLVMBuildAlloca" (void* void* string) void*)]
 [define
  BuildArrayAlloca              ; (builder, elem-type, count-value, name)
  (foreign-procedure "LLVMBuildArrayAlloca" (void* void* void* string) void*)]
 [define
  BuildLoad2                    ; (builder, elem-type, ptr, name)
  (foreign-procedure "LLVMBuildLoad2" (void* void* void* string) void*)]
 [define
  BuildStore
  (foreign-procedure "LLVMBuildStore" (void* void* void*) void*)]
 [define
  BuildGEP2                     ; (builder, elem-type, ptr, index-array, count,
                                ; name)
  [foreign-procedure
   "LLVMBuildGEP2"
   (void* void* void* void* unsigned-int string)
   void*]]
 [define-getter
  BuildGEPWithNoWrapFlags       ; ... + LLVMGEPNoWrapFlags bitmask
  "LLVMBuildGEPWithNoWrapFlags"
  (void* void* void* void* unsigned-int string unsigned-int)
  void*]
 [define-getter
  BuildInBoundsGEP2             ; the flag-less predecessor of inbounds
  "LLVMBuildInBoundsGEP2"
  (void* void* void* void* unsigned-int string)
  void*]

 [define
  BuildTrunc
  (foreign-procedure "LLVMBuildTrunc" (void* void* void* string) void*)]
 [define
  BuildZExt
  (foreign-procedure "LLVMBuildZExt" (void* void* void* string) void*)]
 [define
  BuildSExt
  (foreign-procedure "LLVMBuildSExt" (void* void* void* string) void*)]
 [define
  BuildSIToFP
  (foreign-procedure "LLVMBuildSIToFP" (void* void* void* string) void*)]
 [define
  BuildUIToFP
  (foreign-procedure "LLVMBuildUIToFP" (void* void* void* string) void*)]
 [define
  BuildFPToSI
  (foreign-procedure "LLVMBuildFPToSI" (void* void* void* string) void*)]
 [define
  BuildFPToUI
  (foreign-procedure "LLVMBuildFPToUI" (void* void* void* string) void*)]
 [define
  BuildFPTrunc
  (foreign-procedure "LLVMBuildFPTrunc" (void* void* void* string) void*)]
 [define
  BuildFPExt
  (foreign-procedure "LLVMBuildFPExt" (void* void* void* string) void*)]
 [define
  BuildPtrToInt
  (foreign-procedure "LLVMBuildPtrToInt" (void* void* void* string) void*)]
 [define
  BuildIntToPtr
  (foreign-procedure "LLVMBuildIntToPtr" (void* void* void* string) void*)]
 [define
  BuildBitCast
  (foreign-procedure "LLVMBuildBitCast" (void* void* void* string) void*)]
 [define
  BuildAddrSpaceCast
  (foreign-procedure "LLVMBuildAddrSpaceCast" (void* void* void* string) void*)]
 [define
  BuildFreeze
  (foreign-procedure "LLVMBuildFreeze" (void* void* string) void*)]
 [define
  BuildVAArg                    ; (builder, va-list-ptr, type, name)
  (foreign-procedure "LLVMBuildVAArg" (void* void* void* string) void*)]
 [define
  BuildExtractElement           ; (builder, vector, index, name)
  [foreign-procedure
   "LLVMBuildExtractElement"
   (void* void* void* string)
   void*]]
 [define
  BuildInsertElement            ; (builder, vector, element, index, name)
  [foreign-procedure
   "LLVMBuildInsertElement"
   (void* void* void* void* string)
   void*]]
 [define
  BuildShuffleVector            ; (builder, v1, v2, const-mask, name)
  [foreign-procedure
   "LLVMBuildShuffleVector"
   (void* void* void* void* string)
   void*]]
 [define
  BuildExtractValue             ; (builder, aggregate, index, name)
  [foreign-procedure
   "LLVMBuildExtractValue"
   (void* void* unsigned-int string)
   void*]]
 [define
  BuildInsertValue              ; (builder, aggregate, element, index, name)
  [foreign-procedure
   "LLVMBuildInsertValue"
   (void* void* void* unsigned-int string)
   void*]]
 ;; atomics; ordering and rmw-op ints match the enums in Core.h. The builders
 ;; below take no name parameter -- name via SetValueName2.
 [define
  BuildFence                    ; (builder, ordering, single-thread?, name)
  (foreign-procedure "LLVMBuildFence" (void* int int string) void*)]
 [define
  BuildAtomicRMW                ; (builder, rmw-op, ptr, value, ordering,
                                ; single-thread?)
  [foreign-procedure
   "LLVMBuildAtomicRMW"
   (void* int void* void* int int)
   void*]]
 [define
  BuildAtomicCmpXchg            ; (builder, ptr, cmp, new, succ-ord, fail-ord,
                                ; single-thread?)
  [foreign-procedure
   "LLVMBuildAtomicCmpXchg"
   (void* void* void* void* int int int)
   void*]]
 [define
  SetOrdering                   ; load/store (and other memory insts)
  (foreign-procedure "LLVMSetOrdering" (void* int) void)]
 (define GetOrdering (foreign-procedure "LLVMGetOrdering" (void*) int))
 [define
  SetWeak                       ; cmpxchg only
  (foreign-procedure "LLVMSetWeak" (void* int) void)]
 (define GetWeak (foreign-procedure "LLVMGetWeak" (void*) int))
 [define
  GetAtomicRMWBinOp
  (foreign-procedure "LLVMGetAtomicRMWBinOp" (void*) int)]
 [define
  GetCmpXchgSuccessOrdering
  (foreign-procedure "LLVMGetCmpXchgSuccessOrdering" (void*) int)]
 [define
  GetCmpXchgFailureOrdering
  (foreign-procedure "LLVMGetCmpXchgFailureOrdering" (void*) int)]

 ;; --- Analysis.h -----------------------------------------------------------
 ;; action: 0 = abort-process, 1 = print-message, 2 = return-status
 [define
  VerifyModule                  ; (module, action, char** out-msg) -> bool (true
                                ; = broken)
  (foreign-procedure "LLVMVerifyModule" (void* int void*) int)]
 [define
  VerifyFunction
  (foreign-procedure "LLVMVerifyFunction" (void* int) int)]

 ;; --- Error.h ---------------------------------------------------------------
 [define
  GetErrorMessage               ; consumes the error, returns char*
                                ; (dispose-error-message!)
  (foreign-procedure "LLVMGetErrorMessage" (void*) void*)]
 [define
  DisposeErrorMessage
  (foreign-procedure "LLVMDisposeErrorMessage" (void*) void)]
 (define ConsumeError (foreign-procedure "LLVMConsumeError" (void*) void))

 ;; --- Target.h / TargetMachine.h
 ;; ----------------------------------------------
 [define
  GetDefaultTargetTriple        ; char*, dispose!
  (foreign-procedure "LLVMGetDefaultTargetTriple" () void*)]
 [define
  GetHostCPUName                ; char*, dispose!
  (foreign-procedure "LLVMGetHostCPUName" () void*)]
 [define
  GetHostCPUFeatures            ; char*, dispose!
  (foreign-procedure "LLVMGetHostCPUFeatures" () void*)]
 [define
  GetTargetFromTriple           ; (triple, target*, char** err) -> bool (true =
                                ; failed)
  (foreign-procedure "LLVMGetTargetFromTriple" (string void* void*) int)]
 [define
  CreateTargetMachine           ; (target, triple, cpu, features, opt, reloc,
                                ; code-model)
  [foreign-procedure
   "LLVMCreateTargetMachine"
   (void* string string string int int int)
   void*]]
 [define
  DisposeTargetMachine
  (foreign-procedure "LLVMDisposeTargetMachine" (void*) void)]
 ;; file-type: 0 = assembly, 1 = object
 [define
  TargetMachineEmitToFile       ; (tm, module, path, file-type, char** err) ->
                                ; bool (true = failed)
  [foreign-procedure
   "LLVMTargetMachineEmitToFile"
   (void* void* string int void*)
   int]]
 [define
  TargetMachineEmitToMemoryBuffer ; (tm, module, file-type, char** err, membuf*
                                  ; out)
  [foreign-procedure
   "LLVMTargetMachineEmitToMemoryBuffer"
   (void* void* int void* void*)
   int]]
 [define
  CreateTargetDataLayout
  (foreign-procedure "LLVMCreateTargetDataLayout" (void*) void*)]
 [define
  CopyStringRepOfTargetData     ; char*, dispose!
  (foreign-procedure "LLVMCopyStringRepOfTargetData" (void*) void*)]
 [define
  DisposeTargetData
  (foreign-procedure "LLVMDisposeTargetData" (void*) void)]
 ;; bitcode writer (BitWriter.h): a memory buffer the caller disposes
 [define
  WriteBitcodeToMemoryBuffer
  (foreign-procedure "LLVMWriteBitcodeToMemoryBuffer" (void*) void*)]
 (define GetBufferStart (foreign-procedure "LLVMGetBufferStart" (void*) void*))
 (define GetBufferSize (foreign-procedure "LLVMGetBufferSize" (void*) size_t))
 [define
  DisposeMemoryBuffer
  (foreign-procedure "LLVMDisposeMemoryBuffer" (void*) void)]

 ;; --- generic value/type inspection (read-only; used by sll:unbuild) --------

 (define-getter GetOperand "LLVMGetOperand" (void* unsigned-int) void*)
 (define-getter GetNumOperands "LLVMGetNumOperands" (void*) int)
 (define-getter GetNumArgOperands "LLVMGetNumArgOperands" (void*) unsigned-int)
 ;; IsA* casts: value if it is one, NULL otherwise
 (define-getter IsAInstruction "LLVMIsAInstruction" (void*) void*)
 (define-getter IsAArgument "LLVMIsAArgument" (void*) void*)
 (define-getter IsAFunction "LLVMIsAFunction" (void*) void*)
 (define-getter IsAGlobalVariable "LLVMIsAGlobalVariable" (void*) void*)
 (define-getter IsAGlobalAlias "LLVMIsAGlobalAlias" (void*) void*)
 (define-getter DeleteFunction "LLVMDeleteFunction" (void*) void)
 (define-getter GetFirstUse "LLVMGetFirstUse" (void*) void*)
 (define-getter GetNextUse "LLVMGetNextUse" (void*) void*)
 (define-getter GetUser "LLVMGetUser" (void*) void*)
 (define-getter IsAMDNode "LLVMIsAMDNode" (void*) void*)
 (define-getter IsAMDString "LLVMIsAMDString" (void*) void*)
 (define-getter IsAValueAsMetadata "LLVMIsAValueAsMetadata" (void*) void*)
 [define-getter
  MDStringInContext2            ; -> LLVMMetadataRef
  "LLVMMDStringInContext2"
  (void* string size_t)
  void*]
 [define-getter
  MDNodeInContext2              ; (ctx, MetadataRef*, count)
  "LLVMMDNodeInContext2"
  (void* void* size_t)
  void*]
 [define-getter
  MetadataAsValue2              ; MetadataRef -> ValueRef
  "LLVMMetadataAsValue"
  (void* void*)
  void*]
 (define-getter ValueAsMetadata "LLVMValueAsMetadata" (void*) void*)
 [define-getter
  AddNamedMetadataOperand       ; (module, name, MDNode-as-value)
  "LLVMAddNamedMetadataOperand"
  (void* string void*)
  void]
 ;; LLVMMetadataKind from DebugInfo.h, including ConstantAsMetadata and
 ;; LocalAsMetadata. Unlike LLVMIsAMDNode this distinguishes value wrappers.
 (define-getter GetMetadataKind "LLVMGetMetadataKind" (void*) unsigned-int)
 [define-getter
  GetMDString                   ; (value, unsigned* len-out)
  "LLVMGetMDString"
  (void* void*)
  void*]
 [define-getter
  GetMDNodeNumOperands
  "LLVMGetMDNodeNumOperands"
  (void*)
  unsigned-int]
 [define
  GetMDNodeOperands             ; fills a ValueRef array
  (foreign-procedure "LLVMGetMDNodeOperands" (void* void*) void)]
 (define-getter MetadataTypeInContext "LLVMMetadataTypeInContext" (void*) void*)
 ;; LLVM 20 removed MMX (optional entry: refused there, never resolved)
 (define-getter X86MMXTypeInContext "LLVMX86MMXTypeInContext" (void*) void*)
 (define-getter X86AMXTypeInContext "LLVMX86AMXTypeInContext" (void*) void*)
 [define-getter
  TargetExtTypeInContext        ; (ctx, name, ty*, n, uint*, n)
  "LLVMTargetExtTypeInContext"
  (void* string void* unsigned-int void* unsigned-int)
  void*]
 (define-getter GetTargetExtTypeName "LLVMGetTargetExtTypeName" (void*) void*)
 [define-getter
  GetTargetExtTypeNumTypeParams
  "LLVMGetTargetExtTypeNumTypeParams"
  (void*)
  unsigned-int]
 [define-getter
  GetTargetExtTypeTypeParam
  "LLVMGetTargetExtTypeTypeParam"
  (void* unsigned-int)
  void*]
 [define-getter
  GetTargetExtTypeNumIntParams
  "LLVMGetTargetExtTypeNumIntParams"
  (void*)
  unsigned-int]
 [define-getter
  GetTargetExtTypeIntParam
  "LLVMGetTargetExtTypeIntParam"
  (void* unsigned-int)
  unsigned-int]
 (define-getter IsAConstantInt "LLVMIsAConstantInt" (void*) void*)
 (define-getter IsAConstantFP "LLVMIsAConstantFP" (void*) void*)
 (define-getter IsAConstantExpr "LLVMIsAConstantExpr" (void*) void*)
 [define-getter
  IsAConstantPointerNull
  "LLVMIsAConstantPointerNull"
  (void*)
  void*]
 [define-getter
  IsAConstantAggregateZero
  "LLVMIsAConstantAggregateZero"
  (void*)
  void*]
 (define-getter IsAConstantDataArray "LLVMIsAConstantDataArray" (void*) void*)
 (define-getter IsAConstantArray "LLVMIsAConstantArray" (void*) void*)
 (define-getter IsAConstantStruct "LLVMIsAConstantStruct" (void*) void*)
 (define-getter IsAConstantVector "LLVMIsAConstantVector" (void*) void*)
 (define-getter IsAConstantDataVector "LLVMIsAConstantDataVector" (void*) void*)
 (define-getter IsAInlineAsm "LLVMIsAInlineAsm" (void*) void*)
 (define-getter IsABlockAddress "LLVMIsABlockAddress" (void*) void*)
 (define-getter IsAConstantTokenNone "LLVMIsAConstantTokenNone" (void*) void*)
 (define-getter IsUndef "LLVMIsUndef" (void*) int)
 (define-getter IsPoison "LLVMIsPoison" (void*) int)
 (define-getter GetPoison "LLVMGetPoison" (void*) void*)
 [define-getter
  ConstIntGetSExtValue
  "LLVMConstIntGetSExtValue"
  (void*)
  integer-64]
 [define-getter
  ConstIntGetZExtValue
  "LLVMConstIntGetZExtValue"
  (void*)
  unsigned-64]
 [define-getter
  ConstRealGetDouble
  "LLVMConstRealGetDouble"
  (void* void*)
  double]
 [define-getter
  GetAggregateElement
  "LLVMGetAggregateElement"
  (void* unsigned-int)
  void*]
 (define-getter IsConstantString "LLVMIsConstantString" (void*) int)
 (define-getter GetAsString "LLVMGetAsString" (void* void*) void*)
 (define-getter GetConstOpcode "LLVMGetConstOpcode" (void*) int)
 (define-getter GetElementType "LLVMGetElementType" (void*) void*)
 (define-getter GetArrayLength2 "LLVMGetArrayLength2" (void*) unsigned-64)
 (define-getter GetArrayLength "LLVMGetArrayLength" (void*) unsigned-int)
 (define-getter GetVectorSize "LLVMGetVectorSize" (void*) unsigned-int)
 [define-getter
  CountStructElementTypes
  "LLVMCountStructElementTypes"
  (void*)
  unsigned-int]
 [define-getter
  StructGetTypeAtIndex
  "LLVMStructGetTypeAtIndex"
  (void* unsigned-int)
  void*]
 (define-getter GetStructName "LLVMGetStructName" (void*) void*)
 [define-getter
  GetPointerAddressSpace
  "LLVMGetPointerAddressSpace"
  (void*)
  unsigned-int]
 (define-getter HalfTypeInContext "LLVMHalfTypeInContext" (void*) void*)
 (define-getter BFloatTypeInContext "LLVMBFloatTypeInContext" (void*) void*)
 (define-getter FP128TypeInContext "LLVMFP128TypeInContext" (void*) void*)
 (define-getter X86FP80TypeInContext "LLVMX86FP80TypeInContext" (void*) void*)
 (define-getter PPCFP128TypeInContext "LLVMPPCFP128TypeInContext" (void*) void*)
 (define-getter GetAlignment "LLVMGetAlignment" (void*) unsigned-int)
 (define-getter GetAllocatedType "LLVMGetAllocatedType" (void*) void*)
 [define-getter
  GetGEPSourceElementType
  "LLVMGetGEPSourceElementType"
  (void*)
  void*]
 (define-getter CountIncoming "LLVMCountIncoming" (void*) unsigned-int)
 [define-getter
  GetIncomingValue
  "LLVMGetIncomingValue"
  (void* unsigned-int)
  void*]
 [define-getter
  GetIncomingBlock
  "LLVMGetIncomingBlock"
  (void* unsigned-int)
  void*]
 (define-getter GetCalledValue "LLVMGetCalledValue" (void*) void*)
 (define-getter GetCalledFunctionType "LLVMGetCalledFunctionType" (void*) void*)
 (define-getter GetNormalDest "LLVMGetNormalDest" (void*) void*)
 (define-getter GetUnwindDest "LLVMGetUnwindDest" (void*) void*)
 (define-getter GetNumSuccessors "LLVMGetNumSuccessors" (void*) unsigned-int)
 (define-getter GetSuccessor "LLVMGetSuccessor" (void* unsigned-int) void*)
 (define-getter GetNumClauses "LLVMGetNumClauses" (void*) unsigned-int)
 (define-getter GetClause "LLVMGetClause" (void* unsigned-int) void*)
 (define-getter IsCleanup "LLVMIsCleanup" (void*) int)
 (define-getter GetNumHandlers "LLVMGetNumHandlers" (void*) unsigned-int)
 (define-getter GetHandlers "LLVMGetHandlers" (void* void*) void)
 (define-getter GetParentCatchSwitch "LLVMGetParentCatchSwitch" (void*) void*)
 (define-getter GetNumIndices "LLVMGetNumIndices" (void*) unsigned-int)
 (define-getter GetIndices "LLVMGetIndices" (void*) void*)
 [define-getter
  GetNumMaskElements
  "LLVMGetNumMaskElements"
  (void*)
  unsigned-int]
 (define-getter GetMaskValue "LLVMGetMaskValue" (void* unsigned-int) int)
 (define-getter GetUndefMaskElem "LLVMGetUndefMaskElem" () int)
 [define-getter
  GetInlineAsmAsmString
  "LLVMGetInlineAsmAsmString"
  (void* void*)
  void*]
 [define-getter
  GetInlineAsmConstraintString
  "LLVMGetInlineAsmConstraintString"
  (void* void*)
  void*]
 [define-getter
  GetInlineAsmHasSideEffects
  "LLVMGetInlineAsmHasSideEffects"
  (void*)
  int]
 [define-getter
  GetInlineAsmNeedsAlignedStack
  "LLVMGetInlineAsmNeedsAlignedStack"
  (void*)
  int]
 (define-getter GetInlineAsmDialect "LLVMGetInlineAsmDialect" (void*) int)
 (define-getter GetInlineAsmCanUnwind "LLVMGetInlineAsmCanUnwind" (void*) int)
 [define-getter
  GetBlockAddressFunction
  "LLVMGetBlockAddressFunction"
  (void*)
  void*]
 [define-getter
  GetBlockAddressBasicBlock
  "LLVMGetBlockAddressBasicBlock"
  (void*)
  void*]
 (define-getter HasPersonalityFn "LLVMHasPersonalityFn" (void*) int)
 (define-getter GetPersonalityFn "LLVMGetPersonalityFn" (void*) void*)
 (define-getter GetInitializer "LLVMGetInitializer" (void*) void*)
 (define-getter GetGlobalParent "LLVMGetGlobalParent" (void*) void*)
 (define-getter GetTypeContext "LLVMGetTypeContext" (void*) void*)
 [define
  ContextSetDiagnosticHandler
  [foreign-procedure
   "LLVMContextSetDiagnosticHandler"
   (void* void* void*)
   void]]
 [define-getter
  GetDiagInfoDescription
  "LLVMGetDiagInfoDescription"
  (void*)
  void*]
 (define-getter GetDiagInfoSeverity "LLVMGetDiagInfoSeverity" (void*) int)
 (define-getter IsGlobalConstant "LLVMIsGlobalConstant" (void*) int)
 (define-getter HasMetadata "LLVMHasMetadata" (void*) int)
 [define-getter
  GetFunctionCallConv
  "LLVMGetFunctionCallConv"
  (void*)
  unsigned-int]
 [define-getter
  GetAttributeCountAtIndex
  "LLVMGetAttributeCountAtIndex"
  (void* unsigned-int)
  unsigned-int]
 (define-getter GetVisibility "LLVMGetVisibility" (void*) int)
 (define-getter IsThreadLocal "LLVMIsThreadLocal" (void*) int)
 (define-getter GetSection "LLVMGetSection" (void*) void*)
 [define-getter
  GetNumOperandBundles
  "LLVMGetNumOperandBundles"
  (void*)
  unsigned-int]
 (define-getter IsAtomicSingleThread "LLVMIsAtomicSingleThread" (void*) int)
 (define-getter IsPackedStruct "LLVMIsPackedStruct" (void*) int)
 (define-getter GetBasicBlockName "LLVMGetBasicBlockName" (void*) void*)
 (define-getter GetFirstGlobalAlias "LLVMGetFirstGlobalAlias" (void*) void*)
 (define-getter GetNextGlobalAlias "LLVMGetNextGlobalAlias" (void*) void*)
 [define-getter
  AddAlias2                     ; (module, value-type, addrspace, aliasee, name)
  "LLVMAddAlias2"
  (void* void* unsigned-int void* string)
  void*]
 (define-getter AliasGetAliasee "LLVMAliasGetAliasee" (void*) void*)
 (define-getter GetNextGlobalIFunc "LLVMGetNextGlobalIFunc" (void*) void*)
 [define-getter
  AddGlobalIFunc                ; (m, name, len, fnty, addrspace, resolver)
  "LLVMAddGlobalIFunc"
  (void* string size_t void* unsigned-int void*)
  void*]
 [define-getter
  GetGlobalIFuncResolver
  "LLVMGetGlobalIFuncResolver"
  (void*)
  void*]
 [define
  SetGlobalIFuncResolver
  (foreign-procedure "LLVMSetGlobalIFuncResolver" (void* void*) void)]
 [define
  SetModuleInlineAsm2
  (foreign-procedure "LLVMSetModuleInlineAsm2" (void* string size_t) void)]
 [define
  AliasSetAliasee
  (foreign-procedure "LLVMAliasSetAliasee" (void* void*) void)]
 (define-getter GetFirstGlobalIFunc "LLVMGetFirstGlobalIFunc" (void*) void*)
 (define-getter GetFirstNamedMetadata "LLVMGetFirstNamedMetadata" (void*) void*)
 (define-getter GetModuleInlineAsm "LLVMGetModuleInlineAsm" (void* void*) void*)
 (define-getter GetTarget "LLVMGetTarget" (void*) void*)
 (define-getter GetDataLayoutStr "LLVMGetDataLayoutStr" (void*) void*)

 ;; normalization (stripping constructs sll does not model)
 (define-getter StripModuleDebugInfo "LLVMStripModuleDebugInfo" (void*) int)
 [define-getter
  InstructionGetAllMetadataOtherThanDebugLoc
  "LLVMInstructionGetAllMetadataOtherThanDebugLoc"
  (void* void*)
  void*]
 [define-getter
  ValueMetadataEntriesGetKind
  "LLVMValueMetadataEntriesGetKind"
  (void* unsigned-int)
  unsigned-int]
 [define-getter
  DisposeValueMetadataEntries
  "LLVMDisposeValueMetadataEntries"
  (void*)
  void]
 [define-getter
  SetMetadata                   ; NULL node clears the kind
  "LLVMSetMetadata"
  (void* unsigned-int void*)
  void]
 [define-getter
  GetMetadata                   ; -> node value or NULL
  "LLVMGetMetadata"
  (void* unsigned-int)
  void*]
 [define
  GetMDKindIDInContext
  [foreign-procedure
   "LLVMGetMDKindIDInContext"
   (void* string unsigned-int)
   unsigned-int]]
 (define-getter GlobalClearMetadata "LLVMGlobalClearMetadata" (void*) void)
 [define-getter
  GetAttributesAtIndex          ; (fn, index, attr-array out)
  "LLVMGetAttributesAtIndex"
  (void* unsigned-int void*)
  void]
 (define-getter IsEnumAttribute "LLVMIsEnumAttribute" (void*) int)
 (define-getter IsStringAttribute "LLVMIsStringAttribute" (void*) int)
 [define-getter
  GetEnumAttributeKind
  "LLVMGetEnumAttributeKind"
  (void*)
  unsigned-int]
 [define-getter
  GetStringAttributeKind        ; (attr, unsigned* len out)
  "LLVMGetStringAttributeKind"
  (void* void*)
  void*]
 [define-getter
  RemoveEnumAttributeAtIndex
  "LLVMRemoveEnumAttributeAtIndex"
  (void* unsigned-int unsigned-int)
  void]
 [define-getter
  RemoveStringAttributeAtIndex
  "LLVMRemoveStringAttributeAtIndex"
  (void* unsigned-int string unsigned-int)
  void]
 [define-getter
  GetCallSiteAttributeCount
  "LLVMGetCallSiteAttributeCount"
  (void* unsigned-int)
  unsigned-int]
 [define-getter
  GetCallSiteAttributes
  "LLVMGetCallSiteAttributes"
  (void* unsigned-int void*)
  void]
 [define-getter
  RemoveCallSiteEnumAttribute
  "LLVMRemoveCallSiteEnumAttribute"
  (void* unsigned-int unsigned-int)
  void]
 [define-getter
  RemoveCallSiteStringAttribute
  "LLVMRemoveCallSiteStringAttribute"
  (void* unsigned-int string unsigned-int)
  void]
 [define
  GetEnumAttributeKindForName   ; 0 = no such attribute
  [foreign-procedure
   "LLVMGetEnumAttributeKindForName"
   (string size_t)
   unsigned-int]]
 [define
  CreateEnumAttribute
  [foreign-procedure
   "LLVMCreateEnumAttribute"
   (void* unsigned-int unsigned-64)
   void*]]
 [define
  CreateStringAttribute
  [foreign-procedure
   "LLVMCreateStringAttribute"
   (void* string unsigned-int string unsigned-int)
   void*]]
 [define
  AddAttributeAtIndex
  (foreign-procedure "LLVMAddAttributeAtIndex" (void* unsigned-int void*) void)]
 [define
  AddCallSiteAttribute
  [foreign-procedure
   "LLVMAddCallSiteAttribute"
   (void* unsigned-int void*)
   void]]
 [define-getter
  GetEnumAttributeValue
  "LLVMGetEnumAttributeValue"
  (void*)
  unsigned-64]
 [define-getter
  GetStringAttributeValue       ; (attr, unsigned* len out)
  "LLVMGetStringAttributeValue"
  (void* void*)
  void*]
 (define-getter IsTypeAttribute "LLVMIsTypeAttribute" (void*) int)
 [define-getter
  SetInstructionCallConv
  "LLVMSetInstructionCallConv"
  (void* unsigned-int)
  void]
 [define-getter
  GetInstructionCallConv
  "LLVMGetInstructionCallConv"
  (void*)
  unsigned-int]
 [define-getter
  SetUnnamedAddress             ; 0 = no unnamed_addr
  "LLVMSetUnnamedAddress"
  (void* int)
  void]
 (define-getter SetVisibility "LLVMSetVisibility" (void* int) void)
 (define-getter SetSection "LLVMSetSection" (void* string) void)
 (define-getter SetThreadLocal "LLVMSetThreadLocal" (void* int) void)
 ;; named struct types
 (define-getter StructCreateNamed "LLVMStructCreateNamed" (void* string) void*)
 [define-getter
  StructSetBody                 ; (struct-type, elem-array, count, packed?)
  "LLVMStructSetBody"
  (void* void* unsigned-int int)
  void]
 ;; constant expressions
 [define-getter
  ConstGEP2                     ; (elem-type, ptr-const, index-array, count)
  "LLVMConstGEP2"
  (void* void* void* unsigned-int)
  void*]
 [define-getter
  ConstInBoundsGEP2
  "LLVMConstInBoundsGEP2"
  (void* void* void* unsigned-int)
  void*]
 (define-getter ConstPtrToInt "LLVMConstPtrToInt" (void* void*) void*)
 (define-getter ConstIntToPtr "LLVMConstIntToPtr" (void* void*) void*)
 (define-getter ConstBitCast "LLVMConstBitCast" (void* void*) void*)
 (define-getter ConstAddrSpaceCast "LLVMConstAddrSpaceCast" (void* void*) void*)
 [define-getter
  ConstGEPWithNoWrapFlags       ; flags: inbounds 1, nusw 2, nuw 4
  "LLVMConstGEPWithNoWrapFlags"
  (void* void* void* unsigned-int unsigned-int)
  void*]
 (define-getter ConstTrunc "LLVMConstTrunc" (void* void*) void*)
 (define-getter ConstAdd "LLVMConstAdd" (void* void*) void*)
 (define-getter ConstNSWAdd "LLVMConstNSWAdd" (void* void*) void*)
 (define-getter ConstNUWAdd "LLVMConstNUWAdd" (void* void*) void*)
 (define-getter ConstSub "LLVMConstSub" (void* void*) void*)
 (define-getter ConstNSWSub "LLVMConstNSWSub" (void* void*) void*)
 (define-getter ConstNUWSub "LLVMConstNUWSub" (void* void*) void*)
 (define-getter ConstMul "LLVMConstMul" (void* void*) void*)
 (define-getter ConstNSWMul "LLVMConstNSWMul" (void* void*) void*)
 (define-getter ConstNUWMul "LLVMConstNUWMul" (void* void*) void*)
 (define-getter ConstXor "LLVMConstXor" (void* void*) void*)
 [define-getter
  ConstExtractElement
  "LLVMConstExtractElement"
  (void* void*)
  void*]
 [define-getter
  ConstInsertElement
  "LLVMConstInsertElement"
  (void* void* void*)
  void*]
 [define-getter
  ConstShuffleVector
  "LLVMConstShuffleVector"
  (void* void* void*)
  void*]

 (define-getter IsAConstant "LLVMIsAConstant" (void*) void*)
 [define-getter
  IsExternallyInitialized
  "LLVMIsExternallyInitialized"
  (void*)
  int]
 (define-getter HasPrefixData "LLVMHasPrefixData" (void*) int)
 (define-getter HasPrologueData "LLVMHasPrologueData" (void*) int)
 [define-getter
  SetGC                         ; void* so NULL can clear the gc name
  "LLVMSetGC"
  (void* void*)
  void]
 (define SetGCString (foreign-procedure "LLVMSetGC" (void* string) void))
 (define-getter GetGC "LLVMGetGC" (void*) void*)
 [define
  SetAtomicSingleThread
  (foreign-procedure "LLVMSetAtomicSingleThread" (void* int) void)]
 [define
  SetExternallyInitialized
  (foreign-procedure "LLVMSetExternallyInitialized" (void* int) void)]
 [define-getter
  CreateOperandBundle           ; (tag, tag-len, arg-array, count)
  "LLVMCreateOperandBundle"
  (string size_t void* unsigned-int)
  void*]
 (define-getter DisposeOperandBundle "LLVMDisposeOperandBundle" (void*) void)
 [define-getter
  GetOperandBundleAtIndex       ; caller disposes the result
  "LLVMGetOperandBundleAtIndex"
  (void* unsigned-int)
  void*]
 [define-getter
  GetOperandBundleTag           ; (bundle, size_t* len-out)
  "LLVMGetOperandBundleTag"
  (void* void*)
  void*]
 [define-getter
  GetNumOperandBundleArgs
  "LLVMGetNumOperandBundleArgs"
  (void*)
  unsigned-int]
 [define-getter
  GetOperandBundleArgAtIndex
  "LLVMGetOperandBundleArgAtIndex"
  (void* unsigned-int)
  void*]
 [define-getter
  BuildCallWithOperandBundles   ; (b, fnty, fn, args, n, bundles, nb, name)
  "LLVMBuildCallWithOperandBundles"
  (void* void* void* void* unsigned-int void* unsigned-int string)
  void*]
 [define-getter
  BuildInvokeWithOperandBundles
  "LLVMBuildInvokeWithOperandBundles"
  (void* void* void* void* unsigned-int void* void* void* unsigned-int string)
  void*]
 [define-getter
  GetTypeByName2                ; named struct lookup; NULL if absent
  "LLVMGetTypeByName2"
  (void* string)
  void*]
 (define-getter IsOpaqueStruct "LLVMIsOpaqueStruct" (void*) int)
 (define-getter IsLiteralStruct "LLVMIsLiteralStruct" (void*) int)
 [define-getter
  ScalableVectorType
  "LLVMScalableVectorType"
  (void* unsigned-int)
  void*]
 [define-getter
  ConstIntOfStringAndSize       ; big integers via decimal text
  "LLVMConstIntOfStringAndSize"
  (void* string unsigned-int unsigned-8)
  void*]
 [define-getter
  PrintValueToString            ; char*, dispose!
  "LLVMPrintValueToString"
  (void*)
  void*]
 [define-getter
  AddGlobalInAddressSpace
  "LLVMAddGlobalInAddressSpace"
  (void* void* string unsigned-int)
  void*]
 [define-getter
  SetComdat                     ; void* so NULL can clear it
  "LLVMSetComdat"
  (void* void*)
  void]
 (define-getter SetDLLStorageClass "LLVMSetDLLStorageClass" (void* int) void)
 [define-getter
  ConstNamedStruct              ; (named-struct-type, constant-array, count)
  "LLVMConstNamedStruct"
  (void* void* unsigned-int)
  void*]

 ;; --- IRReader.h
 ;; -----------------------------------------------------------------
 [define
  ParseIRInContext              ; (ctx, membuf, module* out, char** err) -> bool
                                ; (true = failed); consumes membuf
  (foreign-procedure "LLVMParseIRInContext" (void* void* void* void*) int)]
 [define
  CreateMemoryBufferWithMemoryRangeCopy ; (data, len, name); copies data
  [foreign-procedure
   "LLVMCreateMemoryBufferWithMemoryRangeCopy"
   (void* size_t string)
   void*]]

 ;; --- Transforms/PassBuilder.h
 ;; ------------------------------------------------
 [define
  RunPasses                     ; (module, passes-string, tm-or-null, options)
                                ; -> LLVMErrorRef
  (foreign-procedure "LLVMRunPasses" (void* string void* void*) void*)]
 [define
  CreatePassBuilderOptions
  (foreign-procedure "LLVMCreatePassBuilderOptions" () void*)]
 [define
  DisposePassBuilderOptions
  (foreign-procedure "LLVMDisposePassBuilderOptions" (void*) void)]

 ;; --- Orc.h / LLJIT.h
 ;; -----------------------------------------------------------
 [define
  OrcCreateNewThreadSafeContext
  (foreign-procedure "LLVMOrcCreateNewThreadSafeContext" () void*)]
 [define
  OrcThreadSafeContextGetContext
  (foreign-procedure "LLVMOrcThreadSafeContextGetContext" (void*) void*)]
 [define
  OrcDisposeThreadSafeContext
  (foreign-procedure "LLVMOrcDisposeThreadSafeContext" (void*) void)]
 [define
  OrcCreateNewThreadSafeModule  ; consumes module; tsctx stays ours
  (foreign-procedure "LLVMOrcCreateNewThreadSafeModule" (void* void*) void*)]
 [define
  OrcDisposeThreadSafeModule    ; only if NOT handed to the JIT
  (foreign-procedure "LLVMOrcDisposeThreadSafeModule" (void*) void)]
 [define
  OrcCreateLLJITBuilder
  (foreign-procedure "LLVMOrcCreateLLJITBuilder" () void*)]
 [define
  OrcDisposeLLJITBuilder
  (foreign-procedure "LLVMOrcDisposeLLJITBuilder" (void*) void)]
 [define
  OrcJITTargetMachineBuilderCreateFromTargetMachine ; consumes the machine
  [foreign-procedure
   "LLVMOrcJITTargetMachineBuilderCreateFromTargetMachine"
   (void*)
   void*]]
 [define
  OrcLLJITBuilderSetJITTargetMachineBuilder         ; the builder takes the JTMB
  [foreign-procedure
   "LLVMOrcLLJITBuilderSetJITTargetMachineBuilder"
   (void* void*)
   void]]
 [define
  OrcCreateLLJIT                ; (LLJIT* out, builder-or-null) -> LLVMErrorRef
  (foreign-procedure "LLVMOrcCreateLLJIT" (void* void*) void*)]
 [define
  OrcDisposeLLJIT               ; -> LLVMErrorRef
  (foreign-procedure "LLVMOrcDisposeLLJIT" (void*) void*)]
 [define
  OrcLLJITGetMainJITDylib
  (foreign-procedure "LLVMOrcLLJITGetMainJITDylib" (void*) void*)]
 [define
  OrcLLJITGetGlobalPrefix
  (foreign-procedure "LLVMOrcLLJITGetGlobalPrefix" (void*) char)]
 [define
  OrcLLJITGetTripleString
  (foreign-procedure "LLVMOrcLLJITGetTripleString" (void*) void*)]
 [define
  OrcLLJITGetDataLayoutStr
  (foreign-procedure "LLVMOrcLLJITGetDataLayoutStr" (void*) void*)]
 [define
  OrcCreateDynamicLibrarySearchGeneratorForProcess
  [foreign-procedure
   "LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess"
   (void* char void* void*)
   void*]]
 [define
  OrcJITDylibAddGenerator
  (foreign-procedure "LLVMOrcJITDylibAddGenerator" (void* void*) void)]
 [define
  OrcLLJITAddLLVMIRModule       ; consumes TSM even on error -> LLVMErrorRef
  (foreign-procedure "LLVMOrcLLJITAddLLVMIRModule" (void* void* void*) void*)]
 [define
  OrcLLJITLookup                ; (jit, uint64* out-addr, name) -> LLVMErrorRef
  (foreign-procedure "LLVMOrcLLJITLookup" (void* void* string) void*)]]
