;;; (tests normalize) -- strip constructs ll does not model from a parsed
;;; module, so the corpus round-trip measures what ll DOES model on files
;;; that also use what it doesn't (see project/coverage-plan.md, level 3).
;;; Every strip below corresponds to a row in project/not-modeled.md;
;;; modeling a construct later means deleting its strip here, at which
;;; point thousands of corpus files start testing it.
;;; Import as: (prefix (tests normalize) n:)
(library (tests normalize)
  (export normalize-module! comparable-ir)
  (import (chezscheme)
          (prefix (llvm base) base:)
          (prefix (llvm raw) LLVM)
          (prefix (llvm ir) ir:))

  (define function-index 4294967295)   ; LLVMAttributeIndex ~0U

  ;; strip every attribute at one index of a function or call site
  (define (strip-attrs-at! v idx count-at get-at remove-enum remove-string)
    (let ([n (count-at v idx)])
      (unless (zero? n)
        (let ([arr (foreign-alloc (fx* 8 n))])
          (get-at v idx arr)
          (do ([i 0 (fx+ i 1)])
              ((fx= i n))
            (let ([a (foreign-ref 'unsigned-64 arr (fx* 8 i))])
              (if (zero? (LLVMIsStringAttribute a))
                  ;; enum and type attributes both carry an enum kind
                  (remove-enum v idx (LLVMGetEnumAttributeKind a))
                  (let-values ([(kp klen)
                                (base:call-with-out-ptr
                                  (lambda (out)
                                    (LLVMGetStringAttributeKind a out)))])
                    (let ([k (base:cstring->string/len kp klen)])
                      (remove-string v idx k (string-length k)))))))
          (foreign-free arr)))))

  (define (strip-fn-attrs! f nparams)
    (do ([i -1 (+ i 1)])
        ((> i nparams))
      (strip-attrs-at! f (if (= i -1) function-index i)
                       LLVMGetAttributeCountAtIndex
                       LLVMGetAttributesAtIndex
                       LLVMRemoveEnumAttributeAtIndex
                       LLVMRemoveStringAttributeAtIndex)))

  (define (strip-callsite-attrs! c nargs)
    (do ([i -1 (+ i 1)])
        ((> i nargs))
      (strip-attrs-at! c (if (= i -1) function-index i)
                       LLVMGetCallSiteAttributeCount
                       LLVMGetCallSiteAttributes
                       LLVMRemoveCallSiteEnumAttribute
                       LLVMRemoveCallSiteStringAttribute)))

  ;; clear non-debug metadata attachments (debug ones go with
  ;; StripModuleDebugInfo at the module level)
  (define (strip-instruction-metadata! ins)
    (let ([nout (foreign-alloc 8)])
      (foreign-set! 'unsigned-64 nout 0 0)
      (let* ([entries (LLVMInstructionGetAllMetadataOtherThanDebugLoc ins nout)]
             [n (foreign-ref 'unsigned-64 nout 0)])
        (foreign-free nout)
        (do ([i 0 (fx+ i 1)])
            ((fx= i n))
          (LLVMSetMetadata ins (LLVMValueMetadataEntriesGetKind entries i)
                           base:null-ptr))
        (unless (base:null-ptr? entries)
          (LLVMDisposeValueMetadataEntries entries)))))

  (define call-opcodes '(45 5 67))     ; call, invoke, callbr

  (define (normalize-instruction! ins)
    (strip-instruction-metadata! ins)
    (when (memv (ir:instruction-opcode ins) call-opcodes)
      (LLVMSetInstructionCallConv ins 0)
      (strip-callsite-attrs! ins (LLVMGetNumArgOperands ins))))

  (define (normalize-function! f)
    (LLVMGlobalClearMetadata f)
    (LLVMSetGC f base:null-ptr)
    (LLVMSetComdat f base:null-ptr)
    (LLVMSetDLLStorageClass f 0)
    (LLVMSetFunctionCallConv f 0)
    (LLVMSetVisibility f 0)
    (LLVMSetSection f "")
    (LLVMSetUnnamedAddress f 0)
    (strip-fn-attrs! f (length (ir:function-params f)))
    (for-each
      (lambda (bb)
        (for-each normalize-instruction! (ir:block-instructions bb)))
      (ir:function-blocks f)))

  (define (normalize-global! g)
    (LLVMGlobalClearMetadata g)
    (LLVMSetComdat g base:null-ptr)
    (LLVMSetDLLStorageClass g 0)
    (LLVMSetVisibility g 0)
    (LLVMSetSection g "")
    (LLVMSetUnnamedAddress g 0)
    (LLVMSetThreadLocal g 0))

  ;; ---- textual canonicalization for the round-trip comparison ---------
  ;; Some constructs have no C API accessors at all in LLVM 19 and can
  ;; only be excluded from the comparison textually; each is a row in
  ;; project/not-modeled.md: dso_local, alloca swifterror/inalloca bits,
  ;; named syncscopes, global attributes (#N), plus ! metadata and
  ;; $ comdat declaration lines and blank separators.

  (define (find-sub s sub start)
    (let ([n (string-length s)] [m (string-length sub)])
      (let loop ([i start])
        (cond
          [(> (+ i m) n) #f]
          [(string=? (substring s i (+ i m)) sub) i]
          [else (loop (+ i 1))]))))

  (define (strip-token l tok)   ; remove every " tok " leaving one space
    (let loop ([l l])
      (let ([i (find-sub l (string-append " " tok " ") 0)])
        (if i
            (loop (string-append (substring l 0 i)
                                 (substring l (+ i 1 (string-length tok))
                                            (string-length l))))
            l))))

  (define (strip-syncscope l)   ; remove ` syncscope("...")`
    (let ([i (find-sub l " syncscope(\"" 0)])
      (if i
          (let ([close (find-sub l "\")" i)])
            (if close
                (string-append (substring l 0 i)
                               (substring l (+ close 2) (string-length l)))
                l))
          l)))

  (define (strip-global-attr l)  ; drop a trailing " #N" on @-lines
    (if (and (> (string-length l) 0) (char=? (string-ref l 0) #\@))
        (let loop ([i (- (string-length l) 1)])
          (cond
            [(and (> i 1) (char-numeric? (string-ref l i))) (loop (- i 1))]
            [(and (> i 1) (char=? (string-ref l i) #\#)
                  (char=? (string-ref l (- i 1)) #\space)
                  (< (+ i 1) (string-length l)))
             (substring l 0 (- i 1))]
            [else l]))
        l))

  (define (strip-comma-token l tok)  ; remove every ", tok"
    (let loop ([l l])
      (let ([i (find-sub l (string-append ", " tok) 0)])
        (if i
            (loop (string-append
                    (substring l 0 i)
                    (substring l (+ i 2 (string-length tok))
                               (string-length l))))
            l))))

  (define (strip-code-model l)  ; remove `, code_model "..."` (no C API)
    (let ([i (find-sub l ", code_model \"" 0)])
      (if i
          (let ([close (find-sub l "\"" (+ i 14))])
            (if close
                (string-append (substring l 0 i)
                               (substring l (+ close 1) (string-length l)))
                l))
          l)))

  (define (strip-preds-comment l)  ; `; preds = ...` reflects use-list
    (let ([i (find-sub l "; preds = " 0)])   ; order, which is not modeled
      (if i
          (let rtrim ([j i])
            (if (and (> j 0) (char=? (string-ref l (- j 1)) #\space))
                (rtrim (- j 1))
                (substring l 0 j)))
          l)))

  (define (canonical-line l)
    (strip-global-attr
      (strip-preds-comment
        (strip-code-model
          (strip-syncscope
            (strip-comma-token
              (strip-comma-token
                (strip-comma-token
                  (strip-comma-token
                    (strip-token (strip-token (strip-token l "dso_local")
                                              "swifterror")
                                 "inalloca")
                    "no_sanitize_address")
                  "no_sanitize_hwaddress")
                "sanitize_address_dyninit")
              "sanitize_memtag"))))))

  ;; printed module -> comparable text: drops module-identity lines,
  ;; ! metadata and $ comdat lines, blank lines; canonicalizes the rest
  (define (comparable-ir s)
    (let ([p (open-string-input-port s)] [out (open-output-string)])
      (let loop ()
        (let ([l (get-line p)])
          (unless (eof-object? l)
            (unless (or (zero? (string-length l))
                        (memv (string-ref l 0) '(#\; #\! #\$))
                        (and (>= (string-length l) 12)
                             (string=? (substring l 0 12) "attributes #"))
                        (and (>= (string-length l) 15)
                             (string=? (substring l 0 15) "source_filename")))
              (put-string out (canonical-line l))
              (put-char out #\newline))
            (loop))))
      (get-output-string out)))

  ;; NOT strippable via the C API (LLVM 19): dso_local, comdat,
  ;; externally_initialized, DLL storage, gc names, prefix/prologue data,
  ;; named module metadata. Files using them land in the mismatch or
  ;; not-modeled buckets and are accounted there.
  (define (normalize-module! m)
    (let ([mp (ir:module-live-ptr m)])
      ;; guarded: LLVM crashes stripping intentionally-malformed debug
      ;; info (e.g. Verifier/verify-dwarf-no-operands.ll -- a DISubprogram
      ;; with no operands); the leftover metadata then classifies the
      ;; file honestly as unmodeled instruction metadata
      (guard (e [#t #f]) (LLVMStripModuleDebugInfo mp))
      (LLVMSetTarget mp "")
      (LLVMSetDataLayout mp ""))
    (for-each normalize-global! (ir:module-globals m))
    (for-each normalize-function! (ir:module-functions m))))
