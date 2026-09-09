;;; Compare module-construction paths for the same sll program:
;;;   A: sll:build            (C-API IRBuilder, folding)
;;;   B: render + parse      (pure-Scheme text + LLVMParseIRInContext)
;;; Usage: scheme --libdirs . --script tests/bench-build.ss FILE.ll ...
[import
 (chezscheme)
 (prefix (llvm ir) ir:)
 (prefix (sll) sll:)
 (prefix (sll render) render:)
 (prefix (tests normalize) n:)]

(define iterations 20)

[define
 (time-ms thunk)
 [let
  ((t0 (real-time)))
  (do ((i 0 (+ i 1))) ((= i iterations)) (thunk))
  (/ (- (real-time) t0) 1.0 iterations)]]

[define
 (bench path)
 [guard
  [e
   [#t
    [printf
     "~a: skipped (~a)~%"
     path
     (if (message-condition? e) (condition-message e) e)]]]
  [let*
   [(text (call-with-input-file path get-string-all))
    (ctx (ir:make-context))
    (m (let ((m (ir:parse-ir ctx path text))) (n:normalize-module! m) m))
    (prog (sll:unbuild m 'ignore-named-metadata 'tolerate-builder-folds))
    (rendered (render:sll->ll prog))
    [insns
     [let
      count
      ((items prog) (n 0))
      [if
       (null? items)
       n
       [count
        (cdr items)
        [+
         n
         [if
          (eq? (car (car items)) 'define)
          [fold-left
           [lambda
            (a b)
            (if (and (pair? b) (eq? (car b) 'label)) (+ a (length (cddr b))) a)]
           0
           (cdr (car items))]
          0]]]]]]]
   ;; warm-up both paths once
   [let
    ((c (ir:make-context)))
    (ir:module-dispose! (sll:build c "w" prog))
    (ir:module-dispose! (ir:parse-ir c "w" rendered))
    (ir:context-dispose! c)]
   [let
    [[t-build
      [time-ms
       [lambda
        ()
        [let
         ((c (ir:make-context)))
         (ir:module-dispose! (sll:build c "b" prog))
         (ir:context-dispose! c)]]]]
     (t-render (time-ms (lambda () (render:sll->ll prog))))
     [t-parse
      [time-ms
       [lambda
        ()
        [let
         ((c (ir:make-context)))
         (ir:module-dispose! (ir:parse-ir c "p" rendered))
         (ir:context-dispose! c)]]]]]
    [printf
     "~a~%  ~s instructions, ~s chars of IR~%"
     path
     insns
     (string-length rendered)]
    (printf "  build:          ~,2f ms~%" t-build)
    (printf "  render:         ~,2f ms~%" t-render)
    (printf "  parse:          ~,2f ms~%" t-parse)
    [printf
     "  render+parse:   ~,2f ms  (~,2fx of build)~%"
     (+ t-render t-parse)
     (/ (+ t-render t-parse) (max t-build 0.01))]]
   (ir:module-dispose! m)
   (ir:context-dispose! ctx)]]]

(for-each bench (cdr (command-line)))
