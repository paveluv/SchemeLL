;;; (sll asm) -- the structured inline-asm generator.
[import
 (chezscheme)
 (prefix (tests harness) t:)
 (prefix (sll asm) asm:)
 (prefix (sll) sll:)
 (prefix (llvm target) target:)]

(t:section "asm: constraint generation")

[t:check
 "outputs, tied input, clobber"
 [equal?
  [asm:expr
   '((out sum r) (in a (tied sum)) (in b r) (clobber cc))
   '("add " b ", " sum)
   'sideeffect]
  '(asm "add ${2}, ${0}" "=r,0,r,~{cc}" sideeffect)]]

[t:check
 "explicit registers reproduce the hand-written hello string"
 [equal?
  [asm:expr
   '[(out ret (reg rax))
     (in nr (reg rax))
     (in fd (reg rdi))
     (in buf (reg rsi))
     (in len (reg rdx))
     (clobber rcx r11 memory)]
   "syscall"
   'sideeffect]
  '[asm
    "syscall"
    "={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}"
    sideeffect]]]

[t:check
 "inout lowers to output + hidden tied input"
 [equal?
  (asm:expr '((inout x r)) '("incq " x) 'sideeffect)
  '(asm "incq ${0}" "=r,0" sideeffect)]]

[t:check
 "early clobber, alternatives, modifiers, $ escaping"
 [equal?
  [asm:expr
   '[(out! d (r m))
     (in   s r    )]
   '("mov " (mod s w) ", " d "  # costs $$5")]
  '(asm "mov ${1:w}, ${0}  # costs $$$$5" "=&rm,r")]]

[t:check
 "item order does not matter (numbering is canonical)"
 [equal?
  [asm:expr
   '[(in  a (tied b))
     (out b r       )]
   "nop"]
  '(asm "nop" "=r,0")]]

[t:check-exn
 "tied must reference an output"
 [asm:expr
  '[(in  a (tied nothing))
    (out b r             )]
  "nop"]]
[t:check-exn
 "duplicate names rejected"
 [asm:expr
  '[(out x r)
    (in  x r)]
  "nop"]]
[t:check-exn
 "unknown template operand rejected"
 (asm:expr '((out x r)) '("mov " y))]
(t:check-exn "unknown flag rejected" (asm:expr '((out x r)) "nop" 'sideffect))

(t:section "asm: end to end")

;; the template is the host's: AT&T "add src, dst" on x86, three-operand "add
;; dst, src1, src2" on AArch64 -- the operand names and numbering are the same
;; either way
[define
 add-template
 [let
  ((host (target:native-target-name)))
  [cond
   ((string=? host "X86") '("add " b ", " sum))
   ((string=? host "AArch64") '("add " sum ", " sum ", " b))
   (else (error 'test-asm "no add template for this host" host))]]]

[t:check
 "generated asm JITs and runs"
 [=
  42
  [[sll:procedure
    `[[define
       i64
       (@f (i64 %a) (i64 %b))
       [label
        %entry
        [=
         %r
         [call
          i64
          [,[asm:expr
             '[(out sum r         )
               (in  a   (tied sum))
               (in  b   r         )]
             add-template
             'sideeffect]
           (i64 %a)
           (i64 %b)]]]
        (ret i64 %r)]]]
    "f"]
   40
   2]]]

(t:section "asm: generator ergonomics")

[t:check
 "anonymous operands and spliced sublists"
 [equal?
  [asm:expr
   [list
    '(out (reg rax))
    '(in (reg rax))
    (map (lambda (r) `(in (reg ,r))) '(rdi rsi))
    '(clobber memory)]
   "syscall"
   '(sideeffect)]
  '(asm "syscall" "={rax},{rax},{rdi},{rsi},~{memory}" sideeffect)]]

[t:check
 "anonymous inout still ties correctly"
 (equal? (asm:expr '((inout r)) "incq $0") '(asm "incq $0" "=r,0"))]

[t:check-exn
 "anonymous operands cannot be referenced in templates"
 (asm:expr '((out (reg rax))) '("mov " ret))]

(t:section "asm: bug-hunt regressions")

[t:check
 "operand refs are braced (digit fragments cannot merge)"
 [equal?
  [asm:expr
   '[(out d r)
     (in  a r)]
   '("addq $" a "1, " d)]
  '(asm "addq $$${1}1, ${0}" "=r,r")]]
[t:check
 "anonymous inout with explicit #f name"
 (equal? (asm:expr '((inout #f r)) "incq $0") '(asm "incq $0" "=r,0"))]
[t:check-exn
 "tied to an anonymous operand is an error"
 [asm:expr
  '[(out #f r        )
    (in  a  (tied #f))]
  "nop"]]
[t:check-exn
 "malformed (reg ...) does not concatenate"
 (asm:expr '((in a (reg rax rbx))) "nop")]
[t:check-exn
 "malformed (tied ...) does not concatenate"
 [asm:expr
  '[(out o r             )
    (in  a (tied o extra))]
  "nop"]]
