#lang racket/base

;; Provides functionality to take a static contract and turn it into a regular contract.

(require (for-template racket/base
                       racket/contract)
         racket/contract
         racket/list
         racket/match
         racket/syntax
         syntax/private/id-table
         "../utils/utils.rkt"
         "combinators.rkt"
         "combinators/case-lambda.rkt"
         "combinators/name.rkt"
         "combinators/parametric.rkt"
         "constraints.rkt"
         "equations.rkt"
         "kinds.rkt"
         "optimize.rkt"
         "parametric-check.rkt"
         "structures.rkt")

(provide static-contract-may-contain-free-ids?)

(provide/cond-contract
 [instantiate/optimize
     (parametric->/c (a) ((static-contract? (-> #:reason (or/c #f string?) a))
                          (contract-kind? #:cache (or/c #f hash?) #:trusted-positive boolean? #:trusted-negative boolean?)
                          . ->* . (or/c a (list/c (listof syntax?) syntax?))))]
 [instantiate
     (parametric->/c (a) ((static-contract? (-> #:reason (or/c #f string?) a))
                          (contract-kind? #:cache (or/c #f hash?) #:recursive-kinds (or/c hash? #f))
                          . ->* . (or/c a (list/c (listof syntax?) syntax?))))]
 [should-inline-contract? (-> syntax? boolean?)])

;; Providing these so that tests can work directly with them.
(module* internals #f
  (provide compute-constraints
           compute-recursive-kinds
           instantiate/inner))

(define no-optimize-sc? (and (getenv "PLT_TR_NO_CONTRACT_OPTIMIZE") #t))

(define (instantiate/optimize sc fail [kind 'impersonator] #:cache [cache #f] #:trusted-positive [trusted-positive #f] #:trusted-negative [trusted-negative #f])
  (define recursive-kinds
    (with-handlers [(exn:fail:constraint-failure?
                    (lambda (exn)
                      ;; Even if the constraints for `sc` are unsolvable,
                      ;;  the optimizer might be able to reduce parts of
                      ;;  `sc` to give a contract with solvable constraints.
                      ;; This currently happens for the `Any-Syntax` type;
                      ;;  eventually that won't happen for `Any-Syntax`,
                      ;;  and at that point maybe we can fail here. -- Ben G.
                      #f))]
      (compute-recursive-kinds
        (contract-restrict-recursive-values (compute-constraints sc kind)))))
  (define sc/opt (if no-optimize-sc? sc (optimize sc #:trusted-positive trusted-positive #:trusted-negative trusted-negative #:recursive-kinds recursive-kinds)))
  (instantiate sc/opt fail kind #:cache cache #:recursive-kinds recursive-kinds))

;; kind is the greatest kind of contract that is supported, if a greater kind would be produced the
;; fail procedure is called.
;;
;; The cache is used to share contract definitions across multiple calls to
;; type->contract in a given contract fixup pass. If it's #f then that means don't
;; do any sharing (useful for testing).
(define (instantiate sc fail [kind 'impersonator] #:cache [cache #f] #:recursive-kinds [recursive-kinds #f])
  (if (parametric-check sc)
      (fail #:reason "multiple parametric contracts are not supported")
      (with-handlers [(exn:fail:constraint-failure?
                        (lambda (exn) (fail #:reason (exn:fail:constraint-failure-reason exn))))]
        (instantiate/inner sc
          (or recursive-kinds
              (compute-recursive-kinds
                (contract-restrict-recursive-values (compute-constraints sc kind))))
          cache))))

;; computes the definitions that are in / used by `sc`
;; `(get-all-name-defs)` is not what we want directly, since it also includes
;; definitions that were optimized away
;; we restrict it to only variables bound in `sc`
(define (compute-defs sc)
  (define all-name-defs (get-all-name-defs))
  ;; all-name-defs maps lists of ids to defs
  ;; we want to match if any id in the list matches
  (define (ref b) (for/first ([k/v (in-list all-name-defs)]
                              #:when (for/or ([k* (in-list (car k/v))])
                                       (free-identifier=? b k*)))
                    k/v))
  (define bound '())
  ;; ignores its second argument (variance, passed by sc-traverse)
  (let loop ([sc sc] [_ #f])
    (match sc
      [(name/sc: name*)
       (unless (member name* bound free-identifier=?)
         (set! bound (cons name* bound))
         ;; traverse what `name` refers to
         (define r (ref name*))
         ;; ref returns a rib, get the one definition we want
         (define target (for/first ([k (in-list (car r))]
                                    [v (in-list (cdr r))]
                                    #:when (free-identifier=? name* k))
                          v))
         (loop target #f))]
      [else (sc-traverse sc loop)]))
  (for*/hash ([b (in-list bound)]
              [v (in-value (ref b))]
              #:when v)
    (values (car v) (cdr v))))

(define (compute-constraints sc max-kind)
  (define memo-table (make-hash))
  (define name-defs (compute-defs sc))
  (define (recur sc)
    (cond [(hash-ref memo-table sc #f)]
          [else
           (define result
             (match sc
               [(recursive-sc names values body)
                (close-loop names (map recur values) (recur body))]
               [(? sc?)
                (sc->constraints sc recur)]))
           (hash-set! memo-table sc result)
           result]))
  (define constraints
    (cond
      [(hash-empty? name-defs)
       (recur sc)]
      [else
       (define keys+values (hash->list name-defs))
       (close-loop (apply append (map car keys+values))
                   (map recur (apply append (map cdr keys+values)))
                   (recur sc))]))
  (validate-constraints (add-constraint constraints max-kind))
  constraints)


(define (compute-recursive-kinds recursives)
  (define eqs (make-equation-set))
  (define vars
    (for/hash ([(name _) (in-free-id-table recursives)])
      (values name (add-variable! eqs 'flat))))

  (define (lookup id)
    (variable-ref (hash-ref vars id)))

  (for ([(name v) (in-free-id-table recursives)])
    (match-define (kind-max others max) v)
    (add-equation! eqs
                   (hash-ref vars name)
                   (λ ()
                     (apply combine-kinds
                            max
                            (for/list ([(id _) (in-free-id-table others)])
                              (lookup id))))))
  (define var-values (resolve-equations eqs))
  (for/hash ([(name var) (in-hash vars)])
    (values name (hash-ref var-values var))))


(define (instantiate/inner sc recursive-kinds cache)
  (define bound-names (make-parameter null))
  ;; sc-queue : records the order in which to return syntax objects
  (define sc-queue null)
  ;; top-level? is #t only for the first call and not for recursive
  ;; calls, which helps for inlining
  (define (recur sc [top-level? #f])
    (cond [(and cache (hash-ref cache sc #f)) => car]
          [(arr/sc? sc) (make-contract sc)]
          [(or (parametric->/sc? sc) (sealing->/sc? sc))
           (match-define (or (parametric->/sc: vars _)
                             (sealing->/sc: vars _ _))
                         sc)
           (parameterize ([bound-names (append vars (bound-names))])
             (make-contract sc))]
          ;; If any names are bound, the contract can't be shared
          ;; becuase it depends on the scope it's in
          [(ormap (λ (n) (name-free-in? n sc)) (bound-names))
           (make-contract sc)]
          [(static-contract-may-contain-free-ids?) (make-contract sc)]
          [else
           (define ctc (make-contract sc))
           (cond 
            ;; when a contract benefits from inlining
            ;; (e.g., ->) and this contract appears
            ;; directly in a define-module-boundary-contract
            ;; position (i.e, top-level? is #t) then
            ;; don't generate a new identifier for it
            [(or (should-inline-contract? ctc #:top-level? top-level?)
                 (not cache))
             ctc]
            [else
             (define fresh-id (generate-temporary))
             (hash-set! cache sc (cons fresh-id ctc))
             (set! sc-queue (cons sc sc-queue))
             fresh-id])]))
  (define (make-contract sc)
    (match sc
      [(recursive-sc names values body)
       (define raw-names (generate-temporaries names))
       (define raw-bindings
         (parameterize ([bound-names (append names (bound-names))])
           (for/list ([raw-name (in-list raw-names)]
                      [value (in-list values)])
             #`[#,raw-name #,(recur value)])))
       (define bindings
         (for/list ([name (in-list names)]
                    [raw-name (in-list raw-names)])
            #`[#,name (recursive-contract #,raw-name
                                            #,(kind->keyword
                                                (hash-ref recursive-kinds name)))]))
       #`(letrec (#,@bindings #,@raw-bindings)
           #,(parameterize ([bound-names (append names (bound-names))])
               (recur body)))]
      [(? sc? sc)
       (sc->contract sc recur)]))
  (define ctc (recur sc #t))
  (define name-defs (compute-defs sc))
  ;; These are extra contract definitions for the name static contracts
  ;; that are used for this type. Since these are shared across multiple
  ;; contracts from a single contract fixup pass, we use the name-defined
  ;; table to see if we've already defined it. If so, we avoid duplicating
  ;; the definition later.
  (define extra-defs
    (cond [(hash-empty? name-defs) null]
          [else
           (define names+values (hash->list name-defs))
           (define names (apply append (map car names+values)))
           (for/list ([name (in-list names)]
                      [sc   (in-list (apply append (map cdr names+values)))]
                      #:unless (lookup-name-defined name))
             (set-name-defined name)
             #`(define #,name
                 (recursive-contract #,(recur sc)
                                     #,(kind->keyword (hash-ref recursive-kinds name)))))]))
  (list (append ;; These contracts are sub-contract definitions used to
                ;; increase sharing among contracts in a given fixup pass
                extra-defs
                (for/list ([sc (in-list (reverse sc-queue))])
                  (match-define (cons id ctc) (hash-ref cache sc))
                  #`(define #,id #,ctc)))
        ctc))

;; Determine whether the given contract syntax should be inlined or
;; not.  if top-level? is true, we inline functions because the
;; contract system treats them specially. Otherwise, always inline
;; simple things.
(define (should-inline-contract? stx #:top-level? [top-level? #f])
  (or
   (syntax-case stx (quote) [(quote _) #t] [_ #f])
   ;; no need to generate an extra def for things that are already identifiers
   (identifier? stx)
   ;; ->* are handled specially by the contract system
   (let ([sexp (syntax-e stx)])
     (and top-level?
          (pair? sexp)
          (or (free-identifier=? (car sexp) #'->)
              (free-identifier=? (car sexp) #'->*))))))

;; determine if a given name is free in the sc
(define (name-free-in? name sc)
  (let/ec escape
    (define/match (free? sc _)
      [((or (recursive-sc-use name*)
            (parametric-var/sc: name*)
            (sealing-var/sc: name*)
            (name/sc: name*))
        _)
       (when (free-identifier=? name name*)
         (escape #t))]
      [(_ _) (sc-traverse sc free?)])
    (free? sc 'dummy)
    #f))
