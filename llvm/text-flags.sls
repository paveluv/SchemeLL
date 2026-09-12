;;; Read instruction flags from LLVM's own printer, for releases whose C API has
;;; no accessor for them (nsw/nuw/exact/nneg/disjoint, fast-math flags and
;;; tail-call kinds arrived in LLVM 18; icmp samesign has none at all). Only the
;;; canonical head of the printed instruction is inspected: the result name
;;; (quoted/escaped forms skipped), then the flag words before and after the
;;; opcode, up to the first word that is not a flag.
[library
 (llvm text-flags)
 [export
  instruction-head
  leading-flags
  leading-flag?
  function-header-has?
  operand-bundles?
  fence-ordering
  array-length
  atomicrmw-operation
  gep-inrange?]
 (import (chezscheme) (prefix (llvm raw) LLVM) (prefix (llvm base) base:))

 ;; LLVM tokens, not Scheme datums: punctuation stays separate, comments are
 ;; skipped, and quoted strings/names cannot impersonate syntax. Keep quoted
 ;; tokens as strings and ordinary words as symbols; no unescaping is needed.
 [define
  (tokens text)
  (define n (string-length text))
  [define
   (delimiter? c)
   [or
    (char-whitespace? c)
    (memv c '(#\( #\) #\[ #\] #\{ #\} #\< #\> #\, #\= #\" #\;))]]
  [let
   loop
   ((i 0) (out '()))
   [cond
    ((= i n) (reverse out))
    ((char-whitespace? (string-ref text i)) (loop (+ i 1) out))
    [(char=? (string-ref text i) #\;)
     [let
      skip
      ((j (+ i 1)))
      [if
       (or (= j n) (char=? (string-ref text j) #\newline))
       (loop j out)
       (skip (+ j 1))]]]
    [(char=? (string-ref text i) #\")
     [let
      quoted
      ((j (+ i 1)))
      [cond
       ((= j n) (error 'llvm-text "unterminated quoted LLVM token" text))
       ((char=? (string-ref text j) #\\) (quoted (min n (+ j 2))))
       [(char=? (string-ref text j) #\")
        (loop (+ j 1) (cons (substring text i (+ j 1)) out))]
       (else (quoted (+ j 1)))]]]
    [(delimiter? (string-ref text i))
     (loop (+ i 1) (cons (string-ref text i) out))]
    [else
     [let
      word
      ((j (+ i 1)))
      [if
       (or (= j n) (delimiter? (string-ref text j)))
       (loop j (cons (string->symbol (substring text i j)) out))
       (word (+ j 1))]]]]]]

 [define
  (value-text v)
  (base:cstring->string/dispose (LLVMPrintValueToString v))]

 ;; LLVM 16 stores full-width array lengths internally, but its unsigned C
 ;; getter truncates them. The canonical array type begins with [N x ...].
 [define
  (array-length ty)
  [let*
   [(text (base:cstring->string/dispose (LLVMPrintTypeToString ty)))
    (ts (tokens text))]
   [if
    (and (pair? ts) (eqv? (car ts) #\[) (pair? (cdr ts)) (symbol? (cadr ts)))
    [or
     (string->number (symbol->string (cadr ts)))
     (error 'llvm-text "unreadable array length" text)]
    (error 'llvm-text "expected an array type" text)]]]

 ;; Both the old index marker and the newer inrange(lo,hi) syntax lack C
 ;; accessors. A quoted name cannot impersonate either annotation.
 (define (gep-inrange? v) (and (memq 'inrange (tokens (value-text v))) #t))

 [define
  (atomicrmw-operation ins)
  [let
   ((ts (tokens (head-text ins))))
   [and
    (pair? ts)
    (eq? (car ts) 'atomicrmw)
    [let
     ((rest (cdr ts)))
     [and
      (pair? rest)
      [if
       (eq? (car rest) 'volatile)
       (and (pair? (cdr rest)) (cadr rest))
       (car rest)]]]]]]

 ;; The canonical function header occupies one line. LLVM may precede it with
 ;; attribute comments; braces in return types and quoted names are not body
 ;; delimiters. Inspect only the actual define/declare line.
 [define
  (function-header-has? f keyword)
  [let
   ((p (open-string-input-port (value-text f))))
   [let
    loop
    ()
    [let
     ((line (get-line p)))
     [and
      (not (eof-object? line))
      [let
       ((ts (tokens line)))
       [if
        (and (pair? ts) (memq (car ts) '(define declare)))
        (and (memq keyword ts) #t)
        (loop)]]]]]]]

 ;; A bundle starts with [ "tag" (. Arrays start with a type, and quoted callee
 ;; names, asm strings and metadata strings stay indivisible tokens. Call-site
 ;; attributes may occur between the argument list and the bundles.
 [define
  (operand-bundles? ins)
  [let
   loop
   ((ts (tokens (value-text ins))))
   [and
    (pair? ts)
    (pair? (cdr ts))
    (pair? (cddr ts))
    [or
     (and (eqv? (car ts) #\[) (string? (cadr ts)) (eqv? (caddr ts) #\())
     (loop (cdr ts))]]]]

 [define
  (fence-ordering ins)
  [let
   ((ts (tokens (value-text ins))))
   [and
    (pair? ts)
    (eq? (car ts) 'fence)
    [let
     ((rest (cdr ts)))
     [let
      [[rest
        [if
         (and (pair? rest) (eq? (car rest) 'syncscope))
         [and
          (>= (length rest) 5)
          (eqv? (cadr rest) #\()
          (string? (caddr rest))
          (eqv? (cadddr rest) #\))
          (cddddr rest)]
         rest]]]
      [and
       (pair? rest)
       (memq (car rest) '(acquire release acq_rel seq_cst))
       (car rest)]]]]]]

 [define
  flag-words
  '[nuw
    nsw
    exact
    nneg
    disjoint
    inbounds
    nusw
    samesign
    fast
    nnan
    ninf
    nsz
    arcp
    contract
    afn
    reassoc
    tail
    musttail
    notail
    volatile]]

 ;; the printed text after "<result> = ", or the whole text for instructions
 ;; without a result
 [define
  (head-text instruction)
  [let*
   [(text (base:cstring->string/dispose (LLVMPrintValueToString instruction)))
    (n (string-length text))]
   [let
    loop
    ((i 0) (quoted? #f) (escaped? #f))
    [cond
     ((= i n) text)
     (escaped? (loop (+ i 1) quoted? #f))
     ((and quoted? (char=? (string-ref text i) #\\)) (loop (+ i 1) quoted? #t))
     ((char=? (string-ref text i) #\") (loop (+ i 1) (not quoted?) #f))
     [(and (not quoted?) (char=? (string-ref text i) #\=))
      (substring text (+ i 1) n)]
     ((and (not quoted?) (char=? (string-ref text i) #\newline)) text)
     (else (loop (+ i 1) quoted? #f))]]]]

 ;; the opcode words, so the opcode can be found past a leading type (a constant
 ;; expression prints as "<type> <opcode> [flags] (...)")
 [define
  opcode-words
  '[ret
    br
    switch
    indirectbr
    invoke
    unreachable
    add
    fadd
    sub
    fsub
    mul
    fmul
    udiv
    sdiv
    fdiv
    urem
    srem
    frem
    shl
    lshr
    ashr
    and
    or
    xor
    alloca
    load
    store
    getelementptr
    trunc
    zext
    sext
    fptoui
    fptosi
    uitofp
    sitofp
    fptrunc
    fpext
    ptrtoint
    inttoptr
    bitcast
    addrspacecast
    icmp
    fcmp
    phi
    call
    select
    va_arg
    extractelement
    insertelement
    shufflevector
    extractvalue
    insertvalue
    fence
    cmpxchg
    atomicrmw
    resume
    landingpad
    cleanupret
    catchret
    catchpad
    cleanuppad
    catchswitch
    fneg
    callbr
    freeze]]

 ;; -> (values opcode-symbol flag-symbols): flags before the opcode (tail kinds)
 ;; and after it (wrap, exact, fast-math, ...), in printed order. Tokens before
 ;; the opcode that are neither flags nor the opcode (a constant expression's
 ;; type) are skipped; #f when no opcode is found.
 [define
  (instruction-head instruction)
  [let
   ((ts (tokens (head-text instruction))))
   (define (next) (and (pair? ts) (let ((x (car ts))) (set! ts (cdr ts)) x)))
   [let
    before
    ((flags '()) (tok (next)))
    [cond
     ((not tok) (values #f (reverse flags)))
     ((memq tok flag-words) (before (cons tok flags) (next)))
     [(memq tok opcode-words)
      [let
       after
       ((flags flags) (tok2 (next)))
       [if
        (and tok2 (memq tok2 flag-words))
        (after (cons tok2 flags) (next))
        (values tok (reverse flags))]]]
     (else (before flags (next)))]]]]

 [define
  (leading-flags instruction)
  (let-values (((op flags) (instruction-head instruction))) flags)]

 [define
  (leading-flag? instruction flag)
  (and (memq flag (leading-flags instruction)) #t)]]
