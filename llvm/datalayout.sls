;;; (llvm datalayout) -- the datalayout string as structured data.
;;; The asm-DSL philosophy applied to LLVM's other little language:
;;; model the STRUCTURE the spec defines, pass unrecognized leaves
;;; through verbatim, and demand byte-identical round-trips (parse
;;; then unparse is the identity on every layout string in LLVM's
;;; own test corpus -- the test suite holds it to that).
;;;
;;; Component forms (LangRef "Data Layout" section, LLVM 19):
;;;   (endian little|big)                      e | E
;;;   (mangling elf|macho|mips|wincoff|wincoff-x86|xcoff|goff)   m:<c>
;;;   (stack-align N)                          S<N>       (bits)
;;;   (program-as N) (globals-as N) (alloca-as N)   P<N> G<N> A<N>
;;;   (ptr size abi pref? idx?)                p:<s>:<abi>[:<p>[:<i>]]
;;;   (ptr (addrspace N) size abi pref? idx?)  p<N>:...   (p0 stays
;;;                                            explicit -- round-trip)
;;;   (int size abi pref?)                     i<s>:<abi>[:<p>]
;;;   (vector size abi pref?)                  v...
;;;   (float size abi pref?)                   f...
;;;   (aggregate abi pref?)                    a:<abi>[:<p>]
;;;   (native N ...)                           n<N>:<N>...
;;;   (non-integral N ...)                     ni:<N>:<N>...
;;;   (fn-ptr-align independent|multiple N)    Fi<N> | Fn<N>
;;;   (raw "...")                              anything else, verbatim
;;;                                            (legacy a0:/s specs,
;;;                                            future components)
(library (llvm datalayout)
  (export parse unparse)
  (import (except (chezscheme) error)
          (prefix (llvm base) base:))

  (define (error msg . irritants)
    (apply base:error 'dl:parse msg irritants))

  ;; ---- little string utilities -------------------------------------

  (define (split s ch)
    (let loop ([i 0] [start 0] [acc '()])
      (cond
        [(= i (string-length s))
         (reverse (cons (substring s start i) acc))]
        [(char=? (string-ref s i) ch)
         (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
        [else (loop (+ i 1) start acc)])))

  (define (all-digits? s)
    (and (> (string-length s) 0)
         (let loop ([i 0])
           (or (= i (string-length s))
               (and (char<=? #\0 (string-ref s i) #\9)
                    (loop (+ i 1)))))))

  (define (num s comp) ; digit string -> exact integer, else #f
    (and (all-digits? s) (string->number s 10)))

  (define (nums parts comp)  ; every part a number, else #f
    (let loop ([ps parts] [acc '()])
      (cond
        [(null? ps) (reverse acc)]
        [(num (car ps) comp) => (lambda (n) (loop (cdr ps) (cons n acc)))]
        [else #f])))

  (define manglings
    '(("e" . elf) ("o" . macho) ("m" . mips) ("w" . wincoff)
      ("x" . wincoff-x86) ("a" . xcoff) ("l" . goff)))

  ;; ---- parse: one component ----------------------------------------

  ;; <letters><first>:<rest>... split into (letters first rest ...)
  (define (component->form c)
    (define (raw) `(raw ,c))
    (if (string=? c "")
        (raw)
        (let* ([colon (let loop ([i 0])
                        (cond [(= i (string-length c)) #f]
                              [(char=? (string-ref c i) #\:) i]
                              [else (loop (+ i 1))]))]
               [head (if colon (substring c 0 colon) c)]
               [tail-parts (if colon
                               (split (substring c (+ colon 1)
                                                 (string-length c)) #\:)
                               '())])
          (cond
            ;; exact-letter components
            [(string=? c "e") '(endian little)]
            [(string=? c "E") '(endian big)]
            [(and (string=? head "m") (= (length tail-parts) 1))
             (cond
               [(assoc (car tail-parts) manglings) =>
                (lambda (p) `(mangling ,(cdr p)))]
               [else (raw)])]
            [(and (string=? head "ni") (pair? tail-parts))
             (cond [(nums tail-parts c) =>
                    (lambda (ns) `(non-integral ,@ns))]
                   [else (raw)])]
            [(and (string=? head "a") (pair? tail-parts))
             (cond [(nums tail-parts c) =>
                    (lambda (ns) `(aggregate ,@ns))]
                   [else (raw)])]
            [(string=? head "") (raw)]
            ;; letter+number, no colon parts
            [(and (not colon) (> (string-length c) 1))
             (let ([letter (string-ref c 0)]
                   [rest (substring c 1 (string-length c))])
               (case letter
                 [(#\n) (cond [(num rest c) =>
                               (lambda (n) `(native ,n))]
                              [else (raw)])]
                 [(#\S) (cond [(num rest c) =>
                               (lambda (n) `(stack-align ,n))]
                              [else (raw)])]
                 [(#\P) (cond [(num rest c) =>
                               (lambda (n) `(program-as ,n))]
                              [else (raw)])]
                 [(#\G) (cond [(num rest c) =>
                               (lambda (n) `(globals-as ,n))]
                              [else (raw)])]
                 [(#\A) (cond [(num rest c) =>
                               (lambda (n) `(alloca-as ,n))]
                              [else (raw)])]
                 [(#\F)
                  (let ([kind (string-ref c 1)]
                        [n (num (substring c 2 (string-length c)) c)])
                    (cond
                      [(and n (char=? kind #\i)) `(fn-ptr-align independent ,n)]
                      [(and n (char=? kind #\n)) `(fn-ptr-align multiple ,n)]
                      [else (raw)]))]
                 [else (raw)]))]
            ;; letter[digits]:parts -- p/i/v/f/n
            [colon
             (let* ([letter (string-ref head 0)]
                    [selfnum (substring head 1 (string-length head))]
                    [ns (nums tail-parts c)])
               (cond
                 [(not ns) (raw)]
                 [(char=? letter #\n)
                  ;; n<w>:<w>... -- the first width rides on the letter
                  (cond [(num selfnum c) =>
                         (lambda (w) `(native ,w ,@ns))]
                        [else (raw)])]
                 [(char=? letter #\p)
                  (cond
                    [(string=? selfnum "") `(ptr ,@ns)]
                    [(num selfnum c) =>
                     (lambda (as) `(ptr (addrspace ,as) ,@ns))]
                    [else (raw)])]
                 [(memv letter '(#\i #\v #\f))
                  (cond
                    [(num selfnum c) =>
                     (lambda (sz)
                       `(,(case letter [(#\i) 'int] [(#\v) 'vector]
                                       [(#\f) 'float])
                         ,sz ,@ns))]
                    [else (raw)])]
                 [else (raw)]))]
            [else (raw)]))))

  ;; ---- unparse: one form -------------------------------------------

  (define (join-nums prefix ns)
    (apply string-append prefix
           (map (lambda (n) (format ":~a" n)) ns)))

  (define (check-nums f ns)
    (unless (and (pair? ns)
                 (for-all (lambda (n) (and (integer? n) (exact? n)
                                           (>= n 0)))
                          ns))
      (base:error 'dl:unparse "component needs exact nonnegative integers" f)))

  (define (form->component f)
    (unless (and (pair? f) (symbol? (car f)))
      (base:error 'dl:unparse "not a datalayout component form" f))
    (case (car f)
      [(endian) (case (cadr f)
                  [(little) "e"] [(big) "E"]
                  [else (base:error 'dl:unparse "endian must be little or big" f)])]
      [(mangling)
       (cond [(find (lambda (p) (eq? (cdr p) (cadr f))) manglings) =>
              (lambda (p) (string-append "m:" (car p)))]
             [else (base:error 'dl:unparse "unknown mangling" f)])]
      [(stack-align) (check-nums f (cdr f)) (format "S~a" (cadr f))]
      [(program-as) (check-nums f (cdr f)) (format "P~a" (cadr f))]
      [(globals-as) (check-nums f (cdr f)) (format "G~a" (cadr f))]
      [(alloca-as) (check-nums f (cdr f)) (format "A~a" (cadr f))]
      [(fn-ptr-align)
       (check-nums f (cddr f))
       (format "F~a~a"
               (case (cadr f)
                 [(independent) "i"] [(multiple) "n"]
                 [else (base:error 'dl:unparse
                                   "fn-ptr-align kind must be independent or multiple" f)])
               (caddr f))]
      [(ptr)
       (if (and (pair? (cadr f)) (eq? (car (cadr f)) 'addrspace))
           (begin (check-nums f (cons (cadr (cadr f)) (cddr f)))
                  (join-nums (format "p~a" (cadr (cadr f))) (cddr f)))
           (begin (check-nums f (cdr f))
                  (join-nums "p" (cdr f))))]
      [(int) (check-nums f (cdr f))
             (join-nums (format "i~a" (cadr f)) (cddr f))]
      [(vector) (check-nums f (cdr f))
                (join-nums (format "v~a" (cadr f)) (cddr f))]
      [(float) (check-nums f (cdr f))
               (join-nums (format "f~a" (cadr f)) (cddr f))]
      [(aggregate) (check-nums f (cdr f)) (join-nums "a" (cdr f))]
      [(native) (check-nums f (cdr f))
                (join-nums (format "n~a" (cadr f)) (cddr f))]
      [(non-integral)
       (check-nums f (cdr f))
       (when (memv 0 (cdr f))
         (base:error 'dl:unparse
                     "address space 0 cannot be non-integral (LLVM rejects ni:0)" f))
       (join-nums "ni" (cdr f))]
      [(raw) (unless (and (string? (cadr f)) (null? (cddr f)))
               (base:error 'dl:unparse "raw takes one string" f))
             (cadr f)]
      [else (base:error 'dl:unparse "unknown component form" f)]))

  ;; ---- entry points ------------------------------------------------

  ;; layout string -> list of component forms; unrecognized
  ;; components come back as (raw "...") rather than errors, because
  ;; LLVM's own parser is the validity judge -- this library only
  ;; refuses what it cannot round-trip (nothing)
  (define (parse s)
    (unless (string? s) (error "expected a datalayout string" s))
    (if (string=? s "") '() (map component->form (split s #\-))))

  ;; component forms -> layout string
  (define (unparse forms)
    (unless (list? forms)
      (base:error 'dl:unparse "expected a list of component forms" forms))
    (if (null? forms)
        ""
        (let ([cs (map form->component forms)])
          (fold-left (lambda (acc c) (string-append acc "-" c))
                     (car cs) (cdr cs))))))
