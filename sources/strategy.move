/*
  Copyright (c) 2026 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code
  requires prior written permission from the Ember Protocol Inc.
*/

/// Supply-only strategy adapters for the atomic liquidity vault.
///
/// Sui Move does not support dynamic dispatch, so a vault that wants to choose
/// between multiple lending markets at runtime must dispatch on a tag and call
/// statically-resolved functions per protocol. The atomic vault stores a `u8`
/// strategy tag (0 = none, 1 = Suilend) plus protocol-specific
/// state in dynamic fields under stable byte-string keys.
///
/// Both integrations are capability-shaped, and for the same reason: the
/// protocol tracks the deposit — and the reward share it earns — inside its own
/// shared object, and the vault holds only the key.
///   • Suilend mints `Coin<CToken<P, T>>` on supply, which the vault deposits
///     straight into an `Obligation` and keeps the `ObligationOwnerCap<P>` for.
///     Holding cTokens raw instead would earn the reserve's base APR and no
///     liquidity-mining rewards, since reward share is the obligation's
///     `deposited_ctoken_amount`. Withdrawals come back out as cTokens and are
///     then redeemed for the underlying.
///
/// Discarding the capability strands whatever is left behind, so the teardown
/// path asserts the position is empty first and requires rewards to be swept in
/// the same transaction.
///
/// All public functions are package-visible — the only call site is
/// `ember_vaults::atomic_liquidity_vault`, which gates them on admin / operator
/// roles before invocation.
module ember_vaults::strategy {

    // === Imports ===

    use std::type_name::{Self, TypeName};

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::dynamic_field;
    use sui::sui::SUI;
    use sui_system::sui_system::SuiSystemState;

    use suilend::lending_market::{Self, LendingMarket, ObligationOwnerCap};
    use suilend::obligation::{Self, Obligation};
    use suilend::reserve::{Self, CToken};
    use suilend::decimal;


    // === Errors ===
    // Reserved range: 7000-7999.

    /// Strategy tag is not one of the recognised values.
    const EInvalidStrategy: u64 = 7000;
    /// Suilend state has not been initialised on this vault.
    const ESuilendStateMissing: u64 = 7001;
    /// Operation called with zero amount.
    const EZeroAmount: u64 = 7002;
    /// Suilend state already exists — refusing to overwrite reserve index.
    const ESuilendStateAlreadyExists: u64 = 7003;
    /// Strategy withdrew less than the requested deficit. Indicates a non-spec-compliant
    /// or paused/rate-limited lending market — caller should not proceed with the
    /// downstream transfer (especially on user-facing auto-pull paths where shares
    /// have already been burned).
    const EStrategyShortDelivery: u64 = 7004;
    /// The Suilend obligation holds fewer cTokens than are needed to cover the
    /// requested underlying amount. Distinct from `EStrategyShortDelivery`
    /// (which means the market delivered less than the cTokens were worth) so
    /// genuine underfunding is diagnosable.
    const EStrategyInsufficientCTokens: u64 = 7005;
    /// A GENERIC Suilend redemption path (`withdraw_from_suilend<P, T>` or
    /// `clear_suilend_state<P, T>`) was invoked with `T = SUI`. Suilend serves
    /// SUI redemptions through `redeem_ctokens_and_withdraw_liquidity_request
    /// -> unstake_sui_from_staker -> fulfill_liquidity_request`, which needs
    /// `&mut SuiSystemState` — the generic combined helper has no unstake step
    /// and aborts once the reserve has moved physical SUI into its staker. SUI
    /// must go through the monomorphic `*_sui` variants.
    const ESuilendSuiRequiresSuiPath: u64 = 7006;
    /// The `LendingMarket<P>` supplied does not match the market committed at
    /// activation. Guards against an operator routing funds to, or valuing /
    /// clearing against, an unintended Suilend market (I-11).
    const ESuilendMarketMismatch: u64 = 7007;
    /// No Suilend obligation has been opened on this vault. Supplying,
    /// withdrawing and claiming all require one — `open_suilend_obligation` is a
    /// separate activation step after `set_strategy_suilend`. A loud abort
    /// rather than a silent fall back to raw cTokens, which would earn base
    /// interest only and look identical on chain.
    ///
    /// Teardown is the deliberate exception: `drain_suilend_obligation` returns
    /// empty-handed instead of aborting, so a vault that activated but never
    /// enrolled can still exit the strategy.
    const ESuilendObligationMissing: u64 = 7008;
    /// An obligation already exists — refusing to clobber the only capability
    /// that can reach the deposit inside it.
    const ESuilendObligationAlreadyExists: u64 = 7009;
    /// A Suilend clear finished with cTokens still deposited in the obligation.
    /// Aborting leaves `strategy_kind`, the cap and the metadata untouched (Move
    /// reverts the whole call), so the operator can retry.
    const ESuilendResidualDeposit: u64 = 7010;
    /// `T` does not match the collateral type committed at activation. See
    /// `assert_suilend_coin_type` — a wrong `T` reads an empty position rather
    /// than failing, so this must be checked explicitly.
    const ESuilendCoinTypeMismatch: u64 = 7011;
    /// The committed reserve index is not the index `market` uses for `T`.
    /// Caught at enrolment, before any supply can move against it.
    const ESuilendReserveIndexMismatch: u64 = 7012;
    /// `withdraw_secondary_collateral` was called with the vault's committed
    /// collateral type. That position is the strategy itself and must exit
    /// through `withdraw_from_suilend`, which sizes and enforces delivery.
    const ESuilendSecondaryIsCommittedType: u64 = 7013;

    // === Strategy Tags ===

    /// No external strategy — vault keeps all idle assets in its own balance.
    const STRATEGY_NONE: u8 = 0;
    /// Supply-only deposits into a Suilend reserve via cTokens.
    const STRATEGY_SUILEND: u8 = 1;

