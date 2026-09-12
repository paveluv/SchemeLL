;;; Pure installation selection: which qualified LLVM release this process uses,
;;; chosen before the bindings load. No getenv, no filesystem, no FFI.
;;;
;;; Three ways to arrive at a release, in order of precedence:
;;;   - select! with an explicit major-version pins one;
;;;   - require! names capabilities the program needs (typed-pointers, ...),
;;;     and the release is the first installed one, in preference order, that
;;;     has them all; prefer! names capabilities that only reorder the
;;;     candidates (releases having them first) without excluding any;
;;;   - nothing: the first installed release in preference order.
;;; Installation is the one fact this library cannot know; (llvm config)
;;; supplies it to resolve! as a predicate when it loads. Once a consumer has
;;; read a setting the selection is sealed for the process.
[library
 (llvm selection)
 [export
  qualified-versions
  qualified-majors
  preference
  capability-names
  capability-of
  make-selection
  selection?
  selection-ref
  select!
  selected?
  sealed?
  require!
  requirements
  prefer!
  preferences
  candidates
  resolve!
  setting]
 (import (chezscheme))

 ;; the qualified releases and the order in which an unpinned process prefers
 ;; them: 19 is the primary release, 20 next, 16 last (it exists for
 ;; typed-pointer bitcode)
 [define
  qualified-versions
  '[(16 0 6)
    (19 1 7)
    (20 1 8)]]
 (define qualified-majors (map car qualified-versions))
 (define preference '(19 20 16))

 ;; Named C API / IR capabilities per release. Each names the release that
 ;; introduced (or removed) the feature; the raw bindings, the IR layer, unbuild
 ;; and the tests consult these instead of version numbers, and
 ;; tests/test-version.ss checks that every optional C entry is present exactly
 ;; when its capability says so. Documented in project/llvm-versions.md.
 [define
  capability-table
  ;; (name . first-major) or (name . (from . to))
  '[(typed-pointers . (16 . 16))    ; LLVMContextSetOpaquePointers, removed in
                                    ; 17
    (array-length-64 . 17)      ; LLVMArrayType2 and friends
    (target-ext-types . 17)
    (atomic-uinc-wrap . 17)     ; atomicrmw uinc_wrap/udec_wrap
    (value-as-metadata-inspection . 17)
    (flag-accessors . 18)       ; nsw/nuw/exact/nneg/disjoint, fast-math
    (tail-call-kinds . 18)
    (operand-bundles . 18)
    (inline-asm-inspection . 18)
    (prefix-data-inspection . 18)
    (sized-string-constants . 18)
    (overloaded-va-intrinsics . 18) ; llvm.va_start.p0
    (callbr . 19)
    (gep-no-wrap-flags . 19)
    (blockaddress-inspection . 19)
    [fence-ordering-accessor
     .
     19]                        ; 16's LLVMGetOrdering misreads fences (probed)
    (x86-mmx . (16 . 19))       ; removed in 20
    (atomic-usub . 20)
    (jit-layout-bridge . 20)
    (icmp-samesign-text . 20)]]

 (define capability-names (map car capability-table))

 [define
  (capability-of major name)
  [let
   ((entry (assq name capability-table)))
   (unless entry (error 'capability-of "unknown LLVM capability" name))
   [let
    ((range (cdr entry)))
    (if (pair? range) (<= (car range) major (cdr range)) (>= major range))]]]

 (define (path? x) (or (not x) (and (string? x) (> (string-length x) 0))))
 [define
  schema
  [list
   ;; #f: resolve from requirements and what is installed
   [list
    'major-version
    #f
    (lambda (x) (or (not x) (and (memv x qualified-majors) #t)))]
   (list 'prefix #f path?)
   (list 'shared-object #f path?)
   (list 'header-directory #f path?)
   (list 'version-header #f path?)]]
 (define-record-type (selection %make-selection selection?) (fields entries))
 (define (copy-value x) (if (string? x) (string-copy x) x))
 [define
  (make-selection overrides)
  [unless
   (list? overrides)
   (error 'make-selection "expected an alist" overrides)]
  [let
   ((seen '()))
   [for-each
    [lambda
     (row)
     [unless
      (and (pair? row) (assq (car row) schema))
      (error 'make-selection "unknown LLVM selection key" row)]
     [when
      (memq (car row) seen)
      (error 'make-selection "duplicate LLVM selection key" (car row))]
     (set! seen (cons (car row) seen))
     [unless
      ((caddr (assq (car row) schema)) (cdr row))
      (error 'make-selection "invalid LLVM selection value" row)]]
    overrides]]
  [%make-selection
   [map
    [lambda
     (entry)
     [let
      ((row (assq (car entry) overrides)))
      (cons (car entry) (copy-value (if row (cdr row) (cadr entry))))]]
    schema]]]
 [define
  (selection-ref profile key)
  [unless
   (selection? profile)
   (error 'selection-ref "expected selection" profile)]
  [let
   ((row (assq key (selection-entries profile))))
   (unless row (error 'selection-ref "unknown LLVM selection key" key))
   (copy-value (cdr row))]]

 (define selected-profile (make-selection '()))
 (define installed? #f)
 (define frozen? #f)
 (define required '())
 (define preferred '())
 (define (selected?) installed?)
 (define (sealed?) frozen?)
 (define (requirements) (list-copy required))
 (define (preferences) (list-copy preferred))

 [define
  (check-requirements! who major)
  [for-each
   [lambda
    (name)
    [unless
     (capability-of major name)
     [error
      who
      "the selected LLVM release lacks a required capability"
      major
      name]]]
   required]]

 [define
  (select! new)
  (unless (selection? new) (error 'select! "expected selection" new))
  [when
   [and
    frozen?
    (not (equal? (selection-entries selected-profile) (selection-entries new)))]
   [error
    'select!
    "LLVM selection is sealed; select before importing LLVM bindings"]]
  [let
   ((major (selection-ref new 'major-version)))
   (when major (check-requirements! 'select! major))]
  (set! selected-profile new)
  (set! installed? #t)]

 ;; Name capabilities the program needs; resolution then considers only releases
 ;; that have them all. After sealing, a requirement the selected release
 ;; already satisfies is accepted; any other is an error.
 [define
  (require! . names)
  [for-each
   [lambda
    (name)
    [unless
     (memq name capability-names)
     (error 'require! "unknown LLVM capability" name)]]
   names]
  [let
   ((major (selection-ref selected-profile 'major-version)))
   [when
    (and major (or frozen? installed?))
    [for-each
     [lambda
      (name)
      [unless
       (capability-of major name)
       [error
        'require!
        [if
         frozen?
         "LLVM selection is sealed at a release without this capability"
         "the selected LLVM release lacks this capability"]
        major
        name]]]
     names]]]
  [for-each
   [lambda
    (name)
    (unless (memq name required) (set! required (append required (list name))))]
   names]]

 ;; Name capabilities the program would rather have: candidates that have them
 ;; all come first, the rest stay candidates. Nothing to check against a sealed
 ;; release, since a preference excludes no release.
 [define
  (prefer! . names)
  [for-each
   [lambda
    (name)
    [unless
     (memq name capability-names)
     (error 'prefer! "unknown LLVM capability" name)]
    [unless
     (memq name preferred)
     (set! preferred (append preferred (list name)))]]
   names]]

 ;; the qualified majors that satisfy every requirement, in preference order,
 ;; those satisfying every preference first
 [define
  (candidates)
  [let*
   [[has-all?
     [lambda
      (names)
      [lambda
       (major)
       (for-all (lambda (name) (capability-of major name)) names)]]]
    (ok (filter (has-all? required) preference))]
   [append
    (filter (has-all? preferred) ok)
    (filter (lambda (m) (not ((has-all? preferred) m))) ok)]]]

 ;; Decide the release: the explicit major-version, checked against the
 ;; requirements, or else the first candidate for which installed-on-host?
 ;; holds. Records the result in the selection and seals it. (llvm config) calls
 ;; this when it loads, with its own installation probe.
 [define
  (resolve! installed-on-host?)
  [let
   ((explicit (selection-ref selected-profile 'major-version)))
   [let
    [[major
      [or
       explicit
       [let
        ((found (find installed-on-host? (candidates))))
        [unless
         found
         [error
          'llvm-selection
          "no qualified LLVM release satisfies the requirements on this host"
          `(requirements ,@required)
          `(candidates ,@(candidates))
          `(installed ,@(filter installed-on-host? qualified-majors))]]
        found]]]]
    (check-requirements! 'llvm-selection major)
    [unless
     explicit
     [set!
      selected-profile
      [%make-selection
       [map
        [lambda
         (row)
         (if (eq? (car row) 'major-version) (cons 'major-version major) row)]
        (selection-entries selected-profile)]]]]
    (set! installed? #t)
    (set! frozen? #t)
    major]]]

 [define
  (setting key)
  [let
   ((value (selection-ref selected-profile key)))
   (set! installed? #t)
   (set! frozen? #t)
   value]]]
