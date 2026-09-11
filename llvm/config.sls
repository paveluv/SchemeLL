;;; Select one qualified LLVM installation per process, before importing raw. C
;;; API capabilities live here; Woof owns its GC and machine protocols.
[library
 (llvm config)
 [export
  major-version
  installation-directory
  shared-object
  header-directory
  load!
  version
  validate-headers!
  capability?
  require-capability!]
 (import (chezscheme))

 [define
  qualified-versions
  '[(19 1 7)
    (20 1 8)]]
 [define
  major-version
  [let
   ((choice (or (getenv "SCHEMELL_LLVM_VERSION") "19")))
   [cond
    ((string=? choice "19") 19)
    ((string=? choice "20") 20)
    [else
     [error
      'llvm-config
      "unsupported SCHEMELL_LLVM_VERSION; expected 19 or 20"
      choice]]]]]

 [define
  installation-directory
  [or
   (getenv "SCHEMELL_LLVM_PREFIX")
   [let
    loop
    [[paths
      [list
       (format "/usr/lib/llvm-~a" major-version)
       (format "/usr/local/llvm~a" major-version)]]]
    [cond
     ((null? paths) #f)
     ((file-directory? (car paths)) (car paths))
     (else (loop (cdr paths)))]]]]
 [define
  shared-object
  [let
   ((name (format "libLLVM-~a.so" major-version)))
   [if
    installation-directory
    [let*
     [(versioned (string-append installation-directory "/lib/" name))
      (generic (string-append installation-directory "/lib/libLLVM.so"))]
     [if
      (or (file-exists? versioned) (not (file-exists? generic)))
      versioned
      generic]]
    name]]]
 [define
  header-directory
  [if
   installation-directory
   (string-append installation-directory "/include/llvm-c")
   (format "/usr/include/llvm-c-~a/llvm-c" major-version)]]

 (define loaded-version #f)
 (define load-failed? #f)
 [define
  (load!)
  [unless
   loaded-version
   [when
    load-failed?
    (error 'llvm-config "previous LLVM load failed; start a fresh process")]
   ;; Chez resolves C entries process-wide. Even a matching preloaded library
   ;; would make the requested prefix ambiguous. Refuse before loading another.
   [when
    (foreign-entry? "LLVMGetVersion")
    [error
     'llvm-config
     "LLVM was already loaded outside SchemeLL; use a fresh process"]]
   (set! load-failed? #t)
   (load-shared-object shared-object)
   [let
    ((out (foreign-alloc 12)))
    [dynamic-wind
     (lambda () (void))
     [lambda
      ()
      [(foreign-procedure "LLVMGetVersion" (void* void* void*) void)
       out
       (+ out 4)
       (+ out 8)]
      [let
       [[actual
         [map
          (lambda (offset) (foreign-ref 'unsigned-32 out offset))
          '(0 4 8)]]]
       [unless
        (equal? actual (assv major-version qualified-versions))
        [error
         'llvm-config
         "unqualified LLVM release or mismatched installation"
         actual
         (assv major-version qualified-versions)
         shared-object]]
       (set! loaded-version actual)
       (set! load-failed? #f)]]
     (lambda () (foreign-free out))]]]
  (void)]
 (define (version) (load!) (list-copy loaded-version))

 ;; Headers are needed by the coverage oracle, not by deployed JIT clients.
 ;; Validate the exact version before using them as an oracle.
 [define
  (validate-headers!)
  [let*
   [[path
     [if
      installation-directory
      [string-append
       installation-directory
       "/include/llvm/Config/llvm-config.h"]
      (format "/usr/include/llvm-~a/llvm/Config/llvm-config.h" major-version)]]
    (keys '(LLVM_VERSION_MAJOR LLVM_VERSION_MINOR LLVM_VERSION_PATCH))
    [defines
     [call-with-input-file
      path
      [lambda
       (p)
       [let
        loop
        ((entries '()))
        [let
         ((line (get-line p)))
         [if
          (eof-object? line)
          entries
          [let
           ((words (open-string-input-port line)))
           [if
            [and
             (>= (string-length line) 8)
             (string=? (substring line 0 8) "#define ")]
            [begin
             (get-string-n words 8)
             [let
              ((key (read words)))
              [loop
               [if
                (memq key keys)
                (cons (cons key (read words)) entries)
                entries]]]]
            (loop entries)]]]]]]]]]
   [let
    [[actual
      (map (lambda (key) (let ((p (assq key defines))) (and p (cdr p)))) keys)]]
    [unless
     (equal? actual (version))
     [error
      'llvm-config
      "LLVM headers do not match the loaded library"
      path
      actual
      (version)]]
    [unless
     (file-exists? (string-append header-directory "/Core.h"))
     (error 'llvm-config "missing LLVM C headers" header-directory)]
    actual]]]

 [define
  (capability? name)
  [case
   name
   ((x86-mmx) (= major-version 19))
   ((atomic-usub) (= major-version 20))
   ((jit-layout-bridge) (= major-version 20))
   ((icmp-samesign-text) (= major-version 20))
   (else #f)]]
 [define
  (require-capability! name)
  [unless
   (capability? name)
   [error
    'llvm-config
    "feature unavailable in selected LLVM version"
    name
    major-version]]]]
