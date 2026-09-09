;;; Diagnose corpus MISMATCH files: re-run the round trip and print the
;;; first differing line of each (A side), masked so signatures group.
;;;   scheme --libdirs . --script tests/probe-mismatch.ss [failures-file]
;;; Pipe through `sort | uniq -c | sort -rn` for the histogram.
[import
 (chezscheme)
 (prefix (llvm ir) ir:)
 (prefix (sll) sll:)
 (prefix (tests normalize) n:)]

[define
 failures-file
 [let
  ((args (cdr (command-line))))
  (if (pair? args) (car args) "tests/tmp/corpus-failures.txt")]]

[define
 (after-marker s marker)
 [let
  ((n (string-length s)) (m (string-length marker)))
  [let
   loop
   ((i 0))
   [cond
    ((> (+ i m) n) #f)
    ((string=? (substring s i (+ i m)) marker) (substring s (+ i m) n))
    (else (loop (+ i 1)))]]]]

;; mask %names, @names and numbers so identical shapes group together
[define
 (mask l)
 [let
  ((out (open-output-string)) (n (string-length l)))
  [let
   loop
   ((i 0))
   [if
    (>= i n)
    (get-output-string out)
    [let
     ((c (string-ref l i)))
     [cond
      [(or (char=? c #\%) (char=? c #\@))
       (put-char out c)
       (put-char out #\V)
       [let
        skip
        ((j (+ i 1)))
        [if
         [and
          (< j n)
          [let
           ((d (string-ref l j)))
           [or
            (char-alphabetic? d)
            (char-numeric? d)
            (memv d '(#\. #\_ #\$ #\-))]]]
         (skip (+ j 1))
         (loop j)]]]
      [(char-numeric? c)
       (put-char out #\N)
       [let
        skip
        ((j (+ i 1)))
        [if
         [and
          (< j n)
          [let
           ((d (string-ref l j)))
           (or (char-numeric? d) (memv d '(#\. #\x #\e #\+ #\-)))]]
         (skip (+ j 1))
         (loop j)]]]
      (else (put-char out c) (loop (+ i 1)))]]]]]]

[define
 (first-diff a b)
 [let
  ((pa (open-string-input-port a)) (pb (open-string-input-port b)))
  [let
   loop
   ()
   [let
    ((la (get-line pa)) (lb (get-line pb)))
    [cond
     ((and (eof-object? la) (eof-object? lb)) #f)
     ((eof-object? la) (cons "<A ended early>" lb))
     ((eof-object? lb) (cons la "<B ended early>"))
     ((not (equal? la lb)) (cons la lb))
     (else (loop))]]]]]

[define
 (probe path)
 [guard
  [e
   [#t
    [printf
     "PROBE-ERROR ~a~%"
     (if (message-condition? e) (condition-message e) e)]]]
  [let*
   [(ctx (ir:make-context))
    (rctx (ir:make-context))
    (m (ir:parse-ir ctx path (call-with-input-file path get-string-all)))]
   (n:normalize-module! m)
   [let*
    [(a (n:comparable-ir (ir:module->string m)))
     (prog (sll:unbuild m 'ignore-named-metadata))
     (m2 (sll:build rctx "c" prog))]
    (n:normalize-module! m2)
    [let
     ((b (n:comparable-ir (ir:module->string m2))))
     [cond
      ((string=? a b) (printf "NOW-EQUAL~%"))
      ((first-diff a b) => (lambda (d) (printf "A: ~a~%" (mask (car d)))))]]]]]]

[call-with-input-file
 failures-file
 [lambda
  (p)
  [let
   loop
   ()
   [let
    ((l (get-line p)))
    [unless
     (eof-object? l)
     [let
      [[sp
        [let
         find
         ((j 0))
         [cond
          ((= j (string-length l)) #f)
          ((char=? (string-ref l j) #\space) j)
          (else (find (+ j 1)))]]]]
      (when (and sp (after-marker l "MISMATCH")) (probe (substring l 0 sp)))]
     (loop)]]]]]
