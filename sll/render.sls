;;; (sll render) -- render an sll program to textual LLVM IR,
;;; in pure Scheme (no LLVM involved). The output is not canonical --
;;; it only needs to PARSE; LLVM's printer canonicalizes both sides of
;;; any comparison.
;;;
;;; This is a testing tool (see project/coverage-plan.md): parsing the
;;; rendered text constructs modules through LLVM's parser, which uses
;;; the direct instruction constructors and never constant-folds -- the
;;; strict verifier for programs the C-API builder would fold.
;;;
;;; Caveat: all-digit %N names render explicitly (`%0 =`, `0:`), which
;;; the parser accepts only when the numbering matches its slot counter
;;; -- true by construction for sll:unbuild output, the intended input.
(library (sll render)
  (export sll->ll)
  (import (except (chezscheme) error)
          (prefix (llvm base) base:))

  (define (error msg . irritants)
    (apply base:error 'render:sll->ll msg irritants))

  ;; single-allocation join: the naive string-append fold is quadratic,
  ;; which shows on multi-thousand-instruction modules
  (define (join sep xs)
    (if (null? xs)
        ""
        (let ([out (open-output-string)])
          (put-string out (car xs))
          (for-each (lambda (x) (put-string out sep) (put-string out x))
                    (cdr xs))
          (get-output-string out))))

  ;; ---- names and strings -----------------------------------------------------

  (define (hex2 n)
    (let ([s (number->string n 16)])
      (string-upcase (if (< n 16) (string-append "0" s) s))))

  ;; a name may appear unquoted when it is an all-digit numeric ID (which
  ;; MUST stay raw -- quoting would make it a different name) or matches
  ;; LLVM's [a-zA-Z$._-][a-zA-Z$._0-9-]* (ASCII only; char-alphabetic?
  ;; is Unicode-aware and must not be used)
  (define (name-char? c digits?)
    (or (char<=? #\a c #\z) (char<=? #\A c #\Z)
        (and digits? (char<=? #\0 c #\9))
        (memv c '(#\$ #\. #\_ #\-))))
  (define (safe-name? s)
    (and (positive? (string-length s))
         (or (let all-digits ([i 0])
               (or (fx= i (string-length s))
                   (and (char<=? #\0 (string-ref s i) #\9)
                        (all-digits (fx+ i 1)))))
             (and (name-char? (string-ref s 0) #f)
                  (let ok ([i 1])
                    (or (fx= i (string-length s))
                        (and (name-char? (string-ref s i) #t)
                             (ok (fx+ i 1)))))))))

  (define (escape-bytes bv extra-nul?)
    (let ([out (open-output-string)])
      (do ([i 0 (fx+ i 1)])
          ((fx= i (bytevector-length bv)))
        (let ([b (bytevector-u8-ref bv i)])
          (if (and (fx>= b 32) (fx<= b 126)
                   (not (fx= b 34)) (not (fx= b 92))) ; " and \
              (put-char out (integer->char b))
              (begin (put-char out #\\) (put-string out (hex2 b))))))
      (when extra-nul? (put-string out "\\00"))
      (get-output-string out)))

  (define (quoted s)   ; an IR quoted string literal, escaped
    (string-append "\"" (escape-bytes (string->utf8 s) #f) "\""))

  (define (name->text sym)   ; %x / @x, quoted when needed
    (let* ([s (symbol->string sym)]
           [rest (substring s 1 (string-length s))])
      (string-append (substring s 0 1)
                     (if (safe-name? rest) rest (quoted rest)))))

  (define (label-text sym)   ; block label, no sigil
    (let ([rest (let ([s (symbol->string sym)])
                  (substring s 1 (string-length s)))])
      (if (safe-name? rest) rest (quoted rest))))

  ;; ---- types --------------------------------------------------------------------

  (define (split-variadic lst)
    (if (and (pair? lst) (eq? (car (last-pair lst)) 'variadic))
        (values (reverse (cdr (reverse lst))) #t)
        (values lst #f)))

  (define (type->text t)
    (cond
      [(symbol? t)
       (if (char=? (string-ref (symbol->string t) 0) #\%)
           (name->text t)
           (symbol->string t))]
      [(pair? t)
       (case (car t)
         [(ptr) (format "ptr addrspace(~a)" (cadr (cadr t)))]
         [(array) (format "[~a x ~a]" (cadr t) (type->text (caddr t)))]
         [(vector) (format "<~a x ~a>" (cadr t) (type->text (caddr t)))]
         [(scalable-vector)
          (format "<vscale x ~a x ~a>" (cadr t) (type->text (caddr t)))]
         [(struct)
          (if (null? (cdr t)) "{}"
              (format "{ ~a }" (join ", " (map type->text (cdr t)))))]
         [(packed-struct)
          (if (null? (cdr t)) "<{}>"
              (format "<{ ~a }>" (join ", " (map type->text (cdr t)))))]
         [(target-ext)
          (format "target(~a)"
                  (join ", "
                        (cons (quoted (cadr t))
                              (map (lambda (x)
                                     (if (integer? x)
                                         (number->string x)
                                         (type->text x)))
                                   (cddr t)))))]
         [(fn)
          (let-values ([(parts variadic?) (split-variadic (cdr t))])
            (format "~a (~a)" (type->text (car parts))
                    (join ", " (append (map type->text (cdr parts))
                                       (if variadic? '("...") '())))))]
         [else (error "cannot render type" t)])]
      [else (error "cannot render type" t)]))

  ;; ---- constants and operands -----------------------------------------------------

  ;; fp constants render bit-exactly in IR's hex forms. sll carries them
  ;; as Scheme flonums (unbuild guarantees exact double representability
  ;; and rejects non-double NaNs), so the target-type bits are derivable:
  ;; half/bfloat/float/double use the plain 16-hex double form (the
  ;; parser converts exactly-representable values), x86_fp80 needs 0xK,
  ;; fp128 0xL, ppc_fp128 0xM.
  (define (double-bits x)   ; the 64 bits of x, as an exact integer
    (let ([bv (make-bytevector 8)])
      (bytevector-ieee-double-set! bv 0 x (endianness big))
      (do ([i 0 (fx+ i 1)]
           [n 0 (+ (* n 256) (bytevector-u8-ref bv i))])
          ((fx= i 8) n))))

  (define (hexn n digits)
    (let ([s (string-upcase (number->string n 16))])
      (string-append (make-string (- digits (string-length s)) #\0) s)))

  ;; re-encode a double as a wider IEEE-ish format with an EXPLICIT-msb
  ;; significand of sig-bits and 15 exponent bits (bias 16383); returns
  ;; (sign exponent significand), significand's msb set for finite
  ;; non-zero values
  (define (widen-double x sig-bits)
    (let* ([bits (double-bits x)]
           [sign (bitwise-arithmetic-shift-right bits 63)]
           [expd (bitwise-and (bitwise-arithmetic-shift-right bits 52) 2047)]
           [frac (bitwise-and bits #xFFFFFFFFFFFFF)])
      (cond
        [(= expd 2047)
         (if (zero? frac)   ; infinity; NaNs cannot reach here (unbuild)
             (values sign 32767 (bitwise-arithmetic-shift-left 1 (- sig-bits 1)))
             (error "NaN in a non-double float position" x))]
        [(and (zero? expd) (zero? frac)) (values sign 0 0)]
        [else
         (let* ([m (if (zero? expd) frac (bitwise-ior frac (expt 2 52)))]
                [e2 (if (zero? expd) -1074 (- expd 1075))]   ; value = m * 2^e2
                [shift (- (- sig-bits 1) (- (bitwise-length m) 1))]
                [msig (bitwise-arithmetic-shift-left m shift)]
                [e (+ (- e2 shift) (- sig-bits 1) 16383)])
           (values sign e msig))])))

  (define (flonum->text tyf x)
    (case tyf
      [(x86_fp80)   ; 0xK + sign|exp15|explicit-int-bit+frac63 (20 hex)
       (let-values ([(sign e msig) (widen-double x 64)])
         (string-append "0xK"
           (hexn (+ (* sign 32768) e) 4) (hexn msig 16)))]
      [(fp128)      ; 0xL + sign|exp15|frac112, implicit msb -- printed
                    ; and parsed as two 64-bit words, LOW word first
       (let-values ([(sign e msig) (widen-double x 113)])
         (let ([bits (bitwise-ior
                       (bitwise-arithmetic-shift-left (+ (* sign 32768) e) 112)
                       (if (zero? msig) 0 (- msig (expt 2 112))))])
           (string-append "0xL"
             (hexn (bitwise-and bits #xFFFFFFFFFFFFFFFF) 16)
             (hexn (bitwise-arithmetic-shift-right bits 64) 16))))]
      [(ppc_fp128)  ; 0xM + hi double bits + lo double bits (32 hex)
       (string-append "0xM" (hexn (double-bits x) 16) (hexn 0 16))]
      [else (string-append "0x" (hexn (double-bits x) 16))]))

  ;; the enclosing define's variadicness: a musttail call forwards `...`
  ;; only when BOTH caller and callee are varargs
  (define caller-variadic? (make-parameter #f))

  ;; env: name-symbol -> 'struct | 'packed-struct | 'opaque, from type items
  (define (named-kind env t)
    (or (and (symbol? t) (hashtable-ref env t #f))
        (error "aggregate constant of unknown named type" t)))

  (define (operand->text env tyf v)
    (cond
      [(symbol? v)
       (case v
         [(undef poison null zeroinitializer none) (symbol->string v)]
         [else (name->text v)])]
      [(and (integer? v) (exact? v)) (number->string v)]
      [(flonum? v) (flonum->text tyf v)]
      [(pair? v)
       (case (car v)
         [(c) (string-append "c" (quoted-bytes (cadr v) #f))]
         [(cz) (string-append "c" (quoted-bytes (cadr v) #t))]
         [(blockaddress)
          (format "blockaddress(~a, ~a)"
                  (name->text (cadr v)) (name->text (caddr v)))]
         [(md)
          ;; metadata operand: !"string" or an inline node !{...}
          (let md->text ([x (cadr v)])
            (if (string? x)
                (string-append "!" (quoted x))
                (format "!{~a}"
                        (join ", " (map (lambda (e) (md->text (cadr e)))
                                        x)))))]
         [(splat)
          (format "splat (~a)" (group->text env (cadr v)))]
         [(extractelement insertelement)
          ;; element-access constexpr: op (G, G[, G])
          (format "~a (~a)" (car v)
                  (join ", " (map (lambda (g) (group->text env g))
                                  (cdr v))))]
         [(trunc ptrtoint inttoptr bitcast addrspacecast)
          ;; constexpr cast: op (src-ty VAL to dst-ty)
          (format "~a (~a ~a to ~a)" (car v) (type->text (cadr v))
                  (operand->text env (cadr v) (caddr v))
                  (type->text (cadddr v)))]
         [(add sub mul xor)
          ;; constexpr binop: op flags (ty A, ty B)
          (let loop ([rest (cdr v)] [flags '()])
            (if (memq (car rest) '(nuw nsw))
                (loop (cdr rest) (cons (car rest) flags))
                (words (symbol->string (car v))
                       (flags-text (reverse flags))
                       (format "(~a ~a, ~a ~a)"
                               (type->text (car rest))
                               (operand->text env (car rest) (cadr rest))
                               (type->text (car rest))
                               (operand->text env (car rest)
                                              (caddr rest))))))]
         [(getelementptr)
          ;; constexpr gep: getelementptr flags (src-ty, G, G...)
          (let loop ([rest (cdr v)] [flags '()])
            (if (memq (car rest) '(inbounds nusw nuw))
                (loop (cdr rest) (cons (car rest) flags))
                (words "getelementptr" (flags-text (reverse flags))
                       (format "(~a)"
                               (join ", "
                                     (cons (type->text (car rest))
                                           (map (lambda (g)
                                                  (group->text env g))
                                                (cdr rest))))))))]
         [else (aggregate->text env tyf v)])]
      [else (error "cannot render operand" v)]))

  (define (quoted-bytes s nul?)   ; a string (its utf8) or a bytevector (as is)
    (string-append "\"" (escape-bytes (if (bytevector? s) s (string->utf8 s)) nul?) "\""))

  (define (group->text env g)   ; (TY V) -> "TY V"
    (format "~a ~a" (type->text (car g))
            (operand->text env (car g) (cadr g))))

  (define (aggregate->text env tyf elems)
    (let ([body (join ", " (map (lambda (g) (group->text env g)) elems))])
      (cond
        [(and (pair? tyf) (eq? (car tyf) 'array)) (format "[~a]" body)]
        [(and (pair? tyf) (memq (car tyf) '(vector scalable-vector)))
         (format "<~a>" body)]
        [(and (pair? tyf) (eq? (car tyf) 'struct)) (format "{ ~a }" body)]
        [(and (pair? tyf) (eq? (car tyf) 'packed-struct))
         (format "<{ ~a }>" body)]
        [(symbol? tyf)
         (if (eq? (named-kind env tyf) 'packed-struct)
             (format "<{ ~a }>" body)
             (format "{ ~a }" body))]
        [else (error "aggregate constant in a non-aggregate position" tyf)])))

  ;; ---- instructions -------------------------------------------------------------------

  (define binops
    '(add fadd sub fsub mul fmul udiv sdiv fdiv urem srem frem
       shl lshr ashr and or xor))
  (define casts
    '(trunc zext sext fptoui fptosi uitofp sitofp fptrunc fpext
       ptrtoint inttoptr bitcast addrspacecast))
  (define flag-words   ; leading modifiers an sll instruction may carry
    '(nsw nuw exact disjoint nneg volatile atomic weak singlethread
       inbounds nusw tail musttail notail
       reassoc nnan ninf nsz arcp contract afn fast))

  (define (span-flags rest)
    (let loop ([r rest] [flags '()])
      (if (and (pair? r) (symbol? (car r)) (memq (car r) flag-words))
          (loop (cdr r) (cons (car r) flags))
          (values (reverse flags) r))))

  (define (words . parts)   ; join non-empty strings with single spaces
    (join " " (filter (lambda (s) (positive? (string-length s))) parts)))

  (define (flags-text flags) (join " " (map symbol->string flags)))

  (define (label-ref g) (format "label %~a" (label-text (cadr g))))

  ;; trailing [ordering-symbol] (align n)... after an instruction's operands
  (define (tail-text rest)
    (apply string-append
           (map (lambda (x)
                  (cond
                    [(symbol? x) (format " ~a" x)]
                    [(eq? (car x) 'addrspace)
                     (format ", addrspace(~a)" (cadr x))]
                    [else (format ", align ~a" (cadr x))]))
                rest)))

  (define (app->text env tyslot app forward-varargs?)
    ;; callee(args) with the call-site type; a musttail call in a
    ;; variadic function forwards the varargs as a literal `...`
    (let ([callee (car app)] [args (cdr app)])
      (format "~a ~a(~a)"
              (type->text tyslot)
              (if (and (pair? callee) (eq? (car callee) 'asm))
                  (asm->text callee)
                  (operand->text env #f callee))
              (join ", " (append
                           (map (lambda (g) (group->text env g)) args)
                           (if forward-varargs? '("...") '()))))))

  (define (bundle-form? x) (and (pair? x) (eq? (car x) 'bundle)))
  (define (bundles->text env bs)
    (if (null? bs)
        ""
        (format " [ ~a ]"
                (join ", "
                      (map (lambda (b)
                             (format "~s(~a)" (cadr b)
                                     (join ", "
                                           (map (lambda (g)
                                                  (group->text env g))
                                                (cddr b)))))
                           bs)))))

  (define (asm->text a)
    (words "asm"
           (if (memq 'sideeffect (cdddr a)) "sideeffect" "")
           (if (memq 'alignstack (cdddr a)) "alignstack" "")
           (if (memq 'inteldialect (cdddr a)) "inteldialect" "")
           (if (memq 'unwind (cdddr a)) "unwind" "")
           (format "~a, ~a" (quoted-bytes (cadr a) #f)
                   (quoted-bytes (caddr a) #f))))

  ;; atomic before volatile, as the parser demands
  (define (memory-flags-text flags)
    (words (if (memq 'atomic flags) "atomic" "")
           (if (memq 'volatile flags) "volatile" "")))

  ;; syncscope goes between the operands and the ordering token
  (define (sync-text flags)
    (if (memq 'singlethread flags) " syncscope(\"singlethread\")" ""))

  (define (op->text env f)
    (let ([op (car f)])
      (let-values ([(flags args) (span-flags (cdr f))])
        (define (ty) (type->text (car args)))
        (define (g n) (group->text env (list-ref args n)))
        (define (v n tyf) (operand->text env tyf (list-ref args n)))
        (cond
          [(memq op binops)
           (words (symbol->string op) (flags-text flags) (ty)
                  (format "~a, ~a" (v 1 (car args)) (v 2 (car args))))]
          [(memq op casts)
           (words (symbol->string op) (flags-text flags) (ty)
                  (v 1 (car args)) "to" (type->text (caddr args)))]
          [else
           (case op
             [(ret)
              (if (equal? args '(void)) "ret void"
                  (words "ret" (ty) (v 1 (car args))))]
             [(br)
              (if (= (length args) 1)
                  (format "br ~a" (label-ref (car args)))
                  (format "br i1 ~a, ~a, ~a"
                          (v 1 'i1) (label-ref (caddr args))
                          (label-ref (cadddr args))))]
             [(switch)
              (format "switch ~a ~a, ~a [ ~a ]"
                      (ty) (v 1 (car args)) (label-ref (caddr args))
                      (join " " (map (lambda (c)
                                       (format "~a, ~a"
                                               (group->text env (car c))
                                               (label-ref (cadr c))))
                                     (cdddr args))))]
             [(indirectbr)
              (format "indirectbr ~a, [~a]"
                      (g 0)
                      (join ", " (map label-ref (cdr args))))]
             [(unreachable) "unreachable"]
             [(fneg)
              (words "fneg" (flags-text flags) (ty) (v 1 (car args)))]
             [(icmp fcmp)
              (words (symbol->string op) (flags-text flags)
                     (symbol->string (car args)) (type->text (cadr args))
                     (format "~a, ~a" (v 2 (cadr args)) (v 3 (cadr args))))]
             [(select)
              (words "select" (flags-text flags)
                     (format "~a, ~a, ~a" (g 0) (g 1) (g 2)))]
             [(phi)
              (words "phi" (flags-text flags) (ty)
                     (join ", "
                           (map (lambda (inc)
                                  (format "[ ~a, %~a ]"
                                          (operand->text env (car args) (car inc))
                                          (label-text (cadr inc))))
                                (cdr args))))]
             [(call)
              ;; parser order: [tail] call [fmf] [cconv] [addrspace] ty
              (let* ([cc (cc-spec (car args))]
                     [args (if cc (cdr args) args)]
                     [as (and (pair? (car args))
                              (eq? (caar args) 'addrspace)
                              (cadr (car args)))]
                     [args (if as (cdr args) args)])
                (words (cond [(memq 'tail flags) "tail"]
                             [(memq 'musttail flags) "musttail"]
                             [(memq 'notail flags) "notail"]
                             [else ""])
                       "call"
                       (flags-text (filter (lambda (x)
                                             (not (memq x '(tail musttail notail))))
                                           flags))
                       (cc-text cc)
                       (if as (format "addrspace(~a)" as) "")
                       (let* ([attr-group?
                               (lambda (x)
                                 (and (pair? x)
                                      (eq? (car x) 'attributes)))]
                              [agroups (filter attr-group?
                                               (cddr args))]
                              [bs (remp attr-group? (cddr args))])
                         (string-append
                           (app->text env (car args) (cadr args)
                                      (and (memq 'musttail flags)
                                           (caller-variadic?)
                                           (pair? (car args))
                                           (eq? (caar args) 'fn)
                                           (memq 'variadic (car args))
                                           #t))
                           ;; call-site attributes: inline, after the
                           ;; argument list, before any bundles
                           (if (null? agroups)
                               ""
                               (string-append
                                 " "
                                 (attrs-words
                                   (apply append
                                          (map cdr agroups)))))
                           (bundles->text env bs)))))]
             [(invoke)
              (let* ([cc (cc-spec (car args))]
                     [args (if cc (cdr args) args)]
                     [bs (filter bundle-form? (cddr args))]
                     [labels (filter (lambda (x) (not (bundle-form? x)))
                                     (cddr args))])
                (format "invoke ~a~a~a to ~a unwind ~a"
                        (if cc (string-append (cc-text cc) " ") "")
                        (app->text env (car args) (cadr args) #f)
                        (bundles->text env bs)
                        (label-ref (car labels)) (label-ref (cadr labels))))]
             [(callbr)
              (let* ([cc (cc-spec (car args))]
                     [args (if cc (cdr args) args)]
                     [bs (filter bundle-form? (cddr args))]
                     [rest (filter (lambda (x) (not (bundle-form? x)))
                                   (cddr args))])
                (format "callbr ~a~a~a to ~a [~a]"
                        (if cc (string-append (cc-text cc) " ") "")
                        (app->text env (car args) (cadr args) #f)
                        (bundles->text env bs)
                        (label-ref (car rest))
                        (join ", " (map label-ref (cadr rest)))))]
             [(landingpad)
              (words "landingpad" (ty)
                     (join " "
                           (map (lambda (c)
                                  (if (eq? c 'cleanup)
                                      "cleanup"
                                      (format "~a ~a ~a" (car c)
                                              (type->text (cadr c))
                                              (operand->text env (cadr c)
                                                             (caddr c)))))
                                (cdr args))))]
             [(resume) (words "resume" (ty) (v 1 (car args)))]
             [(catchswitch)
              (format "catchswitch within ~a [~a] unwind ~a"
                      (operand->text env #f (car args))
                      (join ", " (map label-ref (cadr args)))
                      (if (eq? (caddr args) 'caller)
                          "to caller" (label-ref (caddr args))))]
             [(catchpad cleanuppad)
              (format "~a within ~a [~a]" op
                      (operand->text env #f (car args))
                      (join ", " (map (lambda (g) (group->text env g))
                                      (cadr args))))]
             [(catchret)
              (format "catchret from ~a to ~a"
                      (operand->text env #f (car args))
                      (label-ref (cadr args)))]
             [(cleanupret)
              (format "cleanupret from ~a unwind ~a"
                      (operand->text env #f (car args))
                      (if (eq? (cadr args) 'caller)
                          "to caller" (label-ref (cadr args))))]
             [(freeze) (words "freeze" (ty) (v 1 (car args)))]
             [(va_arg) (format "va_arg ~a, ~a" (g 0) (type->text (cadr args)))]
             [(extractelement) (format "extractelement ~a, ~a" (g 0) (g 1))]
             [(insertelement)
              (format "insertelement ~a, ~a, ~a" (g 0) (g 1) (g 2))]
             [(shufflevector)
              (let ([mask (cdr (caddr args))]
                    [scalable? (let ([t (car (car args))])
                                 (and (pair? t)
                                      (eq? (car t) 'scalable-vector)))])
                (if scalable?
                    ;; scalable shuffles admit only splat masks, spelled
                    ;; as a scalable zeroinitializer/poison constant
                    (format "shufflevector ~a, ~a, <vscale x ~a x i32> ~a"
                            (g 0) (g 1) (length mask)
                            (cond
                              [(for-all (lambda (e) (eqv? e 0)) mask)
                               "zeroinitializer"]
                              [(for-all (lambda (e) (eq? e 'poison)) mask)
                               "poison"]
                              [else (error "non-splat scalable shuffle mask"
                                           mask)]))
                    (format "shufflevector ~a, ~a, <~a x i32> <~a>"
                            (g 0) (g 1) (length mask)
                            (join ", " (map (lambda (e) (format "i32 ~a" e))
                                            mask)))))]
             [(extractvalue)
              (format "extractvalue ~a, ~a" (g 0)
                      (join ", " (map number->string (cdr args))))]
             [(insertvalue)
              (format "insertvalue ~a, ~a, ~a" (g 0) (g 1)
                      (join ", " (map number->string (cddr args))))]
             [(fence) (format "fence~a ~a" (sync-text flags) (car args))]
             [(atomicrmw)
              (words "atomicrmw" (memory-flags-text flags)
                     (symbol->string (car args))
                     (string-append
                       (format "~a, ~a~a ~a" (g 1)
                               (group->text env (caddr args))
                               (sync-text flags) (cadddr args))
                       (tail-text (cddddr args))))]
             [(cmpxchg)
              (words "cmpxchg"
                     (if (memq 'weak flags) "weak" "")
                     (memory-flags-text flags)
                     (string-append
                       (format "~a, ~a, ~a~a ~a ~a" (g 0) (g 1) (g 2)
                               (sync-text flags)
                               (cadddr args) (car (cddddr args)))
                       (tail-text (cdr (cddddr args)))))]
             [(alloca)
              (let* ([rest (cdr args)]
                     [count (and (pair? rest) (pair? (car rest))
                                 (not (memq (caar rest) '(align addrspace)))
                                 (car rest))]
                     [attrs (if count (cdr rest) rest)])
                (string-append
                  (format "alloca ~a" (ty))
                  (if count (format ", ~a" (group->text env count)) "")
                  (tail-text attrs)))]
             [(load)
              (words "load" (memory-flags-text flags)
                     (string-append
                       (format "~a, ~a" (ty) (g 1))
                       (sync-text flags)
                       (tail-text (cddr args))))]
             [(store)
              (words "store" (memory-flags-text flags)
                     (string-append
                       (format "~a, ~a" (g 0) (g 1))
                       (sync-text flags)
                       (tail-text (cddr args))))]
             [(getelementptr)
              (words "getelementptr" (flags-text flags)
                     (string-append
                       (ty)
                       (apply string-append
                              (map (lambda (g)
                                     (format ", ~a" (group->text env g)))
                                   (cdr args)))))]
             [else (error "cannot render instruction" f)])]))))

  (define (insn->text env f)
    (if (eq? (car f) '=)
        (format "  ~a = ~a" (name->text (cadr f)) (op->text env (caddr f)))
        (format "  ~a" (op->text env f))))

  ;; ---- module items --------------------------------------------------------------------

  (define linkage-words
    '(external available_externally linkonce linkonce_odr weak weak_odr
       appending internal private extern_weak common))

  (define cc-words   ; the named calling conventions, as LLVM prints them
    '(fastcc coldcc ghccc anyregcc preserve_mostcc preserve_allcc
       swiftcc cxx_fast_tlscc tailcc cfguard_checkcc swifttailcc
       preserve_nonecc x86_stdcallcc x86_fastcallcc arm_apcscc
       arm_aapcscc arm_aapcs_vfpcc msp430_intrcc x86_thiscallcc
       ptx_kernel ptx_device spir_func spir_kernel intel_ocl_bicc
       x86_64_sysvcc win64cc x86_vectorcallcc hhvmcc hhvm_ccc x86_intrcc
       avr_intrcc avr_signalcc amdgpu_vs amdgpu_gs amdgpu_ps amdgpu_cs
       amdgpu_kernel x86_regcallcc amdgpu_hs amdgpu_ls amdgpu_es
       aarch64_vector_pcs aarch64_sve_vector_pcs amdgpu_gfx
       aarch64_sme_preservemost_from_x0 aarch64_sme_preservemost_from_x2
       amdgpu_cs_chain amdgpu_cs_chain_preserve m68k_rtdcc graalcc
       riscv_vector_cc aarch64_sme_preservemost_from_x1))

  ;; an optional leading cc spec: a named symbol or (cc N); returns it
  ;; or #f. (cc N) prints as ccN, the numbered spelling LLVM uses.
  (define (cc-spec x)
    (and (or (and (symbol? x) (memq x cc-words))
             (and (pair? x) (eq? (car x) 'cc)))
         x))

  (define (cc-text c)
    (cond
      [(not c) ""]
      [(symbol? c) (symbol->string c)]
      [else (format "cc~a" (cadr c))]))

  (define (ifunc->text env item)
    (let* ([rest (cdr (caddr item))]
           [lk (and (symbol? (car rest)) (memq (car rest) linkage-words)
                    (car rest))]
           [rest (if lk (cdr rest) rest)])
      (words (format "~a =" (name->text (cadr item)))
             (if lk (symbol->string lk) "")
             "ifunc" (type->text (car rest))
             (format ", ~a" (group->text env (cadr rest))))))

  (define (alias->text env item)
    ;; (= @a (alias (addrspace n)? linkage? value-type (ptr aliasee)))
    (let* ([rest (cdr (caddr item))]
           [as (let ([x (car rest)])
                 (and (pair? x) (eq? (car x) 'addrspace) (cadr x)))]
           [rest (if as (cdr rest) rest)]
           [lk (and (symbol? (car rest)) (memq (car rest) linkage-words)
                    (car rest))]
           [rest (if lk (cdr rest) rest)])
      (words (format "~a =" (name->text (cadr item)))
             (if lk (symbol->string lk) "")
             (if as (format "addrspace(~a)" as) "")
             "alias" (type->text (car rest))
             (format ", ~a" (group->text env (cadr rest))))))

  (define (global->text env item)
    ;; (= @g (global|constant (addrspace N)? linkage? ty init? attrs))
    (let* ([name (cadr item)] [rhs (caddr item)]
           [kind (car rhs)] [rest (cdr rhs)]
           [as (and (pair? (car rest)) (eq? (caar rest) 'addrspace)
                    (cadr (car rest)))]
           [rest (if as (cdr rest) rest)]
           [lk (and (symbol? (car rest)) (memq (car rest) linkage-words)
                    (car rest))]
           [rest (if lk (cdr rest) rest)]
           [ext-init? (eq? (car rest) 'externally_initialized)]
           [rest (if ext-init? (cdr rest) rest)]
           [ty (car rest)] [rest (cdr rest)]
           [init (and (pair? rest)
                      (not (and (pair? (car rest)) (eq? (caar rest) 'align)))
                      (car rest))]
           [attrs (if init (cdr rest) rest)])
      (string-append
        (words (format "~a =" (name->text name))
               (if lk (symbol->string lk) "")
               (if as (format "addrspace(~a)" as) "")
               (if ext-init? "externally_initialized" "")
               (symbol->string kind)
               (type->text ty)
               (if init (operand->text env ty init) ""))
        (tail-text attrs))))

  (define (signature->text env sig groups?)
    ;; (@f (ty %a) ...) for defines (groups), (@f ty ...) for declares
    (let-values ([(parts variadic?) (split-variadic (cdr sig))])
      (format "~a(~a)" (name->text (car sig))
              (join ", "
                    (append
                      (map (lambda (p)
                             (if groups? (group->text env p) (type->text p)))
                           parts)
                      (if variadic? '("...") '()))))))

  ;; one (attributes ...) element -> its textual spelling
  (define (attr-text spec)
    (cond
      [(symbol? spec) (symbol->string spec)]
      [(null? (cdr spec)) (format "~s" (car spec))]
      [else (format "~s=~s" (car spec) (cadr spec))]))

  (define (attrs-words specs) (join " " (map attr-text specs)))

  (define (function->text env item)
    (let* ([kind (car item)] [rest (cdr item)]
           [lk (and (symbol? (car rest)) (memq (car rest) linkage-words)
                    (car rest))]
           [rest (if lk (cdr rest) rest)]
           [cc (cc-spec (car rest))]
           [rest (if cc (cdr rest) rest)]
           [ty (car rest)] [sig (cadr rest)] [body (cddr rest)])
      (if (eq? kind 'declare)
          (words "declare" (if lk (symbol->string lk) "") (cc-text cc)
                 (type->text ty) (signature->text env sig #f)   ; bare types
                 (let deco ([b body] [acc '()])
                   (if (and (pair? b) (pair? (car b)))
                       (case (caar b)
                         [(attributes)
                          (deco (cdr b)
                                (cons (attrs-words (cdr (car b))) acc))]
                         [(align) (deco (cdr b)
                                        (cons (format "align ~a"
                                                      (cadr (car b)))
                                              acc))]
                         [(gc) (deco (cdr b)
                                     (cons (format "gc ~s" (cadr (car b)))
                                           acc))]
                         [else (join " " (reverse acc))])
                       (join " " (reverse acc)))))
          (let* ([attrs (and (pair? body) (pair? (car body))
                             (eq? (caar body) 'attributes)
                             (car body))]
                 [body (if attrs (cdr body) body)]
                 [algn (and (pair? body) (pair? (car body))
                            (eq? (caar body) 'align)
                            (car body))]
                 [body (if algn (cdr body) body)]
                 [gc (and (pair? body) (pair? (car body))
                          (eq? (caar body) 'gc)
                          (car body))]
                 [body (if gc (cdr body) body)]
                 [pers (and (pair? body) (pair? (car body))
                            (eq? (caar body) 'personality)
                            (car body))]
                 [blocks (if pers (cdr body) body)]
                 [variadic? (let-values ([(parts v?) (split-variadic
                                                       (cdr sig))])
                              v?)])
            (string-append
              (words "define" (if lk (symbol->string lk) "") (cc-text cc)
                     (type->text ty) (signature->text env sig #t)
                     (if attrs (attrs-words (cdr attrs)) "")
                     (if algn (format "align ~a" (cadr algn)) "")
                     (if gc (format "gc ~s" (cadr gc)) "")
                     (if pers
                         (format "personality ~a ~a"
                                 (type->text (cadr pers))
                                 (operand->text env (cadr pers)
                                                (caddr pers)))
                         "")
                     "{")
              "\n"
              (parameterize ([caller-variadic? variadic?])
                (join "\n"
                      (map (lambda (b)
                             (string-append
                               (label-text (cadr b)) ":\n"
                               (join "\n"
                                     (map (lambda (i) (insn->text env i))
                                          (cddr b)))))
                           blocks)))
              "\n}")))))

  (define (type-item->text item)
    (format "~a = type ~a" (name->text (cadr item))
            (if (eq? (caddr item) 'opaque)
                "opaque"
                (type->text (caddr item)))))

  ;; ---- entry point ------------------------------------------------------------------------

  (define (target-item? item)
    (and (pair? item) (memq (car item) '(datalayout triple))))

  (define (sll->ll prog0)
    ;; the parser rejects `target` lines after any other entity
    (let ([prog (append (filter target-item? prog0)
                        (filter (lambda (i) (not (target-item? i))) prog0))]
          [env (make-eq-hashtable)])
      ;; register named struct kinds for aggregate-constant bracket choice
      (for-each
        (lambda (item)
          (when (eq? (car item) 'type)
            (hashtable-set! env (cadr item)
                            (if (pair? (caddr item))
                                (car (caddr item))
                                'opaque))))
        prog)
      (string-append
        (join "\n"
              (map (lambda (item)
                     (case (car item)
                       [(datalayout)
                        (format "target datalayout = ~s" (cadr item))]
                       [(triple)
                        (format "target triple = ~s" (cadr item))]
                       [(module-asm)
                        ;; one `module asm` directive per stored line
                        (let ([p (open-string-input-port (cadr item))]
                              [out '()])
                          (let loop ()
                            (let ([l (get-line p)])
                              (if (eof-object? l)
                                  (join "\n"
                                        (map (lambda (x)
                                               (string-append "module asm "
                                                              (quoted x)))
                                             (reverse out)))
                                  (begin (set! out (cons l out))
                                         (loop))))))]
                       [(type) (type-item->text item)]
                       [(=) (case (car (caddr item))
                              [(alias) (alias->text env item)]
                              [(ifunc) (ifunc->text env item)]
                              [else (global->text env item)])]
                       [(define declare) (function->text env item)]
                       [else (error "cannot render module item" item)]))
                   prog))
        "\n"))))
