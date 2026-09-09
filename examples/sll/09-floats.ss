;;; Floating point: arithmetic, fast-math flags, fcmp, select.
(import (chezscheme) (prefix (sll) sll:))

[define
 clamped-mean
 [sll:procedure
  '[[define
     double
     (@clamped_mean (double %a) (double %b))
     [label
      %entry
      (= %sum (fadd fast double %a %b))
      (= %mean (fmul fast double %sum 0.5))
      (= %toobig (fcmp ogt double %mean 100.0))
      (= %r (select (i1 %toobig) (double 100.0) (double %mean)))
      (ret double %r)]]]
  "clamped_mean"]]

(printf "mean(3.0, 4.0)     = ~a~%" (clamped-mean 3.0 4.0))

(printf "mean(300.0, 400.0) = ~a (clamped)~%" (clamped-mean 300.0 400.0))
