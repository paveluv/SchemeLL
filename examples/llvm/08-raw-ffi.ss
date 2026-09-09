;;; The bottom layer: (llvm raw) is the C API verbatim. The import prefix LLVM
;;; reconstructs the exact C names -- LLVMContextCreate here IS
;;; LLVMContextCreate in llvm-c. No safety nets down here.
[import
 (chezscheme)
 (prefix (llvm raw) LLVM)
 (prefix (llvm base) base:)
 (prefix (llvm config) config:)]

(config:load!)

(define ctx (LLVMContextCreate))

(define m (LLVMModuleCreateWithNameInContext "rawdemo" ctx))

(define i32 (LLVMInt32TypeInContext ctx))

[define
 fnty
 [base:call-with-pointer-array
  (list i32 i32)
  (lambda (arr n) (LLVMFunctionType i32 arr n 0))]]

(define f (LLVMAddFunction m "raw_add" fnty))

(define bb (LLVMAppendBasicBlockInContext ctx f "entry"))

(define b (LLVMCreateBuilderInContext ctx))

(LLVMPositionBuilderAtEnd b bb)

(LLVMBuildRet b (LLVMBuildAdd b (LLVMGetParam f 0) (LLVMGetParam f 1) "s"))

(printf "~a" (base:cstring->string/dispose (LLVMPrintModuleToString m)))

(LLVMDisposeBuilder b)

(LLVMDisposeModule m)

(LLVMContextDispose ctx)
