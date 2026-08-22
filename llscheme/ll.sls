;;; (llscheme ll) -- LLVM IR as s-expressions: the first llscheme layer.
;;; Grammar and rationale: project/ll-design.md. Import as:
;;;   (prefix (llscheme ll) ll:)
;;;
;;; An ll program is plain data -- a list of module items:
;;;   (define <type> (@name (<type> %arg) ...) <block> ...)
;;;   (declare <type> (@name <type> ...))
;;; A function body is a list of block groups, mirroring LLVM's object
;;; model (functions contain blocks contain instructions):
;;;   (label %name <insn> ... <terminator>)
;;; The first group is the entry block. Instructions are textual LLVM IR
;;; transliterated: commas dropped, parens added, `%x = rhs` as
;;; (= %x (rhs)), types kept in IR position, phi pairs as (value %label).
;;;
;;; The interpreter builds an (llvm ir) module in two passes per program
;;; (declare all functions, then emit bodies) and two passes per function
;;; (create all blocks, then emit their instructions), so branches and
;;; phi incoming may reference blocks defined later. phi is the only
;;; permitted forward reference to a *value*; everything else must be
;;; defined textually before use.
(library (llscheme ll)
  (export build jit dump)
  (import (chezscheme)
          (prefix (llvm base) base:)
          (prefix (llvm ir) ir:)
          (prefix (llvm jit) jit:))

  (define (ll-error msg . irritants)
    (apply base:error 'll:build msg irritants))

  ;; ---- names ---------------------------------------------------------------

  (define (sigil-name? ch x)
    (and (symbol? x)
         (let ([s (symbol->string x)])
           (and (> (string-length s) 1) (char=? (string-ref s 0) ch)))))

  (define (local-name? x) (sigil-name? #\% x))   ; %value or %label
  (define (global-name? x) (sigil-name? #\@ x))  ; @function

  (define (strip-sigil x)
    (let ([s (symbol->string x)])
      (substring s 1 (string-length s))))

  ;; ---- types -----------------------------------------------------------------

  (define (int-bits t)   ; i1, i8, ..., iN -> N; anything else -> #f
    (let ([s (symbol->string t)])
      (and (> (string-length s) 1)
           (char=? (string-ref s 0) #\i)
           (let ([n (string->number (substring s 1 (string-length s)))])
             (and (fixnum? n) (positive? n) n)))))

  (define (resolve-type ctx t)
    (unless (symbol? t) (ll-error "invalid type" t))
    (case t
      [(ptr) (ir:pointer-type ctx)]
      [(float) (ir:float-type ctx)]
      [(double) (ir:double-type ctx)]
      [(void) (ir:void-type ctx)]
      [else
       (let ([bits (int-bits t)])
         (unless bits (ll-error "unknown type" t))
         (ir:int-type ctx bits))]))

  ;; ---- per-function build state ------------------------------------------------

  (define-record-type fstate
    (fields ctx builder globals locals blocks fname (mutable phis)))

  ;; ---- operands ------------------------------------------------------------------

  ;; ty types bare literals; #f when the position carries no type of its own
  ;; (then literals must come as a (type value) group).
  (define (resolve-operand st ty form)
    (cond
      [(local-name? form)
       (or (hashtable-ref (fstate-locals st) form #f)
           (ll-error "unbound local (only phi may reference later definitions)"
                     form (fstate-fname st)))]
      [(global-name? form)
       (or (hashtable-ref (fstate-globals st) form #f)
           (ll-error "unbound global" form (fstate-fname st)))]
      [(and (integer? form) (exact? form))
       (unless ty (ll-error "integer literal needs a type annotation" form))
       (ir:const-int ty form)]
      [(flonum? form)
       (unless ty (ll-error "float literal needs a type annotation" form))
       (ir:const-real ty form)]
      [(and (pair? form) (pair? (cdr form)) (null? (cddr form)))
       ;; typed operand group: (type value)
       (resolve-operand st (resolve-type (fstate-ctx st) (car form)) (cadr form))]
      [else (ll-error "invalid operand" form (fstate-fname st))]))

  ;; ---- blocks -----------------------------------------------------------------------

  (define (label-form? f) (and (pair? f) (eq? (car f) 'label)))

  (define (block-by-name st name)
    (unless (local-name? name) (ll-error "invalid label name" name))
    (or (hashtable-ref (fstate-blocks st) name #f)
        (ll-error "unknown label" name (fstate-fname st))))

  (define (block-ref st form)   ; a (label %x) branch target
    (unless (and (label-form? form) (pair? (cdr form)) (null? (cddr form))
                 (local-name? (cadr form)))
      (ll-error "expected branch target (label %name)" form (fstate-fname st)))
    (block-by-name st (cadr form)))

  ;; block group: (label %name <insn> ... <terminator>)
  (define (check-block-group g fname)
    (unless (label-form? g)
      (ll-error "instruction outside a block (expected (label %name insn ...))"
                g fname))
    (unless (and (pair? (cdr g)) (local-name? (cadr g)))
      (ll-error "block label must be a %name" g fname))
    (when (null? (cddr g))
      (ll-error "empty block" (cadr g) fname))
    (let ([final (car (last-pair g))])
      (unless (and (pair? final) (memq (car final) terminator-ops))
        (ll-error "block does not end in a terminator" (cadr g) fname))))

  (define (add-block! st f name)
    (when (hashtable-ref (fstate-blocks st) name #f)
      (ll-error "duplicate label" name (fstate-fname st)))
    (hashtable-set! (fstate-blocks st) name
                    (ir:append-block (fstate-ctx st) f (strip-sigil name))))

  ;; ---- the opcode tables ----------------------------------------------------------------

  (define binops             ; (op type a b)
    `((add . ,ir:build-add) (sub . ,ir:build-sub) (mul . ,ir:build-mul)
      (sdiv . ,ir:build-sdiv) (udiv . ,ir:build-udiv)
      (srem . ,ir:build-srem) (urem . ,ir:build-urem)
      (and . ,ir:build-and) (or . ,ir:build-or) (xor . ,ir:build-xor)
      (shl . ,ir:build-shl) (lshr . ,ir:build-lshr) (ashr . ,ir:build-ashr)
      (fadd . ,ir:build-fadd) (fsub . ,ir:build-fsub)
      (fmul . ,ir:build-fmul) (fdiv . ,ir:build-fdiv)
      (frem . ,ir:build-frem)))

  (define casts              ; (op type value to type)
    `((trunc . ,ir:build-trunc) (zext . ,ir:build-zext) (sext . ,ir:build-sext)
      (fptrunc . ,ir:build-fptrunc) (fpext . ,ir:build-fpext)
      (fptosi . ,ir:build-fp->si) (fptoui . ,ir:build-fp->ui)
      (sitofp . ,ir:build-si->fp) (uitofp . ,ir:build-ui->fp)
      (ptrtoint . ,ir:build-ptr->int) (inttoptr . ,ir:build-int->ptr)
      (bitcast . ,ir:build-bitcast)))

  ;; ---- instruction flags -----------------------------------------------------
  ;; Flags sit where IR writes them: between the opcode and the type (for
  ;; fcmp, before the predicate). They are peeled off the front of the
  ;; argument list, validated per opcode, and applied to the built
  ;; instruction via the C API setters (getelementptr takes its no-wrap
  ;; mask at construction instead).

  ;; LLVMFastMathFlags bits; cross-checked against the installed headers
  ;; by tests/test-coverage.ss
  (define fmf-bits
    '((reassoc . 1) (nnan . 2) (ninf . 4) (nsz . 8)
      (arcp . 16) (contract . 32) (afn . 64) (fast . 127)))

  ;; LLVMGEPNoWrapFlags bits; inbounds implies nusw, as in the IR parser
  (define gep-flag-bits
    '((inbounds . 3) (nusw . 2) (nuw . 4)))

  (define wrap-flag-ops '(add sub mul shl))
  (define exact-flag-ops '(udiv sdiv lshr ashr))

  (define flag-symbols
    '(nsw nuw exact disjoint nneg volatile inbounds nusw
       reassoc nnan ninf nsz arcp contract afn fast))

  ;; call-position flags we do not support yet -- reject loudly rather
  ;; than silently changing semantics
  (define unsupported-flags '(tail musttail notail))

  ;; split leading flag symbols from the rest of an instruction's arguments
  (define (span-flags rest)
    (let loop ([r rest] [flags '()])
      (if (and (pair? r) (symbol? (car r)) (memq (car r) flag-symbols))
          (loop (cdr r) (cons (car r) flags))
          (values (reverse flags) r))))

  (define (require-flag-op op ops flag form)
    (unless (memq op ops)
      (ll-error "flag is not valid for this opcode" flag form)))

  (define (apply-flags! op v flags form)
    (let ([fmf (fold-left
                 (lambda (mask flag)
                   (case flag
                     [(nsw) (require-flag-op op wrap-flag-ops flag form)
                      (ir:set-nsw! v) mask]
                     [(nuw) (require-flag-op op wrap-flag-ops flag form)
                      (ir:set-nuw! v) mask]
                     [(exact) (require-flag-op op exact-flag-ops flag form)
                      (ir:set-exact! v) mask]
                     [(disjoint) (require-flag-op op '(or) flag form)
                      (ir:set-disjoint! v) mask]
                     [(nneg) (require-flag-op op '(zext) flag form)
                      (ir:set-nneg! v) mask]
                     [(volatile) (require-flag-op op '(load store) flag form)
                      (ir:set-volatile! v) mask]
                     [(inbounds nusw)
                      (ll-error "flag is only valid on getelementptr" flag form)]
                     [else (bitwise-ior mask (cdr (assq flag fmf-bits)))]))
                 0 flags)])
      (unless (zero? fmf)
        (unless (ir:can-use-fast-math-flags? v)
          (ll-error "fast-math flags are not valid on this instruction" op form))
        (ir:set-fast-math-flags! v fmf))))

  (define (gep-flags-mask flags form)
    (fold-left (lambda (mask flag)
                 (cond
                   [(assq flag gep-flag-bits) =>
                    (lambda (p) (bitwise-ior mask (cdr p)))]
                   [else (ll-error "flag is not valid on getelementptr" flag form)]))
               0 flags))

  ;; apply post-hoc flags; getelementptr consumed its flags at construction
  (define (finish-op! op flags form v)
    (unless (or (null? flags) (eq? op 'getelementptr))
      (apply-flags! op v flags form))
    v)

  ;; instructions with no bindable result
  (define no-result-ops '(store br ret))

  ;; instructions that may (and must) end a block
  (define terminator-ops '(ret br))

  ;; trailing attribute groups, e.g. (align 8)
  (define (apply-attrs! v attrs form)
    (for-each
      (lambda (a)
        (if (and (pair? a) (eq? (car a) 'align)
                 (pair? (cdr a)) (null? (cddr a))
                 (fixnum? (cadr a)) (positive? (cadr a)))
            (ir:set-alignment! v (cadr a))
            (ll-error "unknown attribute" a form)))
      attrs))

  ;; ---- instruction emission ------------------------------------------------------------

  (define (emit-op st form name)
    (let-values ([(flags args) (span-flags (cdr form))])
      (let ([op (car form)]
            [b (fstate-builder st)] [ctx (fstate-ctx st)])
        (define (arity n shape)
          (unless (= (length args) n)
            (ll-error (string-append "expected " shape) form (fstate-fname st))))
        (define (arity>= n shape)
          (unless (>= (length args) n)
            (ll-error (string-append "expected " shape) form (fstate-fname st))))
        (when (and (pair? args) (memq (car args) unsupported-flags))
          (ll-error "instruction flag not yet supported" (car args) form))
        (finish-op! op flags form
          (cond
            [(assq op binops) =>
             (lambda (entry)
               (arity 3 "(op type a b)")
               (let ([ty (resolve-type ctx (car args))])
                 ((cdr entry) b
                  (resolve-operand st ty (cadr args))
                  (resolve-operand st ty (caddr args))
                  name)))]
            [(assq op casts) =>
             (lambda (entry)
               (arity 4 "(op type value to type)")
               (unless (eq? (caddr args) 'to)
                 (ll-error "cast expects `to`" form))
               (let ([ty (resolve-type ctx (car args))]
                     [dst (resolve-type ctx (cadddr args))])
                 ((cdr entry) b (resolve-operand st ty (cadr args)) dst name)))]
            [else
             (case op
               [(icmp fcmp)
                (arity 4 "(icmp/fcmp pred type a b)")
                (let* ([pred (car args)]
                       [ty (resolve-type ctx (cadr args))]
                       [x (resolve-operand st ty (caddr args))]
                       [y (resolve-operand st ty (cadddr args))])
                  (if (eq? op 'icmp)
                    (ir:build-icmp b pred x y name)
                    (ir:build-fcmp b pred x y name)))]
               [(select)
                (arity 3 "(select (i1 c) (type a) (type b))")
                (ir:build-select b
                                 (resolve-operand st #f (car args))
                                 (resolve-operand st #f (cadr args))
                                 (resolve-operand st #f (caddr args))
                                 name)]
               [(fneg)
                (arity 2 "(fneg type value)")
                (ir:build-fneg b
                               (resolve-operand st (resolve-type ctx (car args)) (cadr args))
                               name)]
               [(phi)
                (arity>= 2 "(phi type [value %label] ...)")
                ;; emit empty; incoming resolves at end of function, when
                ;; every value and label is bound (IR's only forward value ref)
                (let ([ph (ir:build-phi b (resolve-type ctx (car args)) name)])
                  (fstate-phis-set! st (cons (list ph (car args) (cdr args) form)
                                         (fstate-phis st)))
                  ph)]
               [(call)
                (arity>= 2 "(call type callee (type arg) ...)")
                (let ([retty (resolve-type ctx (car args))]
                      [callee-form (cadr args)]
                      [groups (cddr args)])
                  (for-each
                    (lambda (g)
                      (unless (and (pair? g) (pair? (cdr g)) (null? (cddr g)))
                        (ll-error "call argument must be (type value)" g form)))
                    groups)
                  (when (and (eq? (ir:type-kind retty) 'void)
                          (not (string=? name "")))
                    (ll-error "cannot bind the result of a void call" form))
                  (let* ([atys (map (lambda (g) (resolve-type ctx (car g))) groups)]
                         [avals (map (lambda (g ty) (resolve-operand st ty (cadr g)))
                                  groups atys)])
                    (ir:build-call b (ir:function-type retty atys)
                                   (resolve-operand st #f callee-form)
                                   avals name)))]
               [(load)
                (arity>= 2 "(load type (ptr p) ...)")
                (let ([v (ir:build-load b (resolve-type ctx (car args))
                                        (resolve-operand st #f (cadr args))
                                        name)])
                  (apply-attrs! v (cddr args) form)
                  v)]
               [(store)
                (arity>= 2 "(store (type v) (ptr p) ...)")
                (let ([s (ir:build-store b
                                         (resolve-operand st #f (car args))
                                         (resolve-operand st #f (cadr args)))])
                  (apply-attrs! s (cddr args) form)
                  s)]
               [(alloca)
                (arity>= 1 "(alloca type ...)")
                (let ([v (ir:build-alloca b (resolve-type ctx (car args)) name)])
                  (apply-attrs! v (cdr args) form)
                  v)]
               [(getelementptr)
                (arity>= 2 "(getelementptr type (ptr p) (type index) ...)")
                (ir:build-gep/flags b (resolve-type ctx (car args))
                                    (resolve-operand st #f (cadr args))
                                    (map (lambda (g) (resolve-operand st #f g)) (cddr args))
                                    (gep-flags-mask flags form)
                                    name)]
               [(br)
                (cond
                  [(= (length args) 1)         ; (br (label %x))
                   (ir:build-br b (block-ref st (car args)))]
                  [(= (length args) 4)         ; (br i1 %c (label %a) (label %b))
                   (let ([c (resolve-operand st (resolve-type ctx (car args))
                                             (cadr args))])
                     (ir:build-cond-br b c
                                       (block-ref st (caddr args))
                                       (block-ref st (cadddr args))))]
                  [else (ll-error "expected (br (label %x)) or (br i1 %c (label %a) (label %b))"
                          form (fstate-fname st))])]
               [(ret)
                (cond
                  [(equal? args '(void)) (ir:build-ret-void b)]
                  [(= (length args) 2)
                   (ir:build-ret b (resolve-operand st (resolve-type ctx (car args))
                                                    (cadr args)))]
                  [else (ll-error "expected (ret void) or (ret type value)"
                          form (fstate-fname st))])]
               [else (ll-error "unknown opcode" op form)])])))))

  (define (emit-insn! st form)
    (cond
      [(not (pair? form))
       (ll-error "invalid instruction" form (fstate-fname st))]
      [(label-form? form)
       (ll-error "blocks do not nest: (label ...) inside a block"
                 form (fstate-fname st))]
      [(eq? (car form) '=)
       (unless (and (= (length form) 3) (local-name? (cadr form))
                    (pair? (caddr form)))
         (ll-error "expected (= %name (op ...))" form (fstate-fname st)))
       (let ([lhs (cadr form)] [rhs (caddr form)])
         (when (memq (car rhs) no-result-ops)
           (ll-error "instruction produces no result to bind" form))
         (when (hashtable-ref (fstate-locals st) lhs #f)
           (ll-error "duplicate local name" lhs (fstate-fname st)))
         (hashtable-set! (fstate-locals st) lhs
                         (emit-op st rhs (strip-sigil lhs))))]
      [else (emit-op st form "")]))

  (define (fixup-phis! st)
    (for-each
      (lambda (rec)
        (let ([ph (car rec)]
              [ty (resolve-type (fstate-ctx st) (cadr rec))]
              [pairs (caddr rec)]
              [form (cadddr rec)])
          (ir:phi-add-incoming! ph
            (map (lambda (pr)
                   (unless (and (pair? pr) (pair? (cdr pr)) (null? (cddr pr)))
                     (ll-error "phi incoming must be [value %label]" pr form))
                   (cons (resolve-operand st ty (car pr))
                         (block-by-name st (cadr pr))))
                 pairs))))
      (reverse (fstate-phis st))))

  ;; ---- module items ---------------------------------------------------------------------

  (define (item-kind item)
    (unless (and (pair? item) (memq (car item) '(define declare)))
      (ll-error "unknown module item (expected define or declare)" item))
    (car item))

  (define (item-signature item)  ; -> (values ret-type-form name-sym rest)
    (unless (>= (length item) 3)
      (ll-error "malformed module item" item))
    (let ([sig (caddr item)])
      (unless (and (pair? sig) (global-name? (car sig)))
        (ll-error "function signature must be (@name ...)" item))
      (values (cadr item) (car sig) (cdr sig))))

  (define (check-param p item)
    (unless (and (pair? p) (pair? (cdr p)) (null? (cddr p))
                 (local-name? (cadr p)))
      (ll-error "parameter must be (type %name)" p item)))

  ;; pass 1: create every function up front, so bodies may call in any order
  (define (declare-item! ctx m globals item)
    (let ([kind (item-kind item)])
      (let-values ([(retty-form fname rest) (item-signature item)])
        (when (hashtable-ref globals fname #f)
          (ll-error "duplicate global name" fname))
        (let* ([retty (resolve-type ctx retty-form)]
               [ptys (case kind
                       [(define)
                        (map (lambda (p)
                               (check-param p item)
                               (resolve-type ctx (car p)))
                             rest)]
                       [(declare) (map (lambda (t) (resolve-type ctx t)) rest)])])
          (hashtable-set! globals fname
                          (ir:add-function m (strip-sigil fname)
                                           (ir:function-type retty ptys)))))))

  ;; pass 2: emit the body of each define
  (define (emit-item! ctx m globals item)
    (when (eq? (item-kind item) 'define)
      (let-values ([(retty-form fname params) (item-signature item)])
        (let ([f (hashtable-ref globals fname #f)]
              [body (cdddr item)]
              [builder (ir:make-builder ctx)])
          (when (null? body)
            (ll-error "function body is empty" fname))
          (let ([st (make-fstate ctx builder globals (make-eq-hashtable)
                                 (make-eq-hashtable) fname '())])
            ;; bind and name the parameters
            (let loop ([ps params] [i 0])
              (unless (null? ps)
                (let ([pname (cadr (car ps))]
                      [pv (ir:function-param f i)])
                  (when (hashtable-ref (fstate-locals st) pname #f)
                    (ll-error "duplicate parameter name" pname fname))
                  (ir:set-value-name! pv (strip-sigil pname))
                  (hashtable-set! (fstate-locals st) pname pv)
                  (loop (cdr ps) (+ i 1)))))
            ;; every body form is a block group; the first is the entry
            ;; block. Create all blocks before emitting, so branches and
            ;; phi incoming may reference blocks defined later.
            (for-each (lambda (g) (check-block-group g fname)) body)
            (for-each (lambda (g) (add-block! st f (cadr g))) body)
            (for-each
              (lambda (g)
                (ir:position-at-end! builder (block-by-name st (cadr g)))
                (for-each (lambda (fm) (emit-insn! st fm)) (cddr g)))
              body)
            (fixup-phis! st)
            (ir:builder-dispose! builder))))))

  ;; ---- entry points --------------------------------------------------------------------------

  ;; Build an ll program (a list of module items) into a fresh (llvm ir)
  ;; module in the given context.
  (define (build ctx name prog)
    (let ([m (ir:make-module ctx name)]
          [globals (make-eq-hashtable)])
      (for-each (lambda (item) (declare-item! ctx m globals item)) prog)
      (for-each (lambda (item) (emit-item! ctx m globals item)) prog)
      m))

  ;; Build, verify and JIT a program; returns the jit record, ready for
  ;; (jit:function j "name").
  (define (jit prog)
    (let* ([jc (jit:make-context)]
           [m (build (jit:context-ir jc) "ll" prog)]
           [j (jit:make)])
      (ir:verify-module m)
      (jit:add-module! j jc m)
      (jit:context-dispose! jc)
      j))

  ;; Build a program and return its textual LLVM IR (for humans).
  (define (dump prog)
    (let* ([ctx (ir:make-context)]
           [m (build ctx "ll" prog)]
           [s (ir:module->string m)])
      (ir:module-dispose! m)
      (ir:context-dispose! ctx)
      s)))
