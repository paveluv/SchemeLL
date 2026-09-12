;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; Calling into the host process: the JIT resolves libc symbols, so a plain
;;; (declare ...) is all it takes.
(import (chezscheme) (prefix (sll) sll:))

[define
 prog
 '[(declare double (@cos double))
   (declare double (@sqrt double))
   [define
    double
    (@cos_deg (double %deg))
    [label
     %entry
     (= %rad (fmul double %deg 0.017453292519943295))
     (= %c (call double (@cos (double %rad))))
     (ret double %c)]]
   [define
    double
    (@hyp (double %a) (double %b))
    [label
     %entry
     (= %aa (fmul double %a %a))
     (= %bb (fmul double %b %b))
     (= %s (fadd double %aa %bb))
     (= %r (call double (@sqrt (double %s))))
     (ret double %r)]]]]

(define cos-deg (sll:procedure prog "cos_deg"))
(printf "cos(60deg) = ~a~%" (cos-deg 60.0))
