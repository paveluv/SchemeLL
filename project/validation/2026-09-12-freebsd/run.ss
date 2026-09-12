#!chezscheme
(import (chezscheme))
(current-directory (string-append (getenv "HOME") "/git/SchemeLL"))
(define root "/tmp/schemell-freebsd-validation-20260912")
(unless (file-exists? root) (mkdir root))
[define
 (q s)
 [string-append
  "'"
  [apply
   string-append
   (map (lambda (c) (if (char=? c #\') "'\\''" (string c))) (string->list s))]
  "'"]]
[define
 (run name command)
 (printf "Running ~a\n" name)
 (flush-output-port)
 [let
  [[status
    [system
     [format
      "env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C ~a > ~a 2>&1"
      command
      (q (string-append root "/" name))]]]]
  (printf "~a: exit ~a\n" name status)
  (flush-output-port)
  [unless
   (zero? status)
   (display (call-with-input-file (string-append root "/" name) get-string-all))
   (exit 1)]]]
[define
 (copy from to)
 [call-with-port
  (open-file-input-port from)
  [lambda
   (in)
   [call-with-port
    (open-file-output-port to (file-options no-fail))
    [lambda
     (out)
     [let
      ((bytes (get-bytevector-all in)))
      (unless (eof-object? bytes) (put-bytevector out bytes))]]]]]]
[define
 (backup-object path)
 [let
  [[backup
    [string-append
     root
     "/"
     [list->string
      (map (lambda (c) (if (char=? c #\/) #\_ c)) (string->list path))]]]]
  (unless (file-exists? backup) (copy path backup))
  (delete-file path)]]
[define
 (walk dir)
 [for-each
  [lambda
   (name)
   [let
    ((path (string-append dir "/" name)))
    [cond
     ((file-directory? path) (unless (string=? path "tests/tmp") (walk path)))
     [[and
       (member (path-extension path) '("so" "wpo"))
       (file-exists? (string-append (path-root path) ".sls"))]
      (backup-object path)]]]]
  (directory-list dir)]]
[define
 (run-examples)
 [for-each
  [lambda
   (major)
   [run
    (format "examples-llvm~a.log" major)
    (format "SCHEMELL_LLVM_VERSION=~a make examples" major)]]
  '(16 19 20)]]
[define
 (finish-matrix)
 (run-examples)
 [for-each
  [lambda
   (major)
   [run
    (format "test-compiled-llvm~a.log" major)
    (format "SCHEMELL_LLVM_VERSION=~a make test" major)]]
  '(16 19 20)]
 (run "version-cache.log" "make test-version-cache")
 (run "check-format.log" "make check-format")]
[define
 (retain-corpus)
 [for-each
  [lambda
   (name)
   [copy
    (format "tests/tmp/corpus-~a.txt" name)
    (format "~a/corpus16-final-~a.txt" root name)]]
  '("failures" "buckets")]]
[case
 (string->symbol (car (command-line-arguments)))
 [(matrix)
  (for-each walk '("llvm" "sll" "tests"))
  (when (file-exists? "sll.so") (backup-object "sll.so"))
  (run "revision.txt" "git log -1 --format=full")
  (run "kernel.txt" "uname -a")
  (run "os-version.txt" "freebsd-version -ku")
  (run "cpu.txt" "sysctl hw.model hw.ncpu hw.physmem")
  (run "packages.txt" "pkg info -x '^(chez|llvm|gmake|git)' ")
  (run "make-version.txt" "make -V MAKE_VERSION")
  [for-each
   [lambda
    (major)
    [run
     (format "llvm~a.sexp" major)
     [format
      "chez-scheme --libdirs . --script project/validation/2026-09-12-linux/facts.ss ~a"
      major]]
    [run
     (format "test-source-llvm~a.log" major)
     (format "SCHEMELL_LLVM_VERSION=~a make test" major)]]
   '(16 19 20)]
  (finish-matrix)]
 ((remaining) (finish-matrix))
 ((examples) (run-examples))
 [(review)
  [for-each
   [lambda
    (major)
    [run
     (format "review-llvm~a.log" major)
     [format
      "SCHEMELL_LLVM_VERSION=~a chez-scheme --libdirs . --script project/validation/2026-09-12-linux-llvm16/review.ss"
      major]]
    [run
     (format "integration-llvm~a.log" major)
     [format
      "SCHEMELL_LLVM_VERSION=~a chez-scheme --libdirs . --script project/validation/2026-09-12-linux-llvm16/rebase-integration.ss"
      major]]]
   '(16 19 20)]]
 [(corpus)
  [run
   "corpus16-final.log"
   "SCHEMELL_LLVM_VERSION=16 make corpus CORPUS_DIR=reference/llvm16/llvm/test"]
  (retain-corpus)]
 ((retain-corpus) (retain-corpus))
 (else (error 'freebsd-validation "unknown stage"))]
