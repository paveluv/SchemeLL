;;; Corpus round-trip harness (coverage plan, level 3).
;;;
;;;   scheme --libdirs . --script tests/corpus.ss [directory]
;;;
;;; For every .ll file under the directory (default: LLVM's own regression
;;; corpus in reference/llvm-project/llvm/test):
;;;
;;;   parse -> normalize (strip what sll does not model, (tests normalize))
;;;         -> A := canonical print
;;;         -> sll:unbuild -> sll:build -> B := canonical print
;;;   PASS iff A == B.
;;;
;;; Buckets: PASS; parse-fail (LLVM's own parser rejects -- many corpus files
;;; are intentionally invalid or fragments); not modeled: <construct>
;;; (sll:unbuild's strict errors classify the file); MISMATCH and build-fail
;;; (bugs in our layer -- the burn-down list). Sorted counts at the end;
;;; mismatch/build-fail paths are written to tests/tmp/corpus-failures.txt.
(load "host/bootstrap.ss")
[import
 (chezscheme)
 (prefix (llvm ir) ir:)
 (prefix (llvm config) config:)
 (prefix (sll) sll:)
 (prefix (tests normalize) n:)
 (prefix (sll render) render:)]

[define
 root
 [let
  ((args (cdr (command-line))))
  (if (pair? args) (car args) "reference/llvm-project/llvm/test")]]

;; ---- file walk -----------------------------------------------------------

[define
 (ll-file? name)
 [let
  ((n (string-length name)))
  (and (> n 3) (string=? (substring name (- n 3) n) ".ll"))]]

[define
 (find-ll-files dir)
 [let
  loop
  ((dirs (list dir)) (acc '()))
  [if
   (null? dirs)
   acc
   [let
    ((d (car dirs)))
    [let
     inner
     [(entries (guard (e (#t '())) (directory-list d)))
      (dirs (cdr dirs))
      (acc acc)]
     [if
      (null? entries)
      (loop dirs acc)
      [let
       ((p (string-append d "/" (car entries))))
       [cond
        ((file-directory? p) (inner (cdr entries) (cons p dirs) acc))
        ((ll-file? p) (inner (cdr entries) dirs (cons p acc)))
        (else (inner (cdr entries) dirs acc))]]]]]]]]

;; ---- classification ---------------------------------------------------------

(define stats (make-hashtable string-hash string=?))
(define failures '())           ; (path . bucket) for MISMATCH / build-fail
(define bucketed '())           ; (path . bucket) for every non-PASS file

(define (bucket! key) (hashtable-update! stats key (lambda (n) (+ n 1)) 0))

[define
 (starts-with? s prefix)
 [and
  (>= (string-length s) (string-length prefix))
  (string=? (substring s 0 (string-length prefix)) prefix)]]

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

[define
 (classify e)
 [let
  [(who (and (who-condition? e) (condition-who e)))
   (msg (if (message-condition? e) (condition-message e) "?"))]
  [cond
   ((eq? who 'ir:parse-ir) "parse-fail (LLVM rejects the file)")
   [(after-marker msg "not-modeled.md): ")
    =>
    (lambda (what) (string-append "not modeled: " what))]
   ((eq? who 'sll:build) (string-append "BUG build-fail: " msg))
   (else (string-append "BUG error: " msg))]]]

;; ---- the round trip
;; -----------------------------------------------------------

;; first chance for files the builder's constant folding excludes from the
;; strict comparison: render the sll program to text in pure Scheme and
;; construct through LLVM's parser, which never folds -- this makes the ORIGINAL
;; strict comparison possible again (a is the comparable parse-side text)
[define
 (render-strict? m a)
 [guard
  (e (#t #f))
  [let*
   [(prog (sll:unbuild m 'ignore-named-metadata 'tolerate-builder-folds))
    (ctx2 (ir:make-context))
    (m2 (ir:parse-ir ctx2 "rendered" (render:sll->ll prog)))]
   (n:normalize-module! m2)
   [let
    ((b (n:comparable-ir (ir:module->string m2))))
    (ir:module-dispose! m2)
    (ir:context-dispose! ctx2)
    (string=? a b)]]]]

;; second chance: rebuild tolerating folds, then verify the result is a FIXPOINT
;; -- parse our own print, round-trip again, and demand stability. Catches
;; divergence; lossy-but-stable transforms are exactly what the strict tier
;; exists for, so this tier is only entered when the strict one cannot apply.
[define
 (fold-fixpoint? m rctx)
 [guard
  (e (#t #f))
  [let*
   [(prog (sll:unbuild m 'ignore-named-metadata 'tolerate-builder-folds))
    (m2 (sll:build rctx "fx1" prog))]
   (n:normalize-module! m2)
   [let*
    [(text2 (ir:module->string m2))
     (b (n:comparable-ir text2))
     (ctx3 (ir:make-context))
     (rctx3 (ir:make-context))
     (m3 (ir:parse-ir ctx3 "fx" text2))]
    (n:normalize-module! m3)
    [let*
     [(prog2 (sll:unbuild m3 'ignore-named-metadata 'tolerate-builder-folds))
      (m4 (sll:build rctx3 "fx2" prog2))]
     (n:normalize-module! m4)
     [let
      ((b2 (n:comparable-ir (ir:module->string m4))))
      (ir:module-dispose! m4)
      (ir:module-dispose! m3)
      (ir:module-dispose! m2)
      (ir:context-dispose! ctx3)
      (ir:context-dispose! rctx3)
      (string=? b b2)]]]]]]

;; permanent construction benchmark, aggregated over every PASS file: direct
;; C-API build vs pure-Scheme render + LLVM parse (one shot each; the corpus
;; size smooths the noise)
(define bench-n 0)
(define build-ns 0)
(define render-ns 0)
(define parse-ns 0)

[define
 (now-ns)
 [let
  ((t (current-time 'time-monotonic)))
  (+ (* (time-second t) 1000000000) (time-nanosecond t))]]

(define bench-failed '())       ; PASS files whose render or re-parse failed

[define
 (bench-render+parse! path prog build-dt)
 [guard
  (e (#t (set! bench-failed (cons path bench-failed))))
  [let*
   [(t0 (now-ns))
    (text (render:sll->ll prog))
    (t1 (now-ns))
    (ctx (ir:make-context))
    (m (ir:parse-ir ctx "bench" text))
    (t2 (now-ns))]
   (ir:module-dispose! m)
   (ir:context-dispose! ctx)
   (set! bench-n (+ bench-n 1))
   (set! build-ns (+ build-ns build-dt))
   (set! render-ns (+ render-ns (- t1 t0)))
   (set! parse-ns (+ parse-ns (- t2 t1)))]]]

[define
 (folding-bucket? b)
 [or
  (after-marker b "all-constant operands")
  (after-marker b "no-op casts")
  (after-marker b "multi-index extractvalue")]]

[define
 (process path)
 [let
  ((text (guard (e (#t #f)) (call-with-input-file path get-string-all))))
  [cond
   ((not text) (bucket! "unreadable file"))
   ((> (string-length text) 2000000) (bucket! "skipped (> 2MB)"))
   [else
    ;; separate contexts: named struct types are context-registered, so
    ;; rebuilding in the parse context would collide
    [let
     ((ctx (ir:make-context)) (rctx (ir:make-context)) (m #f) (m2 #f))
     [guard
      [e
       [#t
        [let
         ((b (classify e)))
         [cond
          ;; m is already normalized when unbuild's folding detection fires, so
          ;; the strict A text is recomputable here
          [[and
            (folding-bucket? b)
            m
            [render-strict?
             m
             (guard (e2 (#t #f)) (n:comparable-ir (ir:module->string m)))]]
           (bucket! "PASS (via text renderer)")]
          [(and (folding-bucket? b) m (fold-fixpoint? m rctx))
           (bucket! "PASS (modulo builder folding)")]
          [else
           (bucket! b)
           (set! bucketed (cons (cons path b) bucketed))
           [when
            (starts-with? b "BUG")
            (set! failures (cons (cons path b) failures))]]]]]]
      (set! m (ir:parse-ir ctx path text))
      (n:normalize-module! m)
      [let
       ((a (n:comparable-ir (ir:module->string m))))
       [let*
        [(prog (sll:unbuild m 'ignore-named-metadata))
         (t0 (now-ns))
         [build-dt
          (begin (set! m2 (sll:build rctx "corpus" prog)) (- (now-ns) t0))]]
        ;; normalize the rebuild too: LLVM auto-attaches intrinsic attributes to
        ;; declarations it recognizes
        (n:normalize-module! m2)
        [let
         ((b (n:comparable-ir (ir:module->string m2))))
         [cond
          [(string=? a b)
           (bucket! "PASS")
           (bench-render+parse! path prog build-dt)]
          ;; LLVM's maximum alignment; LLVMGetAlignment returns 0 for it,
          ;; indistinguishable from unset -- only the parse-side text can
          ;; witness the loss
          [(after-marker a "align 4294967296")
           [bucket!
            "not modeled: alignment of 2^32 (LLVMGetAlignment truncates it to 0)"]]
          [else
           (bucket! "MISMATCH (bug)")
           (set! failures (cons (cons path "MISMATCH") failures))]]]]]]
     (when m2 (guard (e (#t #f)) (ir:module-dispose! m2)))
     (when m (guard (e (#t #f)) (ir:module-dispose! m)))
     (ir:context-dispose! ctx)
     (ir:context-dispose! rctx)]]]]]

;; ---- run
;; --------------------------------------------------------------------------

[unless
 (file-directory? root)
 (error 'corpus "missing LLVM corpus directory" root)]
(printf "LLVM ~s; collecting .ll files under ~a ...~%" (config:version) root)
(define files (find-ll-files root))
(when (null? files) (error 'corpus "no LLVM IR files found" root))
(printf "~a files~%" (length files))

[let
 loop
 ((fs files) (i 0))
 [unless
  (null? fs)
  [when
   (and (positive? i) (zero? (mod i 2000)))
   (printf "  ... ~a files processed~%" i)
   (flush-output-port (current-output-port))]
  (process (car fs))
  (loop (cdr fs) (+ i 1))]]

;; ---- report
;; -----------------------------------------------------------------------

(printf "~%==== corpus report: ~a ====~%" root)
[let-values
 (((keys vals) (hashtable-entries stats)))
 [let
  [[entries
    [sort
     (lambda (a b) (> (cdr a) (cdr b)))
     (map cons (vector->list keys) (vector->list vals))]]
   (total (apply + (vector->list vals)))]
  (for-each (lambda (e) (printf "~8d  ~a~%" (cdr e) (car e))) entries)
  [let
   ((pass (hashtable-ref stats "PASS" 0)))
   [printf
    "~%total ~a; PASS ~a (~,1f% of all, ~,1f% of parseable)~%"
    total
    pass
    (* 100.0 (/ pass (max 1 total)))
    [*
     100.0
     [/
      pass
      [max
       1
       [-
        total
        (hashtable-ref stats "parse-fail (LLVM rejects the file)" 0)
        (hashtable-ref stats "skipped (> 2MB)" 0)
        (hashtable-ref stats "unreadable file" 0)]]]]]]]]

[begin
 (unless (file-directory? "tests/tmp") (mkdir "tests/tmp"))
 [call-with-output-file
  "tests/tmp/corpus-failures.txt"
  [lambda
   (p)
   [for-each
    [lambda
     (f)
     (put-string p (car f))
     (put-string p "  ")
     (put-string p (cdr f))
     (put-char p #\newline)]
    failures]]
  'replace]
 [printf
  "~a failure paths written to tests/tmp/corpus-failures.txt~%"
  (length failures)]
 [call-with-output-file
  "tests/tmp/corpus-buckets.txt"
  [lambda
   (p)
   [for-each
    [lambda
     (e)
     (put-string p (car e))
     (put-string p "  ")
     (put-string p (cdr e))
     (put-char p #\newline)]
    (reverse bucketed)]]
  'replace]
 [when
  (> bench-n 0)
  (printf "~%construction bench over ~a PASS files (one shot each):~%" bench-n)
  [printf
   "  build ~,1fs   render ~,1fs   parse ~,1fs   (render+parse)/build = ~,2fx~%"
   (/ build-ns 1e9)
   (/ render-ns 1e9)
   (/ parse-ns 1e9)
   (/ (+ render-ns parse-ns) (max build-ns 1))]
  [unless
   (null? bench-failed)
   (printf "  RENDER-FAIL on ~a PASS files:~%" (length bench-failed))
   (for-each (lambda (f) (printf "    ~a~%" f)) bench-failed)]]]

;; A report containing unexplained mismatches is a failed gate, even when every
;; input file was readable. Always overwrite the ledgers above so an empty
;; successful run cannot leave a previous failure list behind.
[exit
 [if
  [and
   (null? failures)
   (null? bench-failed)
   (zero? (hashtable-ref stats "unreadable file" 0))]
  0
  1]]