    // === Dynamic Field Keys ===
    // Stable byte-string keys hung off the atomic vault's UID. Names are
    // prefixed with `al_strategy_` so they cannot collide with future ember
    // vault dynamic fields.

    const KEY_SUILEND_RESERVE_INDEX: vector<u8> = b"al_strategy_suilend_reserve_idx";
    /// Collateral type committed at activation. The vault holds no cTokens of
    /// its own — they live inside the obligation — so there is no typed slot to
    /// carry `T` implicitly, and it is pinned explicitly instead. See
    /// `assert_suilend_coin_type` for why this is load-bearing (I-11).
    const KEY_SUILEND_COIN_TYPE: vector<u8> = b"al_strategy_suilend_coin_type";
    /// Object ID of the `LendingMarket<P>` committed at activation. Every later
    /// Suilend call must present the same market (I-11).
    const KEY_SUILEND_MARKET_ID: vector<u8> = b"al_strategy_suilend_market_id";
    /// `ObligationOwnerCap<P>` for the vault's Suilend obligation. Holding the
    /// supply inside an obligation is what makes it eligible for Suilend's
    /// deposit-side liquidity mining; raw cTokens accrue base interest only,
    /// because reward share is tracked per obligation, not per cToken holder.
    const KEY_SUILEND_OBLIGATION_CAP: vector<u8> = b"al_strategy_suilend_obligation_cap";
    /// Object ID of that obligation. Kept as an untyped `ID` so existence can be
    /// checked without knowing `P`, and so it can be verified off chain.
    const KEY_SUILEND_OBLIGATION_ID: vector<u8> = b"al_strategy_suilend_obligation_id";

    // === Public Strategy Tag Accessors ===

    public fun strategy_none(): u8 { STRATEGY_NONE }
    public fun strategy_suilend(): u8 { STRATEGY_SUILEND }
    public fun is_valid_strategy(s: u8): bool {
        s == STRATEGY_NONE || s == STRATEGY_SUILEND
    }

    public(package) fun assert_valid_strategy(s: u8) {
        assert!(is_valid_strategy(s), EInvalidStrategy);
    }

    // === Suilend State Init / Cleanup ===

    /// Commits the Suilend position's full identity at activation: the reserve
    /// index, the `LendingMarket<P>` object ID, and the collateral type `T`.
    ///
    /// Storing only the reserve index (the original behaviour) left the market
    /// object and the generics to whichever values the operator happened to pass
    /// on the first supply, so nothing on chain could detect a wrong market, and
    /// `clear` could drop the metadata without draining the real position.
    /// Committing the market ID and `T` here makes that detectable (I-11); `P`
    /// is pinned by the `ObligationOwnerCap<P>` that `open_suilend_obligation`
    /// stores.
    ///
    /// Aborts if state already exists — admin must clear first to switch market
    /// or reserve.
    public(package) fun init_suilend_state<P, T>(
        uid: &mut UID,
        market: &LendingMarket<P>,
        reserve_array_index: u64,
    ) {
        assert!(!dynamic_field::exists_with_type<vector<u8>, u64>(uid, KEY_SUILEND_RESERVE_INDEX), ESuilendStateAlreadyExists);
        dynamic_field::add(uid, KEY_SUILEND_RESERVE_INDEX, reserve_array_index);
        dynamic_field::add(uid, KEY_SUILEND_MARKET_ID, object::id(market));
        dynamic_field::add(uid, KEY_SUILEND_COIN_TYPE, type_name::with_defining_ids<T>());
    }

    /// Aborts unless `T` is the collateral type committed at activation.
    ///
    /// Load-bearing rather than defensive. Every typed Suilend path reaches the
    /// position through `obligation::deposited_ctoken_amount<P, T>`, which picks
    /// the deposit out of the obligation BY COIN TYPE and returns 0 when it
    /// finds none. So a wrong `T` does not fail loudly — it reads an empty
    /// position. On the teardown path that is the dangerous case: `clear` would
    /// see zero deposited, skip the drain, and discard the obligation cap while
    /// the real deposit is still inside, making it permanently unreachable. This
    /// assertion is what turns that into an abort. Same failure class as I-11,
    /// which the typed cToken slot used to catch implicitly.
    public(package) fun assert_suilend_coin_type<T>(uid: &UID) {
        assert!(
            dynamic_field::exists_with_type<vector<u8>, TypeName>(uid, KEY_SUILEND_COIN_TYPE),
            ESuilendStateMissing,
        );
        let committed = *dynamic_field::borrow<vector<u8>, TypeName>(uid, KEY_SUILEND_COIN_TYPE);
        assert!(committed == type_name::with_defining_ids<T>(), ESuilendCoinTypeMismatch);
    }

    /// Aborts unless `market` is the one committed at activation.
    fun assert_suilend_market<P>(uid: &UID, market: &LendingMarket<P>) {
        assert!(
            dynamic_field::exists_with_type<vector<u8>, ID>(uid, KEY_SUILEND_MARKET_ID),
            ESuilendStateMissing,
        );
        let committed = *dynamic_field::borrow<vector<u8>, ID>(uid, KEY_SUILEND_MARKET_ID);
        assert!(committed == object::id(market), ESuilendMarketMismatch);
    }

    /// Object ID of the committed Suilend market, for off-chain verification.
    public(package) fun suilend_market_id(uid: &UID): ID {
        *dynamic_field::borrow<vector<u8>, ID>(uid, KEY_SUILEND_MARKET_ID)
    }

    /// Aborts when `T = SUI`, steering callers to the monomorphic `*_sui`
    /// redemption variants. Only the generic REDEMPTION paths need this —
    /// supply is type-agnostic because `deposit_liquidity_and_mint_ctokens`
    /// never touches the staker.
    fun assert_suilend_not_sui<T>() {
        assert!(
            type_name::with_defining_ids<T>() != type_name::with_defining_ids<SUI>(),
            ESuilendSuiRequiresSuiPath,
        );
    }

