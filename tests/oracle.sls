;;; (tests oracle) -- extract enums from the installed LLVM C headers.
;;; The headers are the machine-readable ground truth the coverage tests
;;; check against (see project/coverage-plan.md). Import as: (prefix ... o:)
(library (tests oracle)
  (export enum-alist)
  (import (chezscheme) (prefix (llvm config) config:))

  (define (read-file path)
    (call-with-input-file path get-string-all))

  (define (str-index s sub start)   ; index of sub in s at/after start, or #f
    (let ([n (string-length s)] [m (string-length sub)])
      (let loop ([i start])
        (cond
          [(> (+ i m) n) #f]
          [(string=? (substring s i (+ i m)) sub) i]
          [else (loop (+ i 1))]))))

  (define (last-index-before s sub limit)  ; last occurrence strictly before limit
    (let loop ([i 0] [found #f])
      (let ([j (str-index s sub i)])
        (if (or (not j) (>= j limit))
            found
            (loop (+ j 1) j)))))

  ;; remove /* ... */ and // ... comments
  (define (strip-comments s)
    (let ([n (string-length s)] [out (open-output-string)])
      (let loop ([i 0])
        (cond
          [(>= i n) (get-output-string out)]
          [(and (< (+ i 1) n) (char=? (string-ref s i) #\/)
                (char=? (string-ref s (+ i 1)) #\*))
           (let ([end (str-index s "*/" (+ i 2))])
             (loop (if end (+ end 2) n)))]
          [(and (< (+ i 1) n) (char=? (string-ref s i) #\/)
                (char=? (string-ref s (+ i 1)) #\/))
           (let ([end (str-index s "\n" (+ i 2))])
             (loop (if end (+ end 1) n)))]
          [else (put-char out (string-ref s i)) (loop (+ i 1))]))))

  (define (trim s)
    (let ([n (string-length s)])
      (let ([a (let loop ([i 0])
                 (if (and (< i n) (char-whitespace? (string-ref s i)))
                     (loop (+ i 1)) i))]
            [b (let loop ([i n])
                 (if (and (> i 0) (char-whitespace? (string-ref s (- i 1))))
                     (loop (- i 1)) i))])
        (if (< a b) (substring s a b) ""))))

  (define (split-char s ch)
    (let ([n (string-length s)])
      (let loop ([i 0] [start 0] [acc '()])
        (cond
          [(= i n) (reverse (cons (substring s start n) acc))]
          [(char=? (string-ref s i) ch)
           (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
          [else (loop (+ i 1) start acc)]))))

  ;; C enum semantics: explicit `= N` sets the counter, otherwise prev+1.
  (define (parse-entries body)
    (let loop ([items (split-char body #\,)] [prev -1] [acc '()])
      (if (null? items)
          (reverse acc)
          (let ([item (trim (car items))])
            (if (string=? item "")
                (loop (cdr items) prev acc)
                (let* ([parts (split-char item #\=)]
                       [name (trim (car parts))]
                       [val (if (null? (cdr parts))
                                (+ prev 1)
                                (let ([v (string->number (trim (cadr parts)))])
                                  (unless v
                                    (error 'enum-alist "unparsable enum value" item))
                                  v))])
                  (loop (cdr items) val
                        (cons (cons (string->symbol name) val) acc))))))))

  ;; ((entry-name . value) ...) for `typedef enum { ... } <enum-name>;`
  ;; in the given installed llvm-c header.
  (define (enum-alist header enum-name)
    (let* ([text (read-file (string-append config:header-directory "/" header))]
           [end (or (str-index text (string-append "} " enum-name ";") 0)
                    (error 'enum-alist "enum not found in header" enum-name header))]
           [start (or (last-index-before text "typedef enum" end)
                      (error 'enum-alist "no typedef enum before terminator" enum-name))]
           [open (or (str-index text "{" start)
                     (error 'enum-alist "malformed enum" enum-name))])
      (parse-entries (strip-comments (substring text (+ open 1) end))))))
