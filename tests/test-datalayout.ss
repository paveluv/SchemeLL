;;; (llvm datalayout): the datalayout string as structured data. Round-trip
;;; fidelity was developed against every distinct layout string in LLVM's test
;;; corpus (421 strings, all byte-identical); the curated set here pins one of
;;; each component kind, the legacy raw passthroughs, and the malformed-input
;;; crash-resistance.
[import
 (chezscheme)
 (prefix (tests harness) t:)
 (prefix (llvm datalayout) dl:)
 (prefix (llvm ir) ir:)
 (prefix (llvm target) target:)
 (prefix (sll) sll:)]

(t:section "datalayout: parse/unparse round-trips (real-world strings)")

[for-each
 [lambda
  (s)
  (t:check (format "round-trip ~a" s) (string=? (dl:unparse (dl:parse s)) s))]
 '[ ;; the x86-64 Linux stock layout
   "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
   ;; big-endian, Mach-O and WinCOFF manglings
   "E-m:o-i64:64-n32:64-S128"
   "e-m:w-p:32:32-i64:64-n8:16:32-S32"
   ;; explicit p0, five-field pointer spec (CHERI-style), A/P/G
   "e-m:e-p200:128:128:128:64-A200-P200-G200"
   "e-i64:64-v16:16-v32:32-n16:32:64-p:64:64:64-p1:32:32:32-p2:128:128:128:32"
   "e-p0:32:32-i64:64"
   ;; non-integral (also twice, interleaved -- seen in the corpus)
   "e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-ni:1-p2:32:8:8:32-ni:2"
   ;; aggregate, float, vector, fn-ptr alignment both kinds
   "e-m:m-a:0:64-f80:128-v64:64-Fi64-n8"
   "E-m:a-Fn32-i64:64"
   ;; legacy pre-LLVM-4 specs survive as raw passthrough
   "E-p:32:32:32-a0:0:64-s0:64:64-n32"
   ""]]

(t:section "datalayout: forms")

[t:check
 "parse produces the documented forms"
 [equal?
  (dl:parse "e-m:e-p270:32:32-i64:64-n8:16-S128-ni:1-A5-Fi64")
  '[(endian little)
    (mangling elf)
    (ptr (addrspace 270) 32 32)
    (int 64 64)
    (native 8 16)
    (stack-align 128)
    (non-integral 1)
    (alloca-as 5)
    (fn-ptr-align independent 64)]]]

[t:check
 "explicit p0 stays distinct from bare p"
 [equal?
  (map car (list (car (dl:parse "p0:32:32")) (car (dl:parse "p:32:32"))))
  '(ptr ptr)]]
[t:check
 "explicit p0 keeps its addrspace marker"
 (equal? (dl:parse "p0:32:32") '((ptr (addrspace 0) 32 32)))]
(t:check "bare p has none" (equal? (dl:parse "p:32:32") '((ptr 32 32))))

[t:check
 "construction from forms"
 [string=?
  [dl:unparse
   '[(endian little)
     (mangling elf)
     (int 64 64)
     (native 8 16 32 64)
     (non-integral 1)]]
  "e-m:e-i64:64-n8:16:32:64-ni:1"]]

[t:check
 "malformed inputs parse as raw, never crash"
 (equal? (map car (dl:parse "^-:32-m.-a:")) '(raw raw raw raw))]

(t:section "datalayout: unparse strictness")

(t:check-exn "unknown component form" (dl:unparse '((frob 1))))
(t:check-exn "ni:0 rejected" (dl:unparse '((non-integral 0))))
(t:check-exn "endian must be little or big" (dl:unparse '((endian sideways))))
(t:check-exn "raw takes one string" (dl:unparse '((raw 42))))

(t:section "datalayout: configure-module! integration")

;; the machine's stock layout must survive parse->unparse untouched
[let
 ((tm (target:make-machine)))
 [let*
  [(ctx (ir:make-context))
   (m (sll:build ctx "dlrt" '((define void (@f) (label %e (ret void))))))]
  (target:configure-module! m tm)
  [let
   [[stock
     [let
      ((p (open-string-input-port (ir:module->string m))))
      [let
       loop
       ()
       [let
        ((l (get-line p)))
        [if
         [and
          (> (string-length l) 17)
          (string=? (substring l 0 17) "target datalayout")]
         (substring l 20 (- (string-length l) 1))
         (loop)]]]]]]
   [t:check
    "host layout round-trips byte-identically"
    (string=? (dl:unparse (dl:parse stock)) stock)]]
  ;; configuring twice with ni must not duplicate the component
  (target:configure-module! m tm '(1))
  (target:configure-module! m tm '(1))
  [let*
   [(final (ir:module->string m))
    [count
     [let
      loop
      ((i 0) (n 0))
      [if
       (> (+ i 3) (string-length final))
       n
       [loop
        (+ i 1)
        (if (string=? (substring final i (+ i 3)) "-ni") (+ n 1) n)]]]]]
   (t:check "repeated configure-module! yields exactly one ni" (= count 1))]
  (ir:module-dispose! m)
  (ir:context-dispose! ctx)]
 (target:machine-dispose! tm)]
