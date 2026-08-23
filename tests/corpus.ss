;;; Corpus round-trip harness (coverage plan, level 3).
;;;
;;;   scheme --libdirs . --script tests/corpus.ss [directory]
;;;
;;; For every .ll file under the directory (default: LLVM's own regression
;;; corpus in reference/llvm-project/llvm/test):
;;;
;;;   parse -> normalize (strip what ll does not model, (tests normalize))
;;;         -> A := canonical print
;;;         -> ll:unbuild -> ll:build -> B := canonical print
;;;   PASS iff A == B.
;;;
;;; Buckets: PASS; parse-fail (LLVM's own parser rejects -- many corpus
;;; files are intentionally invalid or fragments); not modeled: <construct>
;;; (ll:unbuild's strict errors classify the file); MISMATCH and build-fail
;;; (bugs in our layer -- the burn-down list). Sorted counts at the end;
;;; mismatch/build-fail paths are written to tests/tmp/corpus-failures.txt.
(import (chezscheme)
        (prefix (llvm ir) ir:)
        (prefix (llscheme ll) ll:)
        (prefix (tests normalize) n:))

(define root
  (let ([args (cdr (command-line))])
    (if (pair? args) (car args) "reference/llvm-project/llvm/test")))

;; ---- file walk -----------------------------------------------------------

(define (ll-file? name)
  (let ([n (string-length name)])
    (and (> n 3) (string=? (substring name (- n 3) n) ".ll"))))

(define (find-ll-files dir)
  (let loop ([dirs (list dir)] [acc '()])
    (if (null? dirs)
        acc
        (let ([d (car dirs)])
          (let inner ([entries (guard (e [#t '()]) (directory-list d))]
                      [dirs (cdr dirs)] [acc acc])
            (if (null? entries)
                (loop dirs acc)
                (let ([p (string-append d "/" (car entries))])
                  (cond
                    [(file-directory? p) (inner (cdr entries) (cons p dirs) acc)]
                    [(ll-file? p) (inner (cdr entries) dirs (cons p acc))]
                    [else (inner (cdr entries) dirs acc)]))))))))

;; ---- classification ---------------------------------------------------------

(define stats (make-hashtable string-hash string=?))
(define failures '())   ; (path . bucket) for MISMATCH / build-fail

(define (bucket! key)
  (hashtable-update! stats key (lambda (n) (+ n 1)) 0))

(define (starts-with? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

(define (after-marker s marker)
  (let ([n (string-length s)] [m (string-length marker)])
    (let loop ([i 0])
      (cond
        [(> (+ i m) n) #f]
        [(string=? (substring s i (+ i m)) marker)
         (substring s (+ i m) n)]
        [else (loop (+ i 1))]))))

(define (classify e)
  (let ([who (and (who-condition? e) (condition-who e))]
        [msg (if (message-condition? e) (condition-message e) "?")])
    (cond
      [(eq? who 'ir:parse-ir) "parse-fail (LLVM rejects the file)"]
      [(after-marker msg "not-modeled.md): ") =>
       (lambda (what) (string-append "not modeled: " what))]
      [(eq? who 'll:build)
       (string-append "BUG build-fail: " msg)]
      [else (string-append "BUG error: " msg)])))

;; ---- the round trip -----------------------------------------------------------

(define (process path)
  (let ([text (guard (e [#t #f])
                (call-with-input-file path get-string-all))])
    (cond
      [(not text) (bucket! "unreadable file")]
      [(> (string-length text) 2000000) (bucket! "skipped (> 2MB)")]
      [else
       ;; separate contexts: named struct types are context-registered,
       ;; so rebuilding in the parse context would collide
       (let ([ctx (ir:make-context)] [rctx (ir:make-context)] [m #f] [m2 #f])
         (guard (e [#t (let ([b (classify e)])
                         (bucket! b)
                         (when (starts-with? b "BUG")
                           (set! failures (cons (cons path b) failures))))])
           (set! m (ir:parse-ir ctx path text))
           (n:normalize-module! m)
           (let ([a (n:comparable-ir (ir:module->string m))])
             (let ([prog (ll:unbuild m 'ignore-named-metadata)])
               (set! m2 (ll:build rctx "corpus" prog))
               ;; normalize the rebuild too: LLVM auto-attaches intrinsic
               ;; attributes to declarations it recognizes
               (n:normalize-module! m2)
               (let ([b (n:comparable-ir (ir:module->string m2))])
                 (if (string=? a b)
                     (bucket! "PASS")
                     (begin
                       (bucket! "MISMATCH (bug)")
                       (set! failures
                         (cons (cons path "MISMATCH") failures))))))))
         (when m2 (guard (e [#t #f]) (ir:module-dispose! m2)))
         (when m (guard (e [#t #f]) (ir:module-dispose! m)))
         (ir:context-dispose! ctx)
         (ir:context-dispose! rctx))])))

;; ---- run --------------------------------------------------------------------------

(printf "collecting .ll files under ~a ...~%" root)
(define files (find-ll-files root))
(printf "~a files~%" (length files))

(let loop ([fs files] [i 0])
  (unless (null? fs)
    (when (and (positive? i) (zero? (mod i 2000)))
      (printf "  ... ~a files processed~%" i)
      (flush-output-port (current-output-port)))
    (process (car fs))
    (loop (cdr fs) (+ i 1))))

;; ---- report -----------------------------------------------------------------------

(printf "~%==== corpus report: ~a ====~%" root)
(let-values ([(keys vals) (hashtable-entries stats)])
  (let ([entries (sort (lambda (a b) (> (cdr a) (cdr b)))
                       (map cons (vector->list keys) (vector->list vals)))]
        [total (apply + (vector->list vals))])
    (for-each
      (lambda (e) (printf "~8d  ~a~%" (cdr e) (car e)))
      entries)
    (let ([pass (hashtable-ref stats "PASS" 0)])
      (printf "~%total ~a; PASS ~a (~,1f% of all, ~,1f% of parseable)~%"
              total pass
              (* 100.0 (/ pass (max 1 total)))
              (* 100.0 (/ pass (max 1 (- total
                                         (hashtable-ref stats "parse-fail (LLVM rejects the file)" 0)
                                         (hashtable-ref stats "skipped (> 2MB)" 0)
                                         (hashtable-ref stats "unreadable file" 0)))))))))

(unless (null? failures)
  (unless (file-directory? "tests/tmp") (mkdir "tests/tmp"))
  (call-with-output-file "tests/tmp/corpus-failures.txt"
    (lambda (p)
      (for-each (lambda (f) (put-string p (car f)) (put-string p "  ")
                  (put-string p (cdr f)) (put-char p #\newline))
                failures))
    'replace)
  (printf "~a failure paths written to tests/tmp/corpus-failures.txt~%"
          (length failures)))