    fun has_suilend_state(uid: &UID): bool {
        dynamic_field::exists_with_type<vector<u8>, u64>(uid, KEY_SUILEND_RESERVE_INDEX)
    }

    // === Suilend Obligation ===
    //
    // Suilend accounts liquidity-mining rewards against an `Obligation`, never
    // against raw cToken holdings: reward share is the obligation's
    // `deposited_ctoken_amount`, updated on every deposit / withdraw. Supplying
    // via `deposit_liquidity_and_mint_ctokens` alone therefore earns the
    // reserve's base APR (through the cToken ratio) and nothing else.
    //
    // Enrolling costs no oracle dependency, which is the reason the deposit can
    // live entirely inside the obligation rather than needing a raw-cToken
    // buffer to serve users:
    //
    //   * `deposit_ctokens_into_obligation` asserts nothing about prices —
    //     adding collateral cannot worsen health.
    //   * `withdraw_ctokens` takes no `PriceInfoObject`. It calls
    //     `obligation::refresh` itself, which reports staleness as a returned
    //     signal rather than aborting, and `obligation::withdraw` then discards
    //     that signal without asserting **when the obligation has no borrows**.
    //   * `claim_rewards` gates only on bad debt.
    //
    // The vault is supply-only by construction — this module exposes no borrow
    // adapter — so `obligation.borrows` is permanently empty and every path
    // above stays Pyth-free. That invariant is what keeps the user-facing
    // instant-withdraw path (`ensure_liquidity_suilend`) free of an oracle
    // dependency, and it is the thing to re-examine first if a borrow adapter
    // is ever added.

    /// Opens the Suilend obligation the vault's supply is deposited into.
    ///
    /// Deliberately a separate step from `init_suilend_state` rather than folded
    /// into it: activation stays a pure ember-side state commitment that never
    /// enters Suilend, and enrolment is independently gated and auditable. The
    /// activation runbook is therefore two calls — `set_strategy_suilend` then
    /// `open_suilend_obligation` — and supplying before the second aborts with
    /// `ESuilendObligationMissing`.
    ///
    /// Requires Suilend state to already exist, so the market and reserve
    /// commitments from activation are in force (I-11).
    public(package) fun open_suilend_obligation<P, T>(
        uid: &mut UID,
        market: &mut LendingMarket<P>,
        ctx: &mut TxContext,
    ) {
        assert!(has_suilend_state(uid), ESuilendStateMissing);
        assert_suilend_market<P>(uid, market);
        assert_suilend_coin_type<T>(uid);
        assert_suilend_reserve_index<P, T>(uid, market);
        assert!(!has_suilend_obligation(uid), ESuilendObligationAlreadyExists);

        let cap = lending_market::create_obligation<P>(market, ctx);
        let obligation_id = lending_market::obligation_id<P>(&cap);
        dynamic_field::add(uid, KEY_SUILEND_OBLIGATION_CAP, cap);
        dynamic_field::add(uid, KEY_SUILEND_OBLIGATION_ID, obligation_id);
    }

    /// Aborts unless the committed reserve index is the one `market` actually
    /// uses for `T` (I-11 follow-up).
    ///
    /// `init_suilend_state` took `reserve_array_index` on trust: a wrong index
    /// still committed cleanly, and the mistake only surfaced later, inside
    /// Suilend, on a call moving real funds. Committing the market object and
    /// `T` did not catch it, because neither says anything about the index.
    ///
    /// Checked here rather than at activation deliberately. The lookup
    /// (`lending_market::reserve_array_index`) is a Suilend call, and activation
    /// is otherwise a pure ember-side state commitment that never enters
    /// Suilend — a property the tests depend on. Enrolment already enters
    /// Suilend, is mandatory, and precedes every supply, so validating here
    /// still guarantees no funds move against an unvalidated index.
    ///
    /// The index comparison alone is NOT sufficient, which an earlier version of
    /// this comment got wrong. `reserve_array_index` returns `reserves.length`
    /// when `T` has no reserve in the market rather than aborting, so a
    /// committed index that happens to equal the length matches a type that is
    /// not there at all — a sentinel compared against itself. Probing the
    /// reserve closes that: `reserve<P, T>` resolves the index and borrows, so
    /// an absent `T` aborts out of bounds inside Suilend.
    ///
    /// The probe runs second so a wrong-but-valid index still reports our own
    /// error rather than an opaque upstream one. Suilend exposes no reserve-count
    /// accessor, so the absent-`T` case cannot be given a nicer code than the
    /// upstream abort.
    fun assert_suilend_reserve_index<P, T>(uid: &UID, market: &LendingMarket<P>) {
        let committed = suilend_reserve_index(uid);
        assert!(
            committed == lending_market::reserve_array_index<P, T>(market),
            ESuilendReserveIndexMismatch,
        );
        let _ = lending_market::reserve<P, T>(market);
    }

    /// Whether an obligation has been opened. Checked against the untyped `ID`
    /// field so callers need not supply `P`.
    public(package) fun has_suilend_obligation(uid: &UID): bool {
        dynamic_field::exists_with_type<vector<u8>, ID>(uid, KEY_SUILEND_OBLIGATION_ID)
    }

    /// Reserve array index committed at activation, for event emission.
    public(package) fun suilend_reserve_index(uid: &UID): u64 {
        assert!(has_suilend_state(uid), ESuilendStateMissing);
        *dynamic_field::borrow<vector<u8>, u64>(uid, KEY_SUILEND_RESERVE_INDEX)
    }

    /// Object ID of the vault's obligation, for off-chain verification.
    public(package) fun suilend_obligation_id(uid: &UID): ID {
        assert!(has_suilend_obligation(uid), ESuilendObligationMissing);
        *dynamic_field::borrow<vector<u8>, ID>(uid, KEY_SUILEND_OBLIGATION_ID)
    }

