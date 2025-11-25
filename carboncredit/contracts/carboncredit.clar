;; Carbon Credits - Decentralized Carbon Offset Marketplace
;; A transparent, verifiable carbon credit trading platform on Stacks

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-not-found (err u102))
(define-constant err-insufficient-credits (err u103))
(define-constant err-invalid-amount (err u104))
(define-constant err-already-verified (err u105))
(define-constant err-not-verified (err u106))
(define-constant err-already-retired (err u107))
(define-constant err-invalid-price (err u108))
(define-constant err-project-inactive (err u109))
(define-constant err-self-transfer (err u110))
(define-constant err-paused (err u111))

;; Data Variables
(define-data-var project-nonce uint u0)
(define-data-var credit-nonce uint u0)
(define-data-var contract-paused bool false)
(define-data-var total-credits-issued uint u0)
(define-data-var total-credits-retired uint u0)

;; Data Maps
(define-map projects
    uint
    {
        owner: principal,
        name: (string-utf8 100),
        location: (string-utf8 100),
        project-type: (string-utf8 50),
        verified: bool,
        active: bool,
        total-credits: uint,
        credits-retired: uint,
        verifier: (optional principal)
    }
)

(define-map credits
    uint
    {
        project-id: uint,
        owner: principal,
        amount: uint,
        vintage-year: uint,
        retired: bool,
        retirement-date: uint,
        retirement-reason: (optional (string-utf8 200))
    }
)

(define-map user-credits
    principal
    uint
)

(define-map project-credits
    uint
    uint
)

(define-map credit-listings
    uint
    {
        seller: principal,
        credit-id: uint,
        price: uint,
        active: bool
    }
)

(define-map listing-nonce
    principal
    uint
)

;; Read-only functions
(define-read-only (get-project (project-id uint))
    (map-get? projects project-id)
)

(define-read-only (get-credit (credit-id uint))
    (map-get? credits credit-id)
)

(define-read-only (get-user-balance (user principal))
    (default-to u0 (map-get? user-credits user))
)

(define-read-only (get-project-available-credits (project-id uint))
    (default-to u0 (map-get? project-credits project-id))
)

(define-read-only (get-listing (listing-id uint))
    (map-get? credit-listings listing-id)
)

(define-read-only (get-total-credits-issued)
    (var-get total-credits-issued)
)

(define-read-only (get-total-credits-retired)
    (var-get total-credits-retired)
)

(define-read-only (is-paused)
    (var-get contract-paused)
)

(define-read-only (get-net-impact)
    (- (var-get total-credits-issued) (var-get total-credits-retired))
)

;; Private helper functions
(define-private (is-project-owner (project-id uint) (caller principal))
    (match (map-get? projects project-id)
        project (is-eq caller (get owner project))
        false
    )
)

(define-private (is-credit-owner (credit-id uint) (caller principal))
    (match (map-get? credits credit-id)
        credit (is-eq caller (get owner credit))
        false
    )
)

;; Public functions

;; Register a new carbon offset project
(define-public (register-project 
    (name (string-utf8 100))
    (location (string-utf8 100))
    (project-type (string-utf8 50))
)
    (let
        (
            (new-id (+ (var-get project-nonce) u1))
        )
        (asserts! (not (var-get contract-paused)) err-paused)
        
        (map-set projects new-id
            {
                owner: tx-sender,
                name: name,
                location: location,
                project-type: project-type,
                verified: false,
                active: true,
                total-credits: u0,
                credits-retired: u0,
                verifier: none
            }
        )
        
        (map-set project-credits new-id u0)
        (var-set project-nonce new-id)
        (ok new-id)
    )
)

