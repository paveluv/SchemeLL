;;; Read instruction flags from LLVM's own printer, for releases whose C API has
;;; no accessor for them (nsw/nuw/exact/nneg/disjoint, fast-math flags and
;;; tail-call kinds arrived in LLVM 18; icmp samesign has none at all). Only the
;;; canonical head of the printed instruction is inspected: the result name
;;; (quoted/escaped forms skipped), then the flag words before and after the
;;; opcode, up to the first word that is not a flag.
[library
 (llvm text-flags)
 (export instruction-head leading-flags leading-flag?)
 (import (chezscheme) (prefix (llvm raw) LLVM) (prefix (llvm base) base:))

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
   ((p (open-string-input-port (head-text instruction))))
   [define
    (next)
    (let ((x (read p))) (and (not (eof-object? x)) (if (symbol? x) x 'other)))]
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
