;;; (llvm target) -- native target initialization, target machines,
;;; object/assembly emission.
[library
 (llvm target)
 [export
  initialize-native!
  initialize-target!
  native-target-name
  native-object-format
  default-triple
  host-cpu-name
  host-cpu-features
  machine?
  make-machine
  machine-dispose!
  machine-live-ptr
  machine-triple
  machine-data-layout
  configure-module!
  emit-object-file
  emit-assembly-file
  emit-object-bytevector
  emit-assembly-string]
 [import
  (chezscheme)
  (prefix (llvm raw) LLVM)
  (prefix (llvm base) base:)
  (prefix (llvm ir) ir:)
  (prefix (llvm datalayout) dl:)]

 ;; The generic LLVMInitializeNativeTarget is a static inline in Target.h, so it
 ;; does not exist as a symbol; we call the per-target functions that do. Map
 ;; Chez's machine type to LLVM's target name ("X86", "AArch64"): the host's
 ;; backend, which is also what host-specific inline asm must be written for.
 [define
  (native-target-name)
  [case
   (machine-type)
   ((a6le ta6le a6nt ta6nt a6osx ta6osx i3le ti3le a6fb ta6fb) "X86")
   ((arm64le tarm64le arm64osx tarm64osx) "AArch64")
   [else
    [base:error
     'target:initialize-native!
     "unsupported machine type"
     (machine-type)]]]]

 ;; The relocatable object format the host's default target machine emits:
 ;; Mach-O on macOS, COFF on Windows, ELF everywhere else. Section names follow
 ;; it (".text" on ELF, "__TEXT,__text" on Mach-O).
 [define
  (native-object-format)
  [case
   (machine-type)
   ((a6osx ta6osx arm64osx tarm64osx) 'mach-o)
   ((a6nt ta6nt i3nt ti3nt) 'coff)
   (else 'elf)]]

 (define native-initialized? #f)

 ;; initialize one backend by LLVM's name ("X86", "AArch64", ...); returns #f
 ;; when this libLLVM was built without it
 [define
  (initialize-target! target)
  [and
   (foreign-entry? (string-append "LLVMInitialize" target "Target"))
   [begin
    [for-each
     [lambda
      (component)
      [let
       ((name (string-append "LLVMInitialize" target component)))
       (when (foreign-entry? name) ((foreign-procedure name () void)))]]
     '("TargetInfo" "Target" "TargetMC" "AsmPrinter" "AsmParser")]
    #t]]]

 [define
  (initialize-native!)
  [unless
   native-initialized?
   (initialize-target! (native-target-name))
   (set! native-initialized? #t)]]

 [define
  (default-triple)
  (base:cstring->string/dispose (LLVMGetDefaultTargetTriple))]
 (define (host-cpu-name) (base:cstring->string/dispose (LLVMGetHostCPUName)))
 [define
  (host-cpu-features)
  (base:cstring->string/dispose (LLVMGetHostCPUFeatures))]

 [define
  (target-from-triple triple)
  [let
   ((target-out (foreign-alloc 8)))
   (foreign-set! 'unsigned-64 target-out 0 0)
   [let-values
    [[(failed msg-ptr)
      [base:call-with-out-ptr
       (lambda (err-out) (LLVMGetTargetFromTriple triple target-out err-out))]]]
    [let
     ((target (foreign-ref 'unsigned-64 target-out 0)))
     (foreign-free target-out)
     [base:check-bool
      'target:from-triple
      failed
      (base:cstring->string/dispose msg-ptr)]
     target]]]]

 [define
  (opt-level->int lvl)
  [case
   lvl
   ((none) 0)
   ((less) 1)
   ((default) 2)
   ((aggressive) 3)
   (else (base:error 'target:make-machine "unknown opt level" lvl))]]

 ;; ---- target machines -------------------------------------------------------

 [define-record-type
  (machine $make-machine machine?)
  (fields ptr triple (mutable state))
  (nongenerative llvm-machine-v0)]

 ;; (make-machine) -> host defaults, -O2 (make-machine triple cpu features
 ;; opt-level)
 [define
  make-machine
  [case-lambda
   [()
    [make-machine
     (default-triple)
     (host-cpu-name)
     (host-cpu-features)
     'default]]
   [(triple cpu features opt-level)
    (initialize-native!)
    [let
     ((target (target-from-triple triple)))
     [$make-machine
      [LLVMCreateTargetMachine
       target
       triple
       cpu
       features
       (opt-level->int opt-level)
       2                        ; reloc: PIC, works for both .o and JIT
       0]                       ; code model: default
      triple
      'owned]]]]]

 [define
  (machine-live-ptr tm)
  [unless
   (eq? (machine-state tm) 'owned)
   (base:error 'machine "target machine is no longer live" (machine-state tm))]
  (machine-ptr tm)]

 [define
  (machine-dispose! tm)
  [when
   (eq? (machine-state tm) 'owned)
   (LLVMDisposeTargetMachine (machine-ptr tm))
   (machine-state-set! tm 'disposed)]]

 ;; Stamp the module with the machine's triple and data layout, as codegen
 ;; expects for correct optimization/lowering. The optional third argument is a
 ;; list of NON-INTEGRAL address spaces appended as an ni: component (e.g. '(1)
 ;; for a moving-GC pointer space): without it, optimization passes may fold
 ;; addrspace(1) pointers through ptrtoint even though a relocating collector
 ;; can change their bits at any safepoint. The machine's stock layout never
 ;; carries ni, so it must be added HERE, before any passes run. Address space 0
 ;; cannot be non-integral (LLVM rejects ni:0).
 [define
  configure-module!
  [case-lambda
   ((m tm) (configure-module! m tm '()))
   [(m tm non-integral)
    (ir:set-module-data-layout! m (machine-data-layout tm non-integral))
    (ir:set-module-target-triple! m (machine-triple tm))]]]
 [define
  machine-data-layout
  [case-lambda
   ((tm) (machine-data-layout tm '()))
   [(tm non-integral)
    [let*
     [(td (LLVMCreateTargetDataLayout (machine-live-ptr tm)))
      [layout
       (base:cstring->string/dispose (LLVMCopyStringRepOfTargetData td))]]
     (LLVMDisposeTargetData td)
     (dl:with-non-integral layout non-integral)]]]]

 ;; ---- emission
 ;; ---------------------------------------------------------------

 ;; file-type: 0 = assembly, 1 = object
 [define
  (emit-to-file tm m path file-type)
  [let-values
   [[(failed msg-ptr)
     [base:call-with-out-ptr
      [lambda
       (err-out)
       [LLVMTargetMachineEmitToFile
        (machine-live-ptr tm)
        (ir:module-live-ptr m)
        path
        file-type
        err-out]]]]]
   [base:check-bool
    'target:emit-to-file
    failed
    (base:cstring->string/dispose msg-ptr)]
   ;; inline-asm parse errors report success + an error diagnostic
   (base:check-diagnostics! 'target:emit-to-file)]]

 (define (emit-object-file tm m path) (emit-to-file tm m path 1))
 (define (emit-assembly-file tm m path) (emit-to-file tm m path 0))

 ;; Fully in-memory emission (file-type as in emit-to-file).
 [define
  (emit-to-bytevector who tm m file-type)
  [let
   ((buf-out (foreign-alloc 8)))
   (foreign-set! 'unsigned-64 buf-out 0 0)
   [let-values
    [[(failed msg-ptr)
      [base:call-with-out-ptr
       [lambda
        (err-out)
        [LLVMTargetMachineEmitToMemoryBuffer
         (machine-live-ptr tm)
         (ir:module-live-ptr m)
         file-type
         err-out
         buf-out]]]]]
    [let
     ((buf (foreign-ref 'unsigned-64 buf-out 0)))
     (foreign-free buf-out)
     (base:check-bool who failed (base:cstring->string/dispose msg-ptr))
     (base:check-diagnostics! who)
     [let*
      [(start (LLVMGetBufferStart buf))
       (size (LLVMGetBufferSize buf))
       (bv (make-bytevector size))]
      [do
       ((i 0 (fx+ i 1)))
       ((fx= i size))
       (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 start i))]
      (LLVMDisposeMemoryBuffer buf)
      bv]]]]]

 [define
  (emit-object-bytevector tm m)
  (emit-to-bytevector 'target:emit-object-bytevector tm m 1)]

 [define
  (emit-assembly-string tm m)
  (utf8->string (emit-to-bytevector 'target:emit-assembly-string tm m 0))]]
