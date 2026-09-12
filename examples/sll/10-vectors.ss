;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; SIMD vectors: literals, lane arithmetic, shufflevector, extractelement.
(import (chezscheme) (prefix (sll) sll:))

[define
 horizontal-max
 [sll:procedure
  '[[define
     i32
     (@hmax4 (i32 %a) (i32 %b) (i32 %c) (i32 %d))
     [label
      %entry
      (= %v0 (insertelement ((vector 4 i32) undef) (i32 %a) (i32 0)))
      (= %v1 (insertelement ((vector 4 i32) %v0) (i32 %b) (i32 1)))
      (= %v2 (insertelement ((vector 4 i32) %v1) (i32 %c) (i32 2)))
      (= %v (insertelement ((vector 4 i32) %v2) (i32 %d) (i32 3)))
      ;; compare against the lanes rotated by 2, keep the larger
      [=
       %sh
       [shufflevector
        ((vector 4 i32) %v)
        ((vector 4 i32) poison)
        (mask 2 3 0 1)]]
      (= %gt (icmp sgt (vector 4 i32) %v %sh))
      [=
       %m1
       (select ((vector 4 i1) %gt) ((vector 4 i32) %v) ((vector 4 i32) %sh))]
      ;; then by 1
      [=
       %sh2
       [shufflevector
        ((vector 4 i32) %m1)
        ((vector 4 i32) poison)
        (mask 1 0 3 2)]]
      (= %gt2 (icmp sgt (vector 4 i32) %m1 %sh2))
      [=
       %m2
       (select ((vector 4 i1) %gt2) ((vector 4 i32) %m1) ((vector 4 i32) %sh2))]
      (= %r (extractelement ((vector 4 i32) %m2) (i32 0)))
      (ret i32 %r)]]]
  "hmax4"]]

(printf "max(3 41 17 9) = ~a~%" (horizontal-max 3 41 17 9))
