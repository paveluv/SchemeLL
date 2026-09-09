;;; (llvm base) -- layer 1 FFI utilities shared by the higher layers. C-string
;;; conversion, out-parameters, pointer arrays, LLVM errors as Scheme
;;; conditions. Assumes a 64-bit platform (8-byte pointers).
[library
 (llvm base)
 [export
  null-ptr
  null-ptr?
  error
  take-diagnostics!
  install-diagnostic-handler!
  check-diagnostics!
  cstring->string
  cstring->string/dispose
  cstring->string/len
  check-error-ref
  check-bool
  call-with-out-ptr
  call-with-out-ptr*
  call-with-pointer-array]
 (import (except (chezscheme) error) (prefix (llvm raw) LLVM))

 (define null-ptr 0)
 (define (null-ptr? p) (eqv? p 0))

 (define word-size 8)

 ;; ---- LLVM diagnostics -----------------------------------------------------
 ;; Many codegen problems (inline-asm parse errors above all) are reported
 ;; through a per-context diagnostic callback, not through return values.
 ;; Raising from inside the callback would unwind through LLVM's C++ frames, so
 ;; the handler only RECORDS; the project error raiser below drains the record
 ;; into whatever condition is raised next, and take-diagnostics! exposes it.

 (define captured-diagnostics '()) ; (severity . message), newest first

 (define severity-names '#(error warning remark note))

 [define
  diag-entry-point
  [let
   [[cb
     [foreign-callable
      [lambda
       (di payload)
       [let*
        [(cmsg (LLVMGetDiagInfoDescription di))
         (msg (or (cstring->string cmsg) "?"))
         (sev (LLVMGetDiagInfoSeverity di))]
        (LLVMDisposeMessage cmsg)
        [set!
         captured-diagnostics
         [cons
          (cons (if (< sev 4) (vector-ref severity-names sev) sev) msg)
          captured-diagnostics]]]]
      (void* void*)
      void]]]
   (lock-object cb)
   (foreign-callable-entry-point cb)]]

 [define
  (install-diagnostic-handler! ctx-ptr)
  (LLVMContextSetDiagnosticHandler ctx-ptr diag-entry-point null-ptr)]

 ;; drain and return captured diagnostics, oldest first
 [define
  (take-diagnostics!)
  (let ((d captured-diagnostics)) (set! captured-diagnostics '()) (reverse d))]

 ;; Some failures (inline-asm parse errors above all) are ONLY visible as
 ;; captured error-severity diagnostics: LLVM's emission entry points still
 ;; report success. Call after codegen.
 [define
  (check-diagnostics! who)
  [let*
   [(diags (take-diagnostics!))
    (errs (filter (lambda (d) (eq? (car d) 'error)) diags))]
   [unless
    (null? errs)
    [error
     who
     [apply
      string-append
      "codegen reported errors:"
      (map (lambda (d) (string-append "\n  " (cdr d))) errs)]]]]]

 [define
  (error who msg . irritants)
  [let
   ((diags (take-diagnostics!)))
   [raise
    [condition
     (make-error)
     (make-who-condition who)
     [make-message-condition
      [if
       (null? diags)
       msg
       [apply
        string-append
        msg
        " [llvm:"
        [fold-right
         (lambda (d acc) (cons* " " (symbol->string (car d)) ": " (cdr d) acc))
         '("]")
         diags]]]]
     (make-irritants-condition irritants)]]]]

 ;; Read a NUL-terminated UTF-8 string at an address; #f for NULL.
 [define
  (cstring->string addr)
  [and
   (not (null-ptr? addr))
   [let
    [[len
      [let
       loop
       ((i 0))
       (if (fxzero? (foreign-ref 'unsigned-8 addr i)) i (loop (fx+ i 1)))]]]
    (cstring->string/len addr len)]]]

 ;; Read exactly len bytes at addr as UTF-8 (for (ptr, length) style APIs).
 [define
  (cstring->string/len addr len)
  [let
   ((bv (make-bytevector len)))
   [do
    ((i 0 (fx+ i 1)))
    ((fx= i len))
    (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 addr i))]
   (utf8->string bv)]]

 ;; For char* results we own: convert, then LLVMDisposeMessage.
 [define
  (cstring->string/dispose addr)
  [and
   (not (null-ptr? addr))
   (let ((s (cstring->string addr))) (LLVMDisposeMessage addr) s)]]

 ;; Raise if an LLVMErrorRef is non-null; consumes and frees the message.
 [define
  (check-error-ref who err)
  [unless
   (null-ptr? err)
   [let*
    [(cmsg (LLVMGetErrorMessage err))
     (msg (or (cstring->string cmsg) "unknown LLVM error"))]
    (LLVMDisposeErrorMessage cmsg)
    (error who msg)]]]

 ;; For LLVMBool results where nonzero means failure and a char** out-param
 ;; holds the message (already read out by the caller).
 [define
  (check-bool who failed? msg)
  (unless (zero? failed?) (error who (or msg "LLVM call failed")))]

 ;; Allocate one zeroed pointer-sized out-slot, pass its address to proc, return
 ;; (values (proc addr) slot-contents). Frees the slot.
 [define
  (call-with-out-ptr proc)
  [let
   ((p (foreign-alloc word-size)))
   (foreign-set! 'unsigned-64 p 0 0)
   [let*
    ((r (proc p)) (v (foreign-ref 'unsigned-64 p 0)))
    (foreign-free p)
    (values r v)]]]

 ;; Same, but proc's result is discarded; returns just the slot contents.
 [define
  (call-with-out-ptr* proc)
  (let-values (((r v) (call-with-out-ptr proc))) v)]

 ;; Marshal a list of addresses into a temporary C array of pointers, pass
 ;; (array-address count) to proc, free the array afterwards. LLVM copies such
 ;; arrays during the call, so the temporary is safe.
 [define
  (call-with-pointer-array ptrs proc)
  [let*
   ((n (length ptrs)) (arr (foreign-alloc (fxmax word-size (fx* word-size n)))))
   [do
    ((i 0 (fx+ i 1)) (ps ptrs (cdr ps)))
    ((null? ps))
    (foreign-set! 'unsigned-64 arr (fx* word-size i) (car ps))]
   (let ((r (proc arr n))) (foreign-free arr) r)]]]
