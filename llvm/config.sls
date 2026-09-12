;;; Select one qualified LLVM installation per process, before importing raw. C
;;; API capabilities live here; Woof owns its GC and machine protocols.
[library
 (llvm config)
 [export
  major-version
  shared-object-suffix
  installed-releases
  installation-directory
  shared-object
  header-directory
  load!
  version
  validate-headers!
  capability?
  require-capability!]
 (import (chezscheme) (prefix (llvm selection) selection:))

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
 ;; Silicon and on Intel Macs, and MacPorts. The first that exists counts.
 [define
  (conventional-directory major)
  [find
   file-directory?
   [list
    (format "/usr/lib/llvm-~a" major)
    (format "/usr/local/llvm~a" major)
    (format "/opt/homebrew/opt/llvm@~a" major)
    (format "/usr/local/opt/llvm@~a" major)
    (format "/opt/local/libexec/llvm-~a" major)]]]
 [define
  (versioned-name major)
  (format "libLLVM-~a.~a" major shared-object-suffix)]
 (define generic-name (string-append "libLLVM." shared-object-suffix))

 ;; Is release MAJOR installed where this process would load it from? Under a
 ;; selected prefix only the versioned library name identifies a release; an
 ;; exact shared-object cannot be probed at all (its major must be explicit);
 ;; otherwise a conventional directory holding the library.
 [define
  (installed-on-host? major)
  [let
   [(prefix (selection:setting 'prefix))
    (so (selection:setting 'shared-object))]
   [cond
    (so #f)
    [prefix
     (file-exists? (string-append prefix "/lib/" (versioned-name major)))]
    [else
     [let
      ((dir (conventional-directory major)))
      [and
       dir
       [or
        (file-exists? (string-append dir "/lib/" (versioned-name major)))
        (file-exists? (string-append dir "/lib/" generic-name))]]]]]]]

 ;; the qualified releases this process could load, in qualified order
 [define
  (installed-releases)
  (filter installed-on-host? selection:qualified-majors)]

 ;; The release: explicit, or resolved from the requirements and what is
 ;; installed (see (llvm selection)); this seals the selection.
 [define
  major-version
  [begin
   [when
    [and
     (selection:setting 'shared-object)
     (not (selection:setting 'major-version))]
    [error
     'llvm-config
     "an exact shared-object selection needs an explicit major-version"]]
   (selection:resolve! installed-on-host?)]]

 [define
  installation-directory
  [or
   (selection:setting 'prefix)
   [and
    (not (selection:setting 'shared-object))
    (conventional-directory major-version)]]]
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
        (equal? actual (assv major-version selection:qualified-versions))
        [error
         'llvm-config
         "unqualified LLVM release or mismatched installation"
         actual
         (assv major-version selection:qualified-versions)
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

 ;; Named C API / IR capabilities of the selected release; the table lives in
 ;; (llvm selection) so requirements can be resolved before loading.
 (define (capability? name) (selection:capability-of major-version name))
 [define
  (require-capability! name)
  [unless
   (capability? name)
   [error
    'llvm-config
    "feature unavailable in selected LLVM version"
    name
    major-version]]]]
