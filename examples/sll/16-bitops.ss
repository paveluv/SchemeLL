;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; Bit twiddling: shifts, masks, and a popcount loop.
(import (chezscheme) (prefix (sll) sll:))

[define
 popcount
 [sll:procedure
  '[[define
     i64
     (@popcount (i64 %x))
     (label %entry (br (label %loop)))
     [label
      %loop
      (= %v (phi i64 (%x %entry) (%v1 %loop)))
      (= %n (phi i64 (0 %entry) (%n1 %loop)))
      (= %bit (and i64 %v 1))
      (= %n1 (add i64 %n %bit))
      (= %v1 (lshr i64 %v 1))
      (= %done (icmp eq i64 %v1 0))
      (br i1 %done (label %exit) (label %loop))]
     (label %exit (ret i64 %n1))]]
  "popcount"]]

(printf "popcount(#xFF00FF)   = ~a~%" (popcount #xFF00FF))
(printf "popcount(#b10110111) = ~a~%" (popcount #b10110111))
