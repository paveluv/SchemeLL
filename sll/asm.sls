;;; (sll asm) -- structured inline-asm expressions.
;;;
;;; A one-directional generator: s-expressions in, an ordinary sll (asm
;;; "template" "constraints" flags...) callee form out. The core sll grammar
;;; keeps asm as verbatim strings (isomorphic to LLVM IR); this library adds the
;;; structure LangRef actually specifies -- output/input/clobber ordering,
;;; =/&/tied operands, {register} references, operand numbering -- while passing
;;; the open-ended per-target constraint letters (r, m, x, Upl, ...) through
;;; uninterpreted.
;;;
;;;   (asm:expr
;;;     '((out  sum r)              ; "=r"      -> $sum is operand 0
;;;       (in   a (tied sum))       ; "0"       -> tied to sum's location
;;;       (in   b r)                ; "r"
;;;       (clobber cc))             ; "~{cc}"
;;;     '("add " b ", " sum)        ; template: "add ${2}, ${0}"
;;;     'sideeffect)
;;;   => (asm "add ${2}, ${0}" "=r,0,r,~{cc}" sideeffect)
;;;
;;; Operands are referenced BY NAME in the template and in (tied ...); the
;;; library computes the $N numbering (outputs first, then inputs, as LangRef
;;; specifies), which removes the two classic hand-written asm bug classes:
;;; mis-numbered operands and malformed constraint strings. Literal $ in
;;; template strings is escaped automatically.
;;;
;;; Items:
;;;   (out NAME? SPEC)    an output              =SPEC
;;;   (out! NAME? SPEC)   early-clobber output   =&SPEC
;;;   (inout NAME? SPEC)  read-write             =SPEC plus a hidden
;;;                                              tied input
;;;   (in NAME? SPEC)     an input               SPEC
;;;   (clobber X ...)     clobbers               ~{X},...
;;; NAME is optional: anonymous operands cannot be referenced by
;;; (tied ...) or the template, which plain-string templates never do
;;; anyway. A LIST of items may appear where an item is expected and
;;; is spliced -- generators can return item lists without the caller
;;; resorting to unquote-splicing.
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
;;; Template: a list of fragments -- strings (verbatim, $ escaped), operand
;;; names (-> $N), or (mod NAME M) (-> ${N:M}, LangRef's "asm template argument
;;; modifiers": register re-spelling, register-pair halves, immediate
;;; formatting, and more -- passed through); or a single plain string used
;;; verbatim (expert mode: you number operands yourself, nothing is escaped).
[library
 (sll asm)
 (export expr)
 (import (except (chezscheme) error) (prefix (llvm base) base:))

 (define (error msg . irritants) (apply base:error 'asm:expr msg irritants))

 (define flag-set '(sideeffect alignstack inteldialect unwind))

 [define
  (item-kind item)
  (and (pair? item) (memq (car item) '(out out! inout in clobber)) (car item))]

 ;; normalize (KIND SPEC) -> (KIND #f SPEC); flatten spliced sublists
 [define
  (normalize-items items)
  [apply
   append
   [map
    [lambda
     (item)
     [cond
      [(item-kind item)
       [if
        (eq? (car item) 'clobber)
        (list item)
        [case
         (length item)
         [(2)
          [list
           [list
            (car item)
            ;; inout's hidden tied input references its output by name, so it
            ;; gets one
            (and (eq? (car item) 'inout) (gensym))
            (cadr item)]]]
         [(3)
          ;; an explicit #f name on inout still needs the internal name its
          ;; hidden tied input references
          [list
           [if
            (and (eq? (car item) 'inout) (not (cadr item)))
            (list 'inout (gensym) (caddr item))
            item]]]
         (else (error "expected (out|out!|inout|in NAME? SPEC)" item))]]]
      ((list? item) (normalize-items item)) ; splice
      (else (error "unknown operand item" item))]]
    items]]]

 [define
  (check-operand-item item)
  [unless
   (or (not (cadr item)) (symbol? (cadr item)))
   (error "operand name must be a symbol" item)]]

 ;; NAME -> index alist for every non-clobber item, outputs first -- the $N
 ;; numbering LangRef specifies
 [define
  (number-operands outs ins)
  [let
   loop
   ((items (append outs ins)) (i 0) (acc '()))
   [if
    (null? items)
    (reverse acc)
    [let
     ((name (cadr (car items))))
     (when (and name (assq name acc)) (error "duplicate operand name" name))
     (loop (cdr items) (+ i 1) (if name (cons (cons name i) acc) acc))]]]]

 [define
  (spec->string spec indices outs)
  [cond
   ((string? spec) spec)
   ((symbol? spec) (symbol->string spec))
   [[and
     (pair? spec)
     (eq? (car spec) 'reg)
     (= (length spec) 2)
     (symbol? (cadr spec))]
    (format "{~a}" (cadr spec))]
   [(and (pair? spec) (eq? (car spec) 'tied) (= (length spec) 2))
    [let
     ((name (cadr spec)))
     [unless
      [and
       name
       (symbol? name)
       (exists (lambda (o) (eq? (cadr o) name)) outs)
       (assq name indices)]
      (error "(tied NAME) must reference a NAMED out/out!/inout operand" spec)]
     (number->string (cdr (assq name indices)))]]
   [(and (list? spec) (pair? spec))
    ;; alternatives -- but a malformed (reg ...) or (tied ...) that failed its
    ;; shape check above must not silently concatenate
    [when
     (memq (car spec) '(reg tied))
     (error "malformed constraint spec" spec)]
    (apply string-append (map (lambda (s) (spec->string s indices outs)) spec))]
   (else (error "invalid constraint spec" spec))]]

 [define
  (escape-dollars s)
  [let
   ((out (open-output-string)))
   [string-for-each
    (lambda (c) (if (char=? c #\$) (put-string out "$$") (put-char out c)))
    s]
   (get-output-string out)]]

 [define
  (template->string template indices)
  [cond
   ((string? template) template) ; expert mode: verbatim
   [(list? template)
    [apply
     string-append
     [map
      [lambda
       (f)
       [cond
        ((string? f) (escape-dollars f))
        [(symbol? f)
         [let
          ((e (assq f indices)))
          (unless e (error "unknown operand in template" f))
          ;; braced: a following digit-initial fragment must not merge into the
          ;; operand number
          (format "${~a}" (cdr e))]]
        [[and
          (pair? f)
          (eq? (car f) 'mod)
          (= (length f) 3)
          (symbol? (cadr f))
          (symbol? (caddr f))]
         [let
          ((e (assq (cadr f) indices)))
          (unless e (error "unknown operand in template" f))
          (format "${~a:~a}" (cdr e) (caddr f))]]
        (else (error "invalid template fragment" f))]]
      template]]]
   (else (error "template must be a string or a fragment list" template))]]

 ;; items + template + flags -> (asm "template" "constraints" flags...)
 [define
  (expr items template . flags0)
  (unless (list? items) (error "expected a list of operand items" items))
  [let
   ((flags (apply append (map (lambda (f) (if (list? f) f (list f))) flags0))))
   [for-each
    [lambda
     (f)
     (unless (memq f flag-set) (error "unknown asm flag" f flag-set))]
    flags]
   (expr* (normalize-items items) template flags)]]

 [define
  (expr* items template flags)
  [let*
   [(outs (filter (lambda (i) (memq (item-kind i) '(out out! inout))) items))
    (ins (filter (lambda (i) (eq? (item-kind i) 'in)) items))
    (clobbers (filter (lambda (i) (eq? (item-kind i) 'clobber)) items))]
   (for-each check-operand-item (append outs ins))
   ;; (inout X S) = output "=S" plus a hidden input tied to X, appended after
   ;; the explicit inputs
   [let*
    [[hidden
      [map
       (lambda (o) `(in ,(gensym) (tied ,(cadr o))))
       (filter (lambda (o) (eq? (car o) 'inout)) outs)]]
     (ins (append ins hidden))
     (indices (number-operands outs ins))
     [constraint-items
      [append
       [map
        [lambda
         (o)
         [string-append
          (case (car o) ((out inout) "=") ((out!) "=&"))
          (spec->string (caddr o) indices outs)]]
        outs]
       (map (lambda (i) (spec->string (caddr i) indices outs)) ins)
       [apply
        append
        [map
         [lambda
          (c)
          [map
           [lambda
            (x)
            (unless (symbol? x) (error "clobbers are symbols" x))
            (format "~~{~a}" x)]
           (cdr c)]]
         clobbers]]]]
     [constraints
      [if
       (null? constraint-items)
       ""
       [fold-left
        (lambda (acc s) (string-append acc "," s))
        (car constraint-items)
        (cdr constraint-items)]]]]
    `(asm ,(template->string template indices) ,constraints ,@flags)]]]]
