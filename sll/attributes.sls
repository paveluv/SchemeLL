;;; (sll attributes) -- the function-attribute names sll can spell.
;;; Shared by sll:build (name -> kind) and sll:unbuild (kind -> name)
;;; so both directions agree by construction.
;;;
;;; Scope: VALUELESS enum attributes plus arbitrary string attributes
;;; (handled by the callers; this module only maps enum names). Valued
;;; enums (memory(...), uwtable(sync), alignstack(N), ...) and type
;;; attributes (sret(T), byval(T), ...) are not modeled -- see
;;; project/not-modeled.md. Kinds are resolved against the LOADED
;;; LLVM on first use (probed: LLVMGetEnumAttributeKindForName returns
;;; 0 for unknown names), so the table adapts across LLVM versions:
;;; a name this LLVM lacks simply drops out.
(library (sll attributes)
  (export enum-name->kind enum-kind->name)
  (import (chezscheme) (prefix (llvm raw) LLVM))

  ;; every valueless enum attribute name LLVM 19 resolves (probed
  ;; 2026-08-24); position validity (function vs param) is LLVM's
  ;; business -- the verifier judges, sll just spells
  (define enum-names
    '(allocalign allocptr alwaysinline builtin cold convergent
      disable_sanitizer_instrumentation fn_ret_thunk_extern hot
      inlinehint jumptable minsize mustprogress naked nest noalias
      nobuiltin nocallback nocapture nocf_check noduplicate nofree
      noimplicitfloat noinline nomerge nonlazybind nonnull noprofile
      norecurse noredzone noreturn nosanitize_bounds
      nosanitize_coverage nosync noundef nounwind
      null_pointer_is_valid optdebug optforfuzzing optnone optsize
      presplitcoroutine readnone readonly returned returns_twice
      safestack sanitize_address sanitize_hwaddress sanitize_memory
      sanitize_memtag sanitize_numerical_stability sanitize_thread
      shadowcallstack skipprofile speculatable
      speculative_load_hardening ssp sspreq sspstrong strictfp
      swiftasync swifterror swiftself willreturn writeonly))

  ;; (name . kind) for the names the loaded LLVM knows, resolved lazily
  ;; so importing this library never forces libLLVM to load early
  (define resolved
    (let ([table #f])
      (lambda ()
        (unless table
          (set! table
            (fold-right
              (lambda (n acc)
                (let* ([s (symbol->string n)]
                       [k (LLVMGetEnumAttributeKindForName
                            s (string-length s))])
                  (if (zero? k) acc (cons (cons n k) acc))))
              '() enum-names)))
        table)))

  (define (enum-name->kind sym)
    (cond [(assq sym (resolved)) => cdr] [else #f]))

  (define (enum-kind->name kind)
    (cond [(find (lambda (p) (= (cdr p) kind)) (resolved)) => car]
          [else #f])))