;; Verify a project (owner only)
(define-public (verify-project (project-id uint) (verifier principal))
    (let
        (
            (project (unwrap! (map-get? projects project-id) err-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (not (get verified project)) err-already-verified)
        
        (map-set projects project-id
            (merge project {
                verified: true,
                verifier: (some verifier)
            })
        )
        (ok true)
    )
)

;; Issue carbon credits (project owner only, must be verified)
(define-public (issue-credits 
    (project-id uint)
    (amount uint)
    (vintage-year uint)
)
    (let
        (
            (project (unwrap! (map-get? projects project-id) err-not-found))
            (new-credit-id (+ (var-get credit-nonce) u1))
            (current-project-credits (get-project-available-credits project-id))
        )
        (asserts! (not (var-get contract-paused)) err-paused)
        (asserts! (is-project-owner project-id tx-sender) err-not-authorized)
        (asserts! (get verified project) err-not-verified)
        (asserts! (get active project) err-project-inactive)
        (asserts! (> amount u0) err-invalid-amount)
        
        ;; Create credit record
        (map-set credits new-credit-id
            {
                project-id: project-id,
                owner: tx-sender,
                amount: amount,
                vintage-year: vintage-year,
                retired: false,
                retirement-date: u0,
                retirement-reason: none
            }
        )
        
        ;; Update balances
        (map-set user-credits tx-sender 
            (+ (get-user-balance tx-sender) amount)
        )
        
        (map-set project-credits project-id 
            (+ current-project-credits amount)
        )
        
        (map-set projects project-id
            (merge project {
                total-credits: (+ (get total-credits project) amount)
            })
        )
        
        ;; Update global stats
        (var-set credit-nonce new-credit-id)
        (var-set total-credits-issued (+ (var-get total-credits-issued) amount))
        
        (ok new-credit-id)
    )
)

;; Transfer credits to another user
(define-public (transfer-credits (recipient principal) (amount uint))
    (let
        (
            (sender-balance (get-user-balance tx-sender))
            (recipient-balance (get-user-balance recipient))
        )
        (asserts! (not (var-get contract-paused)) err-paused)
        (asserts! (not (is-eq tx-sender recipient)) err-self-transfer)
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (>= sender-balance amount) err-insufficient-credits)
        
        ;; Update balances
        (map-set user-credits tx-sender (- sender-balance amount))
        (map-set user-credits recipient (+ recipient-balance amount))
        
        (ok true)
    )
)

;; List credits for sale
(define-public (list-credits-for-sale (credit-id uint) (price uint))
    (let
        (
            (credit (unwrap! (map-get? credits credit-id) err-not-found))
            (current-nonce (default-to u0 (map-get? listing-nonce tx-sender)))
            (new-listing-id (+ current-nonce u1))
        )
        (asserts! (not (var-get contract-paused)) err-paused)
        (asserts! (is-credit-owner credit-id tx-sender) err-not-authorized)
        (asserts! (not (get retired credit)) err-already-retired)
        (asserts! (> price u0) err-invalid-price)
        
        (map-set credit-listings new-listing-id
            {
                seller: tx-sender,
                credit-id: credit-id,
                price: price,
                active: true
            }
        )
        
        (map-set listing-nonce tx-sender new-listing-id)
        (ok new-listing-id)
    )
)

;; Buy listed credits
(define-public (buy-credits (listing-id uint))
    (let
        (
            (listing (unwrap! (map-get? credit-listings listing-id) err-not-found))
            (credit (unwrap! (map-get? credits (get credit-id listing)) err-not-found))
            (seller (get seller listing))
            (price (get price listing))
            (amount (get amount credit))
            (buyer-balance (get-user-balance tx-sender))
            (seller-balance (get-user-balance seller))
        )
        (asserts! (not (var-get contract-paused)) err-paused)
        (asserts! (get active listing) err-not-found)
        (asserts! (not (is-eq tx-sender seller)) err-self-transfer)
        
        ;; Transfer STX from buyer to seller
        (try! (stx-transfer? price tx-sender seller))
        
        ;; Update credit ownership
        (map-set credits (get credit-id listing)
            (merge credit {owner: tx-sender})
        )
        
        ;; Update balances
        (map-set user-credits seller (- seller-balance amount))
        (map-set user-credits tx-sender (+ buyer-balance amount))
        
        ;; Deactivate listing
        (map-set credit-listings listing-id
            (merge listing {active: false})
        )
        
        (ok true)
    )
)

;; Cancel listing
(define-public (cancel-listing (listing-id uint))
    (let
        (
            (listing (unwrap! (map-get? credit-listings listing-id) err-not-found))
        )
        (asserts! (is-eq tx-sender (get seller listing)) err-not-authorized)
        (asserts! (get active listing) err-not-found)
        
        (map-set credit-listings listing-id
            (merge listing {active: false})
        )
        (ok true)
    )
)

;; Retire credits (remove from circulation)
(define-public (retire-credits 
    (credit-id uint)
    (reason (string-utf8 200))
)
    (let
        (
            (credit (unwrap! (map-get? credits credit-id) err-not-found))
            (project (unwrap! (map-get? projects (get project-id credit)) err-not-found))
            (amount (get amount credit))
            (owner-balance (get-user-balance tx-sender))
            (current-project-credits (get-project-available-credits (get project-id credit)))
        )
        (asserts! (not (var-get contract-paused)) err-paused)
        (asserts! (is-credit-owner credit-id tx-sender) err-not-authorized)
        (asserts! (not (get retired credit)) err-already-retired)
        
        ;; Update credit status
        (map-set credits credit-id
            (merge credit {
                retired: true,
                retirement-date: stacks-block-height,
                retirement-reason: (some reason)
            })
        )
        
        ;; Update balances
        (map-set user-credits tx-sender (- owner-balance amount))
        
        (map-set project-credits (get project-id credit)
            (- current-project-credits amount)
        )
        
        (map-set projects (get project-id credit)
            (merge project {
                credits-retired: (+ (get credits-retired project) amount)
            })
        )
        
        ;; Update global stats
        (var-set total-credits-retired (+ (var-get total-credits-retired) amount))
        
        (ok true)
    )
)

;; Batch retire credits (optimized for multiple retirements)
(define-public (batch-retire-credits 
    (credit-ids (list 10 uint))
    (reason (string-utf8 200))
)
    (begin
        (asserts! (not (var-get contract-paused)) err-paused)
        (ok (map retire-single-credit credit-ids))
    )
)

(define-private (retire-single-credit (credit-id uint))
    (match (retire-credits credit-id u"Batch retirement")
        success true
        error false
    )
)

;; Deactivate project (owner only)
(define-public (deactivate-project (project-id uint))
    (let
        (
            (project (unwrap! (map-get? projects project-id) err-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        
        (map-set projects project-id
            (merge project {active: false})
        )
        (ok true)
    )
)

;; Pause contract (owner only, emergency)
(define-public (pause-contract)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set contract-paused true)
        (ok true)
    )
)

;; Unpause contract (owner only)
(define-public (unpause-contract)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set contract-paused false)
        (ok true)
    )
)