    fun borrow_obligation_cap<P>(uid: &UID): &ObligationOwnerCap<P> {
        assert!(
            dynamic_field::exists_with_type<vector<u8>, ObligationOwnerCap<P>>(
                uid,
                KEY_SUILEND_OBLIGATION_CAP,
            ),
            ESuilendObligationMissing,
        );
        dynamic_field::borrow<vector<u8>, ObligationOwnerCap<P>>(uid, KEY_SUILEND_OBLIGATION_CAP)
    }

    /// cTokens of type `T` the vault has deposited in its obligation. Returns 0
    /// when no obligation has been opened, so the teardown and view paths stay
    /// callable on a vault that never enrolled.
    fun obligation_ctoken_amount<P, T>(uid: &UID, market: &LendingMarket<P>): u64 {
        if (!has_suilend_obligation(uid)) { return 0 };
        let obligation_id = *dynamic_field::borrow<vector<u8>, ID>(uid, KEY_SUILEND_OBLIGATION_ID);
        obligation::deposited_ctoken_amount<P, T>(
            lending_market::obligation<P>(market, obligation_id),
        )
    }

    fun borrow_obligation<P>(uid: &UID, market: &LendingMarket<P>): &Obligation<P> {
        let obligation_id = *dynamic_field::borrow<vector<u8>, ID>(uid, KEY_SUILEND_OBLIGATION_ID);
        lending_market::obligation<P>(market, obligation_id)
    }

