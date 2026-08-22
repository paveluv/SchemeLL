;;; (llvm target) -- native target initialization, target machines,
;;; object/assembly emission.
(library (llvm target)
  (export initialize-native-target!
          default-target-triple host-cpu-name host-cpu-features
          target-machine? make-target-machine target-machine-dispose!
          target-machine-live-ptr target-machine-triple
          configure-module-for-target!
          emit-object-file emit-assembly-file emit-object-bytevector)
  (import (chezscheme) (llvm raw) (llvm base) (llvm ir))

  ;; The generic LLVMInitializeNativeTarget is a static inline in Target.h,
  ;; so it does not exist as a symbol; we call the per-target functions that
  ;; do. Map Chez's machine type to LLVM's target name.
  (define (native-target-name)
    (case (machine-type)
      [(a6le ta6le a6nt ta6nt a6osx ta6osx i3le ti3le) "X86"]
      [(arm64le tarm64le arm64osx tarm64osx) "AArch64"]
      [else (llvm-error 'initialize-native-target!
                        "unsupported machine type" (machine-type))]))

  (define native-initialized? #f)

  (define (initialize-native-target!)
    (unless native-initialized?
      (let ([target (native-target-name)])
        (for-each
         (lambda (component)
           (let ([name (string-append "LLVMInitialize" target component)])
             (when (foreign-entry? name)
               ((foreign-procedure name () void)))))
         '("TargetInfo" "Target" "TargetMC" "AsmPrinter" "AsmParser")))
      (set! native-initialized? #t)))

  (define (default-target-triple)
    (cstring->string/dispose (LLVMGetDefaultTargetTriple)))
  (define (host-cpu-name)
    (cstring->string/dispose (LLVMGetHostCPUName)))
  (define (host-cpu-features)
    (cstring->string/dispose (LLVMGetHostCPUFeatures)))

  (define (target-from-triple triple)
    (let ([target-out (foreign-alloc 8)])
      (foreign-set! 'unsigned-64 target-out 0 0)
      (let-values ([(failed msg-ptr)
                    (call-with-out-ptr
                     (lambda (err-out)
                       (LLVMGetTargetFromTriple triple target-out err-out)))])
        (let ([target (foreign-ref 'unsigned-64 target-out 0)])
          (foreign-free target-out)
          (check-bool 'target-from-triple failed (cstring->string/dispose msg-ptr))
          target))))

  (define (opt-level->int lvl)
    (case lvl
      [(none) 0] [(less) 1] [(default) 2] [(aggressive) 3]
      [else (llvm-error 'make-target-machine "unknown opt level" lvl)]))

  ;; ---- target machines -------------------------------------------------------

  (define-record-type (target-machine $make-target-machine target-machine?)
    (fields ptr triple (mutable state))
    (nongenerative llvm-target-machine-v0))

  ;; (make-target-machine)                       -> host defaults, -O2
  ;; (make-target-machine triple cpu features opt-level)
  (define make-target-machine
    (case-lambda
      [() (make-target-machine (default-target-triple)
                               (host-cpu-name) (host-cpu-features) 'default)]
      [(triple cpu features opt-level)
       (initialize-native-target!)
       (let ([target (target-from-triple triple)])
         ($make-target-machine
          (LLVMCreateTargetMachine target triple cpu features
                                   (opt-level->int opt-level)
                                   2   ; reloc: PIC, works for both .o and JIT
                                   0)  ; code model: default
          triple 'owned))]))

  (define (target-machine-live-ptr tm)
    (unless (eq? (target-machine-state tm) 'owned)
      (llvm-error 'target-machine "target machine is no longer live"
                  (target-machine-state tm)))
    (target-machine-ptr tm))

  (define (target-machine-dispose! tm)
    (when (eq? (target-machine-state tm) 'owned)
      (LLVMDisposeTargetMachine (target-machine-ptr tm))
      (target-machine-state-set! tm 'disposed)))

  ;; Stamp the module with the machine's triple and data layout, as codegen
  ;; expects for correct optimization/lowering.
  (define (configure-module-for-target! m tm)
    (set-module-target-triple! m (target-machine-triple tm))
    (let* ([td (LLVMCreateTargetDataLayout (target-machine-live-ptr tm))]
           [layout (cstring->string/dispose (LLVMCopyStringRepOfTargetData td))])
      (LLVMDisposeTargetData td)
      (set-module-data-layout! m layout)))

  ;; ---- emission ---------------------------------------------------------------

  ;; file-type: 0 = assembly, 1 = object
  (define (emit-to-file tm m path file-type)
    (let-values ([(failed msg-ptr)
                  (call-with-out-ptr
                   (lambda (err-out)
                     (LLVMTargetMachineEmitToFile
                      (target-machine-live-ptr tm) (module-live-ptr m)
                      path file-type err-out)))])
      (check-bool 'emit-to-file failed (cstring->string/dispose msg-ptr))))

  (define (emit-object-file tm m path) (emit-to-file tm m path 1))
  (define (emit-assembly-file tm m path) (emit-to-file tm m path 0))

  ;; Fully in-memory: returns the object code as a bytevector.
  (define (emit-object-bytevector tm m)
    (let ([buf-out (foreign-alloc 8)])
      (foreign-set! 'unsigned-64 buf-out 0 0)
      (let-values ([(failed msg-ptr)
                    (call-with-out-ptr
                     (lambda (err-out)
                       (LLVMTargetMachineEmitToMemoryBuffer
                        (target-machine-live-ptr tm) (module-live-ptr m)
                        1 err-out buf-out)))])
        (let ([buf (foreign-ref 'unsigned-64 buf-out 0)])
          (foreign-free buf-out)
          (check-bool 'emit-object-bytevector failed
                      (cstring->string/dispose msg-ptr))
          (let* ([start (LLVMGetBufferStart buf)]
                 [size (LLVMGetBufferSize buf)]
                 [bv (make-bytevector size)])
            (do ([i 0 (fx+ i 1)])
                ((fx= i size))
              (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 start i)))
            (LLVMDisposeMemoryBuffer buf)
            bv))))))
