;;; LLVM 20 compares non-integral pointer properties at LLJIT admission, but the
;;; C API cannot set LLJIT's layout. Carry extra non-integral spaces in a module
;;; flag across admission, then restore the exact layout in LLJIT's IR transform
;;; layer, immediately before its compile layer. Never optimize or emit machine
;;; code with the temporary admission layout. The module flag survives ORC's
;;; context cloning. No C++ layout access or native shim.
[library
 (llvm jit-layout)
 (export install! prepare! restoration-observer)
 [import
  (chezscheme)
  (prefix (llvm raw) LLVM)
  (prefix (llvm base) base:)
  (prefix (llvm datalayout) dl:)
  (prefix (llvm config) config:)]
 (define key "schemell.jit.non-integral-layout")
 (define restoration-observer (make-parameter (lambda (layout) (void))))
 (define (flag m) (LLVMGetModuleFlag m key (string-length key)))
 [define
  (physical forms)
  (filter (lambda (f) (not (eq? (car f) 'non-integral))) forms)]
 [define
  (spaces forms)
  [apply
   append
   (map cdr (filter (lambda (f) (eq? (car f) 'non-integral)) forms))]]
 [define
  (compatible? original host)
  [let
   ((a (dl:parse original)) (b (dl:parse host)))
   [and
    (equal? (physical a) (physical b))
    (for-all (lambda (n) (memv n (spaces a))) (spaces b))]]]
 [define
  (prepare! m host)
  [when
   (config:capability? 'jit-layout-bridge)
   [unless
    (zero? (flag m))
    (base:error 'jit:add-module! "reserved SchemeLL JIT layout flag" key)]
   [let
    ((original (base:cstring->string (LLVMGetDataLayoutStr m))))
    [unless
     (or (string=? original "") (string=? original host))
     [unless
      (compatible? original host)
      [base:error
       'jit:add-module!
       "module data layout is incompatible with this JIT"
       original
       host]]
     [LLVMAddModuleFlag
      m
      0
      key
      (string-length key)
      [LLVMMDStringInContext2
       (LLVMGetModuleContext m)
       original
       (string-length original)]]
     (LLVMSetDataLayout m host)]]]]
 [define
  (callback-error e)
  [LLVMCreateStringError
   [guard
    (formatting-error (else "Scheme JIT callback failed"))
    [if
     (condition? e)
     (with-output-to-string (lambda () (display-condition e)))
     "Scheme JIT callback raised a non-condition value"]]]]
 [define
  (install! j host)
  [if
   (not (config:capability? 'jit-layout-bridge))
   (lambda () (void))
   [let*
    [[restore
      [foreign-callable
       [lambda
        (ignored m)
        [guard
         (e (else (callback-error e)))
         [let
          ((md (flag m)))
          [unless
           (zero? md)
           [let*
            [(v (LLVMMetadataAsValue2 (LLVMGetModuleContext m) md))
             (out (foreign-alloc 4))]
            [dynamic-wind
             (lambda () (void))
             [lambda
              ()
              [when
               (zero? (LLVMIsAMDString v))
               (error 'jit-layout "invalid saved layout metadata")]
              [let*
               [(p (LLVMGetMDString v out))
                [original
                 (base:cstring->string/len p (foreign-ref 'unsigned-32 out 0))]]
               [unless
                (compatible? original host)
                [error
                 'jit-layout
                 "saved layout is incompatible with this JIT"
                 original
                 host]]
               (LLVMSetDataLayout m original)
               ((restoration-observer) original)]]
             (lambda () (foreign-free out))]]]]
         0]]
       (void* void*)
       void*]]
     [transform
      [foreign-callable
       [lambda
        (ignored tsm-out responsibility)
        [guard
         (e (else (callback-error e)))
         [LLVMOrcThreadSafeModuleWithModuleDo
          (foreign-ref 'void* tsm-out 0)
          (foreign-callable-entry-point restore)
          0]]]
       (void* void* void*)
       void*]]]
    (lock-object restore)
    (lock-object transform)
    [LLVMOrcIRTransformLayerSetTransform
     (LLVMOrcLLJITGetIRTransformLayer j)
     (foreign-callable-entry-point transform)
     0]
    ;; Caller releases only after disposing LLJIT, including unused modules.
    (lambda () (unlock-object transform) (unlock-object restore))]]]]