    /// Withdraws a collateral position of coin type `C` that is NOT the vault's
    /// committed `T`, and returns it as `Coin<C>` for the caller to forward.
    ///
    /// Exists because of Q2. `claim_rewards_and_deposit` is permissionless, so a
    /// third party can put reward tokens into this obligation as collateral in
    /// a type the vault never chose. Teardown refuses to discard the cap while
    /// any deposit remains, so without a way to remove those the exit would be
    /// permanently blockable by anyone. This is that way out: the operator names
    /// the type — readable off chain from `obligation::deposits` — and pulls it.
    ///
    /// Aborts if `C == T`: the committed asset is the strategy position and must
    /// go through `withdraw_from_suilend`, which sizes against a target amount
    /// and enforces delivery. Routing it through here would bypass both.
    ///
    /// Aborts for `C = SUI` — see `withdraw_secondary_collateral_sui`.
    ///
    /// Pyth-free for the same reason as every other withdraw here: the vault
    /// never borrows.
    public(package) fun withdraw_secondary_collateral<P, C>(
        uid: &UID,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<C> {
        assert_suilend_market<P>(uid, market);
        assert!(
            !committed_coin_type_is<C>(uid),
            ESuilendSecondaryIsCommittedType,
        );
        assert_suilend_not_sui<C>();

        let (reserve_index, ctokens) = pull_secondary_ctokens<P, C>(uid, market, clock, ctx);
        lending_market::redeem_ctokens_and_withdraw_liquidity<P, C>(
            market, reserve_index, clock, ctokens, option::none(), ctx,
        )
    }

    /// SUI counterpart of `withdraw_secondary_collateral`.
    ///
    /// Same reason the main withdraw path needed one (M-01): Suilend stakes idle
    /// SUI reserve balance, so the combined redemption helper — which is exactly
    /// `request -> fulfill` with no unstake between — pays from a liquid balance
    /// that may be empty and aborts in `balance::split`. A foreign SUI position
    /// is a likely case, not a corner one: sSUI and SUI are what these reserves
    /// actually pay out, so a reward deposited into the obligation by a third
    /// party can easily be SUI.
    public(package) fun withdraw_secondary_collateral_sui<P>(
        uid: &UID,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        assert_suilend_market<P>(uid, market);
        assert!(!committed_coin_type_is<SUI>(uid), ESuilendSecondaryIsCommittedType);

        let (reserve_index, ctokens) = pull_secondary_ctokens<P, SUI>(uid, market, clock, ctx);
        let drained = redeem_suilend_ctokens_sui<P>(
            market, system_state, reserve_index, clock, coin::into_balance(ctokens), ctx,
        );
        coin::from_balance(drained, ctx)
    }

    /// Shared prelude for both secondary-collateral paths: locates the foreign
    /// position, checks it is non-empty, and pulls its cTokens out of the
    /// obligation. Redemption differs between `C = SUI` and everything else, so
    /// it stays with the caller.
    fun pull_secondary_ctokens<P, C>(
        uid: &UID,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, Coin<CToken<P, C>>) {
        assert!(has_suilend_obligation(uid), ESuilendObligationMissing);

        let amount = obligation::deposited_ctoken_amount<P, C>(borrow_obligation<P>(uid, market));
        assert!(amount > 0, EZeroAmount);

        let reserve_index = lending_market::reserve_array_index<P, C>(market);
        let cap = borrow_obligation_cap<P>(uid);
        let ctokens = lending_market::withdraw_ctokens<P, C>(
            market, reserve_index, cap, clock, amount, ctx,
        );
        (reserve_index, ctokens)
    }

    fun committed_coin_type_is<C>(uid: &UID): bool {
        if (!dynamic_field::exists_with_type<vector<u8>, TypeName>(uid, KEY_SUILEND_COIN_TYPE)) {
            return false
        };
        *dynamic_field::borrow<vector<u8>, TypeName>(uid, KEY_SUILEND_COIN_TYPE)
            == type_name::with_defining_ids<C>()
    }

    /// Pulls `ctoken_amount` cTokens out of the vault's obligation.
    ///
    /// Asserts the obligation actually holds that many first, so a shortfall is
    /// diagnosable as genuine underfunding (`EStrategyInsufficientCTokens`)
    /// rather than surfacing as an opaque Suilend-side abort. `ctoken_amount` is
    /// the exact minimum from `suilend_ctokens_for_target` (M-04), so holding
    /// less is real underfunding, not a rounding artefact — hence the distinct
    /// abort rather than clamping into `EStrategyShortDelivery`.
    ///
    /// Passes an explicit amount, never Suilend's `u64::MAX` sentinel: the
    /// sentinel routes through `max_withdraw_amount`, which clamps to the market
    /// rate limiter and would silently under-deliver.
    fun withdraw_obligation_ctokens<P, T>(
        uid: &UID,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        reserve_index: u64,
        ctoken_amount: u64,
        ctx: &mut TxContext,
    ): Coin<CToken<P, T>> {
        // Enrolment is asserted by the callers, before they do any ratio math —
        // `obligation_ctoken_amount` returns 0 when no obligation exists, so
        // reaching the sufficiency check unenrolled would report the vault as
        // `EStrategyInsufficientCTokens`, which by its own definition means
        // genuine underfunding (M-04).
        assert!(
            ctoken_amount <= obligation_ctoken_amount<P, T>(uid, market),
            EStrategyInsufficientCTokens,
        );
        let cap = borrow_obligation_cap<P>(uid);
        lending_market::withdraw_ctokens<P, T>(market, reserve_index, cap, clock, ctoken_amount, ctx)
    }

    /// Withdraws everything the obligation holds and removes the capability.
    /// Shared by the generic and SUI teardown paths.
    ///
    /// Returns the cTokens for the caller to redeem — redemption differs between
    /// `T = SUI` and everything else, so it stays with the caller.
    ///
    /// REWARDS: discarding the cap makes the obligation permanently unreachable,
    /// stranding any unclaimed rewards. Callers must sweep every live reward
    /// triple via `claim_suilend_reward` first, in the same transaction.
    fun drain_suilend_obligation<P, T>(
        uid: &mut UID,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Balance<CToken<P, T>> {
        let mut pulled = balance::zero<CToken<P, T>>();
        if (!has_suilend_obligation(uid)) { return pulled };

        let deposited = obligation_ctoken_amount<P, T>(uid, market);
        if (deposited > 0) {
            let reserve_index = *dynamic_field::borrow<vector<u8>, u64>(
                uid,
                KEY_SUILEND_RESERVE_INDEX,
            );
            let ctokens = withdraw_obligation_ctokens<P, T>(
                uid,
                market,
                clock,
                reserve_index,
                deposited,
                ctx,
            );
            balance::join(&mut pulled, coin::into_balance(ctokens));
        };

        // Q2: the obligation must be empty of EVERY coin type, not just `T`.
        //
        // Suilend's `claim_rewards_and_deposit` takes an `obligation_id`, not
        // the owner cap — it is permissionless. Anyone can therefore claim this
        // vault's accrued rewards and deposit them into this obligation as
        // collateral in the REWARD's coin type, which the vault never chose and
        // cannot name. Draining `T` and asserting `deposited_ctoken_amount<P,T>
        // == 0` says nothing about those positions: the old check passed while
        // sSUI collateral sat in the obligation, and discarding the cap made it
        // unreachable forever.
        //
        // Checking the whole `deposits` vector closes that. It is also why the
        // exit cannot simply drain everything itself — Move needs a type
        // parameter per coin type, and the set is not known at compile time.
        // `withdraw_secondary_collateral<P, C>` is the escape: the operator
        // names each foreign type and pulls it out, then the exit proceeds.
        // Without that escape this assert would be a permissionless DoS on the
        // exit; with it, a third party can delay an exit but not block it.
        assert!(
            vector::is_empty(obligation::deposits<P>(borrow_obligation<P>(uid, market))),
            ESuilendResidualDeposit,
        );

        let cap: ObligationOwnerCap<P> = dynamic_field::remove(uid, KEY_SUILEND_OBLIGATION_CAP);
        // Park the emptied cap at the zero address — Suilend exposes no way to
        // destroy an obligation, and `ObligationOwnerCap` has key+store. The
        // obligation object survives on chain; the assertion above is what
        // guarantees it is empty before we give up the ability to reach it.
        transfer::public_transfer(cap, @0x0);
        let _: ID = dynamic_field::remove(uid, KEY_SUILEND_OBLIGATION_ID);
        pulled
    }

    /// Drains the Suilend strategy fully and removes its state: withdraws
    /// everything the obligation holds, redeems it via
    /// `lending_market::redeem_ctokens_and_withdraw_liquidity`, discards the
    /// emptied obligation cap, removes the activation commitments, and returns
    /// the underlying `Balance<T>` to the caller (typically
    /// `atomic_liquidity_vault::set_strategy_none_from_suilend`, which joins it
    /// into `vault.balance`).
    ///
    /// Returns `balance::zero<T>()` if nothing was deposited (idempotent on a
    /// strategy with zero supplied amount, and on one that never opened an
    /// obligation). Caller is responsible for handling the returned Balance even
    /// when zero.
    ///
    /// REWARDS: this discards the `ObligationOwnerCap`, after which any
    /// unclaimed Suilend rewards are unreachable. Sweep every live reward triple
    /// via `claim_suilend_reward` BEFORE calling this, in the same transaction.
    public(package) fun clear_suilend_state<P, T>(
        uid: &mut UID,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Balance<T> {
        assert_suilend_not_sui<T>();
        assert_suilend_market<P>(uid, market);
        assert_suilend_coin_type<T>(uid);
        let mut drained = balance::zero<T>();

        let pulled = drain_suilend_obligation<P, T>(uid, market, clock, ctx);
        if (balance::value(&pulled) > 0) {
            let reserve_index = *dynamic_field::borrow<vector<u8>, u64>(
                uid, KEY_SUILEND_RESERVE_INDEX,
            );
            let received = lending_market::redeem_ctokens_and_withdraw_liquidity<P, T>(
                market,
                reserve_index,
                clock,
                coin::from_balance(pulled, ctx),
                option::none(),
                ctx,
            );
            balance::join(&mut drained, coin::into_balance(received));
        } else {
            balance::destroy_zero(pulled);
        };

        remove_suilend_commitments(uid);
        drained
    }

    /// Removes the activation commitments written by `init_suilend_state`.
    /// Existence-guarded per field so teardown stays idempotent.
    fun remove_suilend_commitments(uid: &mut UID) {
        if (dynamic_field::exists_with_type<vector<u8>, u64>(uid, KEY_SUILEND_RESERVE_INDEX)) {
            let _: u64 = dynamic_field::remove(uid, KEY_SUILEND_RESERVE_INDEX);
        };
        if (dynamic_field::exists_with_type<vector<u8>, ID>(uid, KEY_SUILEND_MARKET_ID)) {
            let _: ID = dynamic_field::remove(uid, KEY_SUILEND_MARKET_ID);
        };
        if (dynamic_field::exists_with_type<vector<u8>, TypeName>(uid, KEY_SUILEND_COIN_TYPE)) {
            let _: TypeName = dynamic_field::remove(uid, KEY_SUILEND_COIN_TYPE);
        };
    }

    // === Suilend Supply / Withdraw ===

    /// Deposits `coins` into the configured Suilend reserve and merges the
    /// returned cTokens into the vault's stored `Balance<CToken<P, T>>`.
    /// Returns the underlying-T amount supplied (for event emission).
    public(package) fun supply_to_suilend<P, T>(
        uid: &mut UID,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        coins: Coin<T>,
        ctx: &mut TxContext,
    ): u64 {
        // No SUI guard here: `deposit_liquidity_and_mint_ctokens` never touches
        // the staker, so supply is type-agnostic. Redemption is the asymmetric
        // half — see `withdraw_from_suilend_sui`.
        assert_suilend_market<P>(uid, market);
        assert_suilend_coin_type<T>(uid);
        let amount = coin::value(&coins);
        assert!(amount > 0, EZeroAmount);
        assert!(
            dynamic_field::exists_with_type<vector<u8>, u64>(uid, KEY_SUILEND_RESERVE_INDEX),
            ESuilendStateMissing,
        );
        let reserve_index = *dynamic_field::borrow<vector<u8>, u64>(uid, KEY_SUILEND_RESERVE_INDEX);
        // Borrowed up here, before the mint, so an unenrolled vault aborts
        // `ESuilendObligationMissing` on the precondition rather than after
        // `deposit_liquidity_and_mint_ctokens` has already run. Move would
        // revert either way, so nothing was at risk — but paying for an
        // external state-mutating call before checking a precondition that
        // cannot pass is the wrong shape, and the abort is cheaper and clearer
        // here. Same reasoning as the withdraw paths.
        let cap = borrow_obligation_cap<P>(uid);

        let new_ctokens = lending_market::deposit_liquidity_and_mint_ctokens<P, T>(
            market,
            reserve_index,
            clock,
            coins,
            ctx,
        );

        // Straight into the obligation — this is the step that enrols the
        // deposit in the reserve's `deposits_pool_reward_manager`. The vault
        // retains no cTokens of its own.
        lending_market::deposit_ctokens_into_obligation<P, T>(
            market,
            reserve_index,
            cap,
            clock,
            new_ctokens,
            ctx,
        );

        amount
    }

    /// Smallest cToken count whose redemption delivers at least
    /// `target_amount` of `T`, using the simulated ratio (interest projected
    /// forward to `clock`).
    ///
    /// `decimal::div` floors to 18 decimals BEFORE `decimal::ceil` sees the
    /// quotient, so near an integer boundary the discarded fraction is
    /// unrecoverable and `ceil` selects one cToken too few — Suilend then
    /// floors `candidate * ratio` on redemption and delivers one base unit
    /// short. Verify the candidate against that same redemption arithmetic and
    /// bump it. The inner floor puts `candidate` at most one below the true
    /// ceiling, so a single bump is exact.
    ///
    /// Shared by the generic and SUI redemption paths so the sizing math
    /// cannot drift between them.
    fun suilend_ctokens_for_target<P, T>(
        market: &LendingMarket<P>,
        clock: &Clock,
        target_amount: u64,
    ): u64 {
        let r = lending_market::reserve<P, T>(market);
        let ratio = reserve::simulated_ctoken_ratio<P>(r, clock);
        let mut candidate = decimal::ceil(decimal::div(decimal::from(target_amount), ratio));
        if (decimal::floor(decimal::mul(decimal::from(candidate), ratio)) < target_amount) {
            candidate = candidate + 1;
        };
        candidate
    }

    /// Redeems enough cTokens to receive AT LEAST `target_amount` of T. The
    /// returned `Balance<T>` may be slightly larger than `target_amount` due to
    /// ratio rounding — caller is responsible for joining the surplus into the
    /// vault's idle balance.
    ///
    /// Aborts `EStrategyInsufficientCTokens` when the obligation holds fewer
    /// cTokens than the exact minimum. The former behaviour — clamp to the held
    /// balance and redeem whatever that yields — was removed with the M-04 fix:
    /// since `suilend_ctokens_for_target` now returns the exact minimum, holding
    /// less is genuine underfunding rather than a rounding artefact, and it
    /// deserves a distinct abort instead of falling through to
    /// `EStrategyShortDelivery`.
    ///
    /// Aborts for `T = SUI`: Suilend serves SUI out of a staker and the
    /// combined redemption helper has no unstake step. Use
    /// `withdraw_from_suilend_sui`.
    public(package) fun withdraw_from_suilend<P, T>(
        uid: &mut UID,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        target_amount: u64,
        ctx: &mut TxContext,
    ): Balance<T> {
        assert_suilend_not_sui<T>();
        assert_suilend_market<P>(uid, market);
        assert_suilend_coin_type<T>(uid);
        assert!(target_amount > 0, EZeroAmount);
        assert!(has_suilend_state(uid), ESuilendStateMissing);
        // Before the ratio math, so an unenrolled vault names the missing
        // activation step rather than falling through to the sufficiency check
        // and reporting `EStrategyInsufficientCTokens` — the un-enrolled state
        // has to stay loudly distinguishable from underfunding.
        assert!(has_suilend_obligation(uid), ESuilendObligationMissing);
        let reserve_index = *dynamic_field::borrow<vector<u8>, u64>(uid, KEY_SUILEND_RESERVE_INDEX);

        let ctoken_amount = suilend_ctokens_for_target<P, T>(market, clock, target_amount);
        // Pyth-free even though this sits under the user-facing instant-withdraw
        // path — see the invariant note above `open_suilend_obligation`.
        let ctokens = withdraw_obligation_ctokens<P, T>(
            uid,
            market,
            clock,
            reserve_index,
            ctoken_amount,
            ctx,
        );
        let received = lending_market::redeem_ctokens_and_withdraw_liquidity<P, T>(
            market,
            reserve_index,
            clock,
            ctokens,
            option::none(),
            ctx,
        );

        let received_bal = coin::into_balance(received);
        // Suilend may deliver slightly MORE than target_amount due to cToken-ratio
        // rounding (caller joins the surplus). Less than target_amount is a spec
        // violation — refuse to proceed so downstream callers (especially
        // ensure_liquidity_* on user-facing paths) don't transfer against a short.
        assert!(balance::value(&received_bal) >= target_amount, EStrategyShortDelivery);
        received_bal
    }

    /// SUI-specific counterpart of `withdraw_from_suilend`. Monomorphic on
    /// `SUI` because `lending_market::unstake_sui_from_staker` is SUI-only.
    ///
    /// Suilend stakes idle SUI reserve balance with validators, so the combined
    /// `redeem_ctokens_and_withdraw_liquidity` helper — which is exactly
    /// `request -> fulfill` — pays from a liquid balance that may be empty and
    /// aborts in `balance::split`. The protocol-native SUI path inserts an
    /// unstake between the two:
    ///
    /// ```text
    /// redeem_ctokens_and_withdraw_liquidity_request
    ///   -> unstake_sui_from_staker      (needs &mut SuiSystemState)
    ///   -> fulfill_liquidity_request
    /// ```
    ///
    /// `LiquidityRequest` is a hot potato with no abilities, so all three steps
    /// necessarily settle inside this call — there is no partial-state window.
    ///
    /// Same delivery contract as the generic variant: may return slightly more
    /// than `target_amount` (caller joins the surplus); less is a spec
    /// violation and aborts `EStrategyShortDelivery`.
    public(package) fun withdraw_from_suilend_sui<P>(
        uid: &mut UID,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        clock: &Clock,
        target_amount: u64,
        ctx: &mut TxContext,
    ): Balance<SUI> {
        assert_suilend_market<P>(uid, market);
        assert_suilend_coin_type<SUI>(uid);
        assert!(target_amount > 0, EZeroAmount);
        assert!(has_suilend_state(uid), ESuilendStateMissing);
        // Before the ratio math, so an unenrolled vault names the missing
        // activation step rather than falling through to the sufficiency check
        // and reporting `EStrategyInsufficientCTokens` — the un-enrolled state
        // has to stay loudly distinguishable from underfunding.
        assert!(has_suilend_obligation(uid), ESuilendObligationMissing);
        let reserve_index = *dynamic_field::borrow<vector<u8>, u64>(uid, KEY_SUILEND_RESERVE_INDEX);

        let ctoken_amount = suilend_ctokens_for_target<P, SUI>(market, clock, target_amount);
        let ctokens = withdraw_obligation_ctokens<P, SUI>(
            uid,
            market,
            clock,
            reserve_index,
            ctoken_amount,
            ctx,
        );

        let received_bal = redeem_suilend_ctokens_sui<P>(
            market,
            system_state,
            reserve_index,
            clock,
            coin::into_balance(ctokens),
            ctx,
        );
        assert!(balance::value(&received_bal) >= target_amount, EStrategyShortDelivery);
        received_bal
    }

    /// Runs Suilend's three-step SUI redemption over `ctokens` and returns the
    /// underlying. Shared by `withdraw_from_suilend_sui` and
    /// `clear_suilend_state_sui` so the step order lives in exactly one place.
    fun redeem_suilend_ctokens_sui<P>(
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        reserve_index: u64,
        clock: &Clock,
        ctokens: Balance<CToken<P, SUI>>,
        ctx: &mut TxContext,
    ): Balance<SUI> {
        let request = lending_market::redeem_ctokens_and_withdraw_liquidity_request<P, SUI>(
            market,
            reserve_index,
            clock,
            coin::from_balance(ctokens, ctx),
            option::none(),
            ctx,
        );
        // Tops the reserve's liquid balance back up from the staker. Upstream
        // is a no-op when the reserve's coin type is not SUI, so this is safe
        // even on a market whose SUI reserve holds nothing staked.
        lending_market::unstake_sui_from_staker<P>(
            market, reserve_index, &request, system_state, ctx,
        );
        let received = lending_market::fulfill_liquidity_request<P, SUI>(
            market, reserve_index, request, ctx,
        );
        coin::into_balance(received)
    }

    /// SUI-specific counterpart of `clear_suilend_state`. Same lifecycle and
    /// idempotence, but drains through the request -> unstake -> fulfill path
    /// so an emergency evacuation of a SUI vault cannot abort on staked
    /// reserve liquidity.
    public(package) fun clear_suilend_state_sui<P>(
        uid: &mut UID,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Balance<SUI> {
        assert_suilend_market<P>(uid, market);
        assert_suilend_coin_type<SUI>(uid);
        let mut drained = balance::zero<SUI>();

        let pulled = drain_suilend_obligation<P, SUI>(uid, market, clock, ctx);
        if (balance::value(&pulled) > 0) {
            let reserve_index = *dynamic_field::borrow<vector<u8>, u64>(
                uid, KEY_SUILEND_RESERVE_INDEX,
            );
            let received = redeem_suilend_ctokens_sui<P>(
                market, system_state, reserve_index, clock, pulled, ctx,
            );
            balance::join(&mut drained, received);
        } else {
            balance::destroy_zero(pulled);
        };

        remove_suilend_commitments(uid);
        drained
    }

    // === Suilend Reward Collection ===

    /// Claims one Suilend pool reward of coin type `RewardType` for the vault's
    /// obligation and returns it as a `Coin<RewardType>`.
    ///
    /// Suilend accounts rewards per `(reserve, reward slot, deposit-or-borrow)`
    /// triple, so a full sweep is one call per live triple — batch them in a
    /// single PTB. `reward_index` is a slot in the reserve's `pool_rewards`
    /// vector, which a Suilend admin can vacate, so it is resolved off chain per
    /// claim rather than stored. `is_deposit_reward` selects between the
    /// reserve's `deposits_` and `borrows_pool_reward_manager`; the vault only
    /// ever deposits, so it is always `true` today, but it is threaded through
    /// rather than hardcoded so the entry does not have to change if that ever
    /// stops being true.
    ///
    /// Does NOT consume the cap, so this can run while the strategy is live or
    /// immediately before `clear_suilend_state` discards it — after which
    /// unclaimed rewards are unreachable.
    ///
    /// No price refresh needed: `claim_rewards` gates only on bad debt, which a
    /// supply-only obligation cannot have.
    /// `RewardSourceType` names the reserve the reward accrues on, and is NOT
    /// always the vault's committed collateral.
    ///
    /// Q-02 follow-up. Secondary collateral sitting in the obligation — put
    /// there by Suilend's permissionless `claim_rewards_and_deposit` — earns
    /// rewards from ITS OWN reserve. This used to read the committed reserve
    /// index unconditionally, so those rewards were unclaimable, and since
    /// teardown discards the obligation cap they would have been lost at exit.
    /// The sweep order that recovers everything is: claim on each reserve that
    /// has accrued, then `withdraw_secondary_collateral` per foreign type, then
    /// exit.
    ///
    /// The index is derived from the type rather than passed raw, so a caller
    /// cannot name a reserve that does not match the reward they asked for.
    /// `reserve<P, RewardSourceType>` is probed for the same reason as in
    /// `assert_suilend_reserve_index`: `reserve_array_index` returns
    /// `reserves.length` for an absent type instead of aborting.
    public(package) fun claim_suilend_reward<P, RewardSourceType, RewardType>(
        uid: &UID,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        reward_index: u64,
        is_deposit_reward: bool,
        ctx: &mut TxContext,
    ): Coin<RewardType> {
        assert_suilend_market<P>(uid, market);
        // Enrolment first: a cheap local precondition should not sit behind an
        // external call, and it keeps the guard reachable in tests, where every
        // Suilend call is an `abort 0` stub.
        assert!(has_suilend_obligation(uid), ESuilendObligationMissing);
        let _ = lending_market::reserve<P, RewardSourceType>(market);
        let reserve_index = lending_market::reserve_array_index<P, RewardSourceType>(market);
        let cap = borrow_obligation_cap<P>(uid);
        lending_market::claim_rewards<P, RewardType>(
            market,
            cap,
            clock,
            reserve_index,
            reward_index,
            is_deposit_reward,
            ctx,
        )
    }

    // === View / Read Helpers ===

    // Suilend needs no internal supplied-value view. Withdrawals here are
    // denominated in cTokens and sized by `suilend_ctokens_for_target`, so
    // nothing in the package ever needed to read the position's underlying
    // value to clamp a pull.
    //
    // An off-chain reader CAN take `obligation_id` from
    // `SuilendObligationOpenedEvent` and read the obligation straight off the
    // Suilend market — but doing so means reimplementing Suilend's cToken math
    // off-chain, which silently drifts if the protocol changes how it values a
    // position.
    //
    // So the on-chain readout this note used to describe as hypothetical now
    // exists, in the shape it prescribed: `get_suilend_strategy_assets` on
    // `atomic_liquidity_vault`, taking
    // `&AtomicLiquidityVault<T>` alongside `get_strategy_kind`. The helpers
    // below stay package-visible and are reached through those.

    /// Underlying collateral the vault's SUILEND position is currently worth.
    ///
    /// Mirrors what the redemption path would deliver: cTokens held in the
    /// obligation, valued at `simulated_ctoken_ratio` (interest projected to
    /// `clock`), floored — the same direction Suilend rounds when it actually
    /// redeems, so this never claims more than a withdrawal would produce.
    ///
    /// Returns 0 when no obligation has been opened, matching
    /// `obligation_ctoken_amount`, so a vault that never enrolled stays
    /// readable.
    ///
    /// `T` must be the vault's committed Suilend coin type; passing another
    /// reads a different reserve and returns a value for a position this vault
    /// does not hold. Callers that cannot guarantee it should use
    /// `assert_suilend_coin_type` first, as the supply and withdraw paths do.
    public(package) fun get_suilend_supplied_value<P, T>(
        uid: &UID,
        market: &LendingMarket<P>,
        clock: &Clock,
    ): u64 {
        // No obligation means nothing is deployed, and a vault that never
        // enrolled has no commitment to check against — so this comes first and
        // keeps the view callable on any vault.
        if (!has_suilend_obligation(uid)) { return 0 };

        // Past that point the vault IS committed, so hold the caller to it. A
        // wrong same-`P` market would otherwise fall through to Suilend's own
        // obligation lookup and abort there, and a wrong `T` is worse still: it
        // reads a DIFFERENT reserve's ratio and returns a plausible number for a
        // position this vault does not hold. Same guards the supply and
        // withdraw paths use, for the same reason.
        assert_suilend_market<P>(uid, market);
        assert_suilend_coin_type<T>(uid);

        let ctokens = obligation_ctoken_amount<P, T>(uid, market);
        if (ctokens == 0) { return 0 };
        let r = lending_market::reserve<P, T>(market);
        let ratio = reserve::simulated_ctoken_ratio<P>(r, clock);
        decimal::floor(decimal::mul(decimal::from(ctokens), ratio))
    }

}
