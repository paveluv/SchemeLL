;;; (sll asm) -- EXPERIMENTAL: structured inline-asm expressions.
;;;
;;; A one-directional generator: s-expressions in, an ordinary sll
;;; (asm "template" "constraints" flags...) callee form out. The core
;;; sll grammar keeps asm as verbatim strings (isomorphic to LLVM IR);
;;; this library adds the structure LangRef actually specifies --
;;; output/input/clobber ordering, =/&/tied operands, {register}
;;; references, operand numbering -- while passing the open-ended
;;; per-target constraint letters (r, m, x, Upl, ...) through
;;; uninterpreted.
;;;
;;;   (asm:expr
;;;     '((out  sum r)              ; "=r"      -> $sum is operand 0
;;;       (in   a (tied sum))       ; "0"       -> tied to sum's location
;;;       (in   b r)                ; "r"
;;;       (clobber cc))             ; "~{cc}"
;;;     '("add " b ", " sum)        ; template: "add $2, $0"
;;;     'sideeffect)
;;;   => (asm "add $2, $0" "=r,0,r,~{cc}" sideeffect)
;;;
;;; Operands are referenced BY NAME in the template and in (tied ...);
;;; the library computes the $N numbering (outputs first, then inputs,
;;; as LangRef specifies), which removes the two classic hand-written
;;; asm bug classes: mis-numbered operands and malformed constraint
;;; strings. Literal $ in template strings is escaped automatically.
;;;
;;; Items:
;;;   (out NAME SPEC)     an output              =SPEC
;;;   (out! NAME SPEC)    early-clobber output   =&SPEC
;;;   (inout NAME SPEC)   read-write             =SPEC plus a hidden
;;;                                              tied input
;;;   (in NAME SPEC)      an input               SPEC
;;;   (clobber X ...)     clobbers               ~{X},...
;;;
;;; SPEC:
;;;   symbol              a constraint code, passed through: r, m, i,
;;;                       x, Upl, ... (target-specific; not validated
;;;                       here -- codegen diagnostics are the arbiter)
;;;   (reg NAME)          an explicit register: {NAME}
;;;   (tied NAME)         the same location as output NAME: its digit
;;;   (SPEC ...)          adjacent alternatives, concatenated: (r m)
;;;                       -> "rm"
;;;   string              verbatim escape hatch
;;;
;;; Template: a list of fragments -- strings (verbatim, $ escaped),
;;; operand names (-> $N), or (mod NAME M) (-> ${N:M}, LangRef's "asm
;;; template argument modifiers": register re-spelling, register-pair
;;; halves, immediate formatting, and more -- passed through);
;;; or a single plain string used verbatim (expert mode: you number
;;; operands yourself, nothing is escaped).
(library (sll asm)
  (export expr)
  (import (except (chezscheme) error)
          (prefix (llvm base) base:))

  (define (error msg . irritants)
    (apply base:error 'asm:expr msg irritants))

  (define flag-set '(sideeffect alignstack inteldialect unwind))

  (define (item-kind item)
    (and (pair? item) (memq (car item) '(out out! inout in clobber))
         (car item)))

  (define (check-operand-item item)
    (unless (and (= (length item) 3) (symbol? (cadr item)))
      (error "expected (out|out!|inout|in NAME SPEC)" item)))

  ;; NAME -> index alist for every non-clobber item, outputs first --
  ;; the $N numbering LangRef specifies
  (define (number-operands outs ins)
    (let loop ([items (append outs ins)] [i 0] [acc '()])
      (if (null? items)
          (reverse acc)
          (let ([name (cadr (car items))])
            (when (assq name acc)
              (error "duplicate operand name" name))
            (loop (cdr items) (+ i 1) (cons (cons name i) acc))))))

  (define (spec->string spec indices outs)
    (cond
      [(string? spec) spec]
      [(symbol? spec) (symbol->string spec)]
      [(and (pair? spec) (eq? (car spec) 'reg)
            (= (length spec) 2) (symbol? (cadr spec)))
       (format "{~a}" (cadr spec))]
      [(and (pair? spec) (eq? (car spec) 'tied) (= (length spec) 2))
       (let ([name (cadr spec)])
         (unless (exists (lambda (o) (eq? (cadr o) name)) outs)
           (error "(tied NAME) must reference an out/out!/inout operand"
                  spec))
         (number->string (cdr (assq name indices))))]
      [(and (list? spec) (pair? spec))
       (apply string-append
              (map (lambda (s) (spec->string s indices outs)) spec))]
      [else (error "invalid constraint spec" spec)]))

  (define (escape-dollars s)
    (let ([out (open-output-string)])
      (string-for-each
        (lambda (c)
          (if (char=? c #\$) (put-string out "$$") (put-char out c)))
        s)
      (get-output-string out)))

  (define (template->string template indices)
    (cond
      [(string? template) template]   ; expert mode: verbatim
      [(list? template)
       (apply string-append
              (map (lambda (f)
                     (cond
                       [(string? f) (escape-dollars f)]
                       [(symbol? f)
                        (let ([e (assq f indices)])
                          (unless e (error "unknown operand in template" f))
                          (string-append "$" (number->string (cdr e))))]
                       [(and (pair? f) (eq? (car f) 'mod) (= (length f) 3)
                             (symbol? (cadr f)) (symbol? (caddr f)))
                        (let ([e (assq (cadr f) indices)])
                          (unless e (error "unknown operand in template" f))
                          (format "${~a:~a}" (cdr e) (caddr f)))]
                       [else (error "invalid template fragment" f)]))
                   template))]
      [else (error "template must be a string or a fragment list"
                   template)]))

  ;; items + template + flags -> (asm "template" "constraints" flags...)
  (define (expr items template . flags)
    (unless (list? items) (error "expected a list of operand items" items))
    (for-each (lambda (f)
                (unless (memq f flag-set)
                  (error "unknown asm flag" f flag-set)))
              flags)
    (let* ([outs (filter (lambda (i) (memq (item-kind i) '(out out! inout)))
                         items)]
           [ins (filter (lambda (i) (eq? (item-kind i) 'in)) items)]
           [clobbers (filter (lambda (i) (eq? (item-kind i) 'clobber))
                             items)]
           [other (filter (lambda (i) (not (item-kind i))) items)])
      (unless (null? other)
        (error "unknown operand item" (car other)))
      (for-each check-operand-item (append outs ins))
      ;; (inout X S) = output "=S" plus a hidden input tied to X,
      ;; appended after the explicit inputs
      (let* ([hidden (map (lambda (o) `(in ,(gensym) (tied ,(cadr o))))
                          (filter (lambda (o) (eq? (car o) 'inout)) outs))]
             [ins (append ins hidden)]
             [indices (number-operands outs ins)]
             [constraint-items
              (append
                (map (lambda (o)
                       (string-append
                         (case (car o) [(out inout) "="] [(out!) "=&"])
                         (spec->string (caddr o) indices outs)))
                     outs)
                (map (lambda (i) (spec->string (caddr i) indices outs))
                     ins)
                (apply append
                       (map (lambda (c)
                              (map (lambda (x)
                                     (unless (symbol? x)
                                       (error "clobbers are symbols" x))
                                     (format "~~{~a}" x))
                                   (cdr c)))
                            clobbers)))]
             [constraints
              (if (null? constraint-items)
                  ""
                  (fold-left (lambda (acc s) (string-append acc "," s))
                             (car constraint-items)
                             (cdr constraint-items)))])
        `(asm ,(template->string template indices) ,constraints ,@flags)))))
