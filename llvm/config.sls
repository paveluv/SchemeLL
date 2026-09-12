;;; Select one qualified LLVM installation per process, before importing raw. C
;;; API capabilities live here; Woof owns its GC and machine protocols.
[library
 (llvm config)
 [export
  major-version
  shared-object-suffix
  installation-directory
  shared-object
  header-directory
  load!
  version
  validate-headers!
  capability?
  require-capability!]
 (import (chezscheme) (prefix (llvm selection) selection:))

 [define
  qualified-versions
  '[(16 0 6)
    (19 1 7)
    (20 1 8)]]
 (define major-version (selection:setting 'major-version))

 ;; The host's shared-library suffix, from Chez's machine type: ...osx is macOS
 ;; (dylib), ...nt is Windows (dll), everything else is ELF (so).
 [define
  shared-object-suffix
  [let*
   [(name (symbol->string (machine-type)))
    (n (string-length name))
    [ends-with?
     [lambda
      (tail)
      [let
       ((m (string-length tail)))
       (and (>= n m) (string=? tail (substring name (- n m) n)))]]]]
   (cond ((ends-with? "osx") "dylib") ((ends-with? "nt") "dll") (else "so"))]]

 ;; Conventional installation directories for a major release: Debian/Ubuntu
 ;; packages, a manual /usr/local build, Homebrew's keg-only llvm@N on Apple
 ;; Silicon and on Intel Macs, and MacPorts. Only directories that exist count.
 [define
  installation-directory
  [or
   (selection:setting 'prefix)
   [and
    (not (selection:setting 'shared-object))
    [let
     loop
     [[paths
       [list
        (format "/usr/lib/llvm-~a" major-version)
        (format "/usr/local/llvm~a" major-version)
        (format "/opt/homebrew/opt/llvm@~a" major-version)
        (format "/usr/local/opt/llvm@~a" major-version)
        (format "/opt/local/libexec/llvm-~a" major-version)]]]
     [cond
      ((null? paths) #f)
      ((file-directory? (car paths)) (car paths))
      (else (loop (cdr paths)))]]]]]
 [define
  shared-object
  [or
   (selection:setting 'shared-object)
   [let
    ((name (format "libLLVM-~a.~a" major-version shared-object-suffix)))
    [if
     installation-directory
     [let*
      [(versioned (string-append installation-directory "/lib/" name))
       [generic
        [string-append
         installation-directory
         "/lib/libLLVM."
         shared-object-suffix]]]
      [if
       (or (file-exists? versioned) (not (file-exists? generic)))
       versioned
       generic]]
     name]]]]
 [define
  header-directory
  [or
   (selection:setting 'header-directory)
   [if
    installation-directory
    (string-append installation-directory "/include/llvm-c")
    (format "/usr/include/llvm-c-~a/llvm-c" major-version)]]]

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
     [or
      (selection:setting 'version-header)
      [if
       installation-directory
       [string-append
        installation-directory
        "/include/llvm/Config/llvm-config.h"]
       [format
        "/usr/include/llvm-~a/llvm/Config/llvm-config.h"
        major-version]]]]
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

 ;; Named C API / IR capabilities of the selected release. Each names the
 ;; release that introduced (or removed) the feature; the raw bindings, the IR
 ;; layer and unbuild consult these instead of version numbers, and
 ;; tests/test-version.ss checks that every optional C entry is present exactly
 ;; when its capability says so.
 [define
  (capability? name)
  [case
   name
   ;; LLVM 16: typed pointers still exist (LLVMContextSetOpaquePointers); needed
   ;; to write bitcode for readers that predate opaque pointers
   ((typed-pointers) (= major-version 16))
   ;; LLVM 17 C API: 64-bit array lengths (LLVMArrayType2, LLVMConstArray2,
   ;; LLVMGetArrayLength2), target extension inspection and atomicrmw
   ;; uinc_wrap/udec_wrap (the IR operations already exist in 16).
   ((array-length-64) (>= major-version 17))
   ((target-ext-types) (>= major-version 17))
   ((atomic-uinc-wrap) (>= major-version 17))
   ((value-as-metadata-inspection) (>= major-version 17))
   ;; LLVM 18: flag accessors (nsw/nuw/exact/nneg/disjoint and fast-math
   ;; get/set), tail-call kinds beyond `tail`, operand bundles, inline-asm and
   ;; prefix/prologue inspection, size_t string constants
   ((flag-accessors) (>= major-version 18))
   ((tail-call-kinds) (>= major-version 18))
   ((operand-bundles) (>= major-version 18))
   ((inline-asm-inspection) (>= major-version 18))
   ((prefix-data-inspection) (>= major-version 18))
   ((sized-string-constants) (>= major-version 18))
   ;; LLVM 18 overloaded llvm.va_start/va_end/va_copy on the pointer type
   ;; (llvm.va_start.p0); earlier releases know only the plain names
   ((overloaded-va-intrinsics) (>= major-version 18))
   ;; LLVM 19: callbr, getelementptr nusw/nuw, blockaddress inspection;
   ;; LLVMGetOrdering reads fences correctly (16 misreads them, probed)
   ((callbr) (>= major-version 19))
   ((fence-ordering-accessor) (>= major-version 19))
   ((gep-no-wrap-flags) (>= major-version 19))
   ((blockaddress-inspection) (>= major-version 19))
   ;; LLVM 20 removed MMX and added usub_cond/usub_sat, the JIT layout bridge
   ;; and the samesign text detection
   ((x86-mmx) (<= major-version 19))
   ((atomic-usub) (>= major-version 20))
   ((jit-layout-bridge) (>= major-version 20))
   ((icmp-samesign-text) (>= major-version 20))
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
