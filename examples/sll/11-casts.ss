;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; The cast family: truncation, extension (with nuw/nsw/nneg flags), and
;;; pointer<->integer round trips.
(import (chezscheme) (prefix (sll) sll:) (prefix (llvm config) config:))

;; the nneg/nsw flags need the LLVM 18 flag setters
[unless
 (config:capability? 'flag-accessors)
 [printf
  "skipped: instruction flags need the LLVM 18 C API (this is LLVM ~a)~%"
  config:major-version]
 (exit 0)]

[define
 prog
 '[[define
    i64
    (@low_byte_squared (i64 %x))
    [label
     %entry
     (= %b (trunc i64 %x i8))
     (= %w (zext nneg i8 %b i64))
     (= %sq (mul nsw i64 %w %w))
     (ret i64 %sq)]]
   [define
    i64
    (@ptr_roundtrip (ptr %p))
    [label
     %entry
     (= %addr (ptrtoint ptr %p i64))
     (= %back (inttoptr i64 %addr ptr))
     (= %same (icmp eq ptr %p %back))
     (= %r (zext i1 %same i64))
     (ret i64 %r)]]]]

(define lbs (sll:procedure prog "low_byte_squared"))
(printf "low-byte(#x1234567890abcd11)^2 = ~a~%" (lbs #x1234567890abcd11))
