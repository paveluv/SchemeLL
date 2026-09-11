;;; Detect LLVM instruction flags that have no C API accessor. Inspect only the
;;; canonical opcode prefix, skipping a quoted/escaped SSA result name.
[library
 (llvm text-flags)
 (export leading-flag?)
 (import (chezscheme) (prefix (llvm raw) LLVM) (prefix (llvm base) base:))
 [define
  (leading-flag? instruction flag)
  [let*
   [(text (base:cstring->string/dispose (LLVMPrintValueToString instruction)))
    (n (string-length text))]
   [let
    loop
    ((i 0) (quoted? #f) (escaped? #f))
    [cond
     ((= i n) #f)
     (escaped? (loop (+ i 1) quoted? #f))
     ((and quoted? (char=? (string-ref text i) #\\)) (loop (+ i 1) quoted? #t))
     ((char=? (string-ref text i) #\") (loop (+ i 1) (not quoted?) #f))
     [(and (not quoted?) (char=? (string-ref text i) #\=))
      [let
       ((p (open-string-input-port (substring text (+ i 1) n))))
       (read p)
       (eq? (read p) flag)]]
     (else (loop (+ i 1) quoted? #f))]]]]]
