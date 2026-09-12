;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; Arbitrary-width integers: 128-bit multiply internally, i64 halves at the FFI
;;; boundary (Chez's FFI speaks up to 64 bits).
(import (chezscheme) (prefix (sll) sll:))

[define
 mulhi
 [sll:procedure
  '[[define
     i64
     (@mulhi64 (i64 %a) (i64 %b))
     [label
      %entry
      (= %wa (zext i64 %a i128))
      (= %wb (zext i64 %b i128))
      (= %prod (mul i128 %wa %wb))
      (= %hi (lshr i128 %prod 64))
      (= %r (trunc i128 %hi i64))
      (ret i64 %r)]]]
  "mulhi64"]]

(printf "high 64 bits of (2^62 * 6) = ~a~%" (mulhi (expt 2 62) 6))
