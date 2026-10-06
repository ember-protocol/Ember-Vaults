/// Stub of `suilend::lending_market` — declares only the public surface used
/// by ember_vaults. Real implementations live at the published Suilend package
/// address. Do NOT publish this stub.
module suilend::lending_market {

    /// Stub bodies never execute: at runtime these calls dispatch to the real
    /// on-chain package. Named so an accidental local execution is legible
    /// rather than a bare `abort 0`.
    const EDeprecated: u64 = 0;

    use sui::clock::Clock;
    use sui::coin::Coin;
    use sui::sui::SUI;
    use sui_system::sui_system::SuiSystemState;

    use suilend::reserve::{Reserve, CToken, LiquidityRequest};
    use suilend::obligation::Obligation;

    public struct LendingMarket<phantom P> has key, store {
        id: UID,
    }

    /// Optional rate-limiter bypass passed to redemption. We always supply
    /// `option::none::<RateLimiterExemption<P, T>>()` because the atomic vault
    /// never holds an exemption.
    public struct RateLimiterExemption<phantom P, phantom T> has drop {}

    /// Authorises every mutation of one `Obligation<P>`. Issued once by
    /// `create_obligation` and held by the vault as a dynamic field — losing it
    /// makes the obligation permanently unreachable, so the teardown path
    /// asserts the obligation is empty before discarding it.
    public struct ObligationOwnerCap<phantom P> has key, store {
        id: UID,
    }

    public fun deposit_liquidity_and_mint_ctokens<P, T>(
        _lending_market: &mut LendingMarket<P>,
        _reserve_array_index: u64,
        _clock: &Clock,
        _deposit: Coin<T>,
        _ctx: &mut TxContext,
    ): Coin<CToken<P, T>> { abort EDeprecated }

    public fun redeem_ctokens_and_withdraw_liquidity<P, T>(
        _lending_market: &mut LendingMarket<P>,
        _reserve_array_index: u64,
        _clock: &Clock,
        _ctokens: Coin<CToken<P, T>>,
        _rate_limiter_exemption: Option<RateLimiterExemption<P, T>>,
        _ctx: &mut TxContext,
    ): Coin<T> { abort EDeprecated }

    /// Step 1 of the split redemption path. `redeem_ctokens_and_withdraw_-
    /// liquidity` is exactly this plus `fulfill_liquidity_request`, with no
    /// unstake step — which is why `T = SUI` must use the split form.
    public fun redeem_ctokens_and_withdraw_liquidity_request<P, T>(
        _lending_market: &mut LendingMarket<P>,
        _reserve_array_index: u64,
        _clock: &Clock,
        _ctokens: Coin<CToken<P, T>>,
        _rate_limiter_exemption: Option<RateLimiterExemption<P, T>>,
        _ctx: &mut TxContext,
    ): LiquidityRequest<P, T> { abort EDeprecated }

    /// Step 2, SUI only. Unstakes enough SUI from the reserve's staker to
    /// cover `_liquidity_request` so step 3 can pay from liquid balance.
    /// No-op upstream when the reserve's coin type is not SUI.
    public fun unstake_sui_from_staker<P>(
        _lending_market: &mut LendingMarket<P>,
        _sui_reserve_array_index: u64,
        _liquidity_request: &LiquidityRequest<P, SUI>,
        _system_state: &mut SuiSystemState,
        _ctx: &mut TxContext,
    ) { abort EDeprecated }

    /// Step 3. Consumes the hot potato and pays out of the reserve's liquid
    /// balance. Aborts in `balance::split` if step 2 was skipped for a staked
    /// SUI reserve.
    public fun fulfill_liquidity_request<P, T>(
        _lending_market: &mut LendingMarket<P>,
        _reserve_array_index: u64,
        _liquidity_request: LiquidityRequest<P, T>,
        _ctx: &mut TxContext,
    ): Coin<T> { abort EDeprecated }

    /// Opens a fresh obligation inside `_lending_market` and returns the only
    /// capability that can act on it.
    public fun create_obligation<P>(
        _lending_market: &mut LendingMarket<P>,
        _ctx: &mut TxContext,
    ): ObligationOwnerCap<P> { abort EDeprecated }

    /// Moves cTokens from a free-floating `Coin` into the obligation. This is
    /// the step that enrols the deposit in the reserve's
    /// `deposits_pool_reward_manager` — raw cTokens accrue base interest only.
    ///
    /// Upstream asserts nothing about oracle freshness: adding collateral
    /// cannot worsen obligation health.
    public fun deposit_ctokens_into_obligation<P, T>(
        _lending_market: &mut LendingMarket<P>,
        _reserve_array_index: u64,
        _obligation_owner_cap: &ObligationOwnerCap<P>,
        _clock: &Clock,
        _deposit: Coin<CToken<P, T>>,
        _ctx: &mut TxContext,
    ) { abort EDeprecated }

    /// Pulls cTokens back out of the obligation. Takes NO `PriceInfoObject`:
    /// upstream calls `obligation::refresh` itself and passes the resulting
    /// stale-oracle signal into `obligation::withdraw`, which discards it
    /// without asserting when the obligation has no borrows. A supply-only
    /// obligation therefore needs no `refresh_reserve_price` leg in the PTB.
    ///
    /// `_amount` is in cTokens. Passing `u64::MAX` routes upstream through
    /// `max_withdraw_amount`, which clamps to the market rate limiter — ember
    /// always passes an explicit amount so that clamp is never hit.
    public fun withdraw_ctokens<P, T>(
        _lending_market: &mut LendingMarket<P>,
        _reserve_array_index: u64,
        _obligation_owner_cap: &ObligationOwnerCap<P>,
        _clock: &Clock,
        _amount: u64,
        _ctx: &mut TxContext,
    ): Coin<CToken<P, T>> { abort EDeprecated }

    /// Claims one pool reward for the obligation. Accounting is per
    /// `(reserve, reward slot, deposit-or-borrow)` triple, so a full sweep is
    /// one call per live triple. `_reward_index` is a slot in the reserve's
    /// `pool_rewards` vector and can be vacated by a Suilend admin, so it is
    /// resolved off-chain per claim.
    ///
    /// Upstream gates only on bad debt (`deposited_value >= borrowed_value`),
    /// trivially satisfied by a supply-only obligation. No oracle dependency.
    public fun claim_rewards<P, RewardType>(
        _lending_market: &mut LendingMarket<P>,
        _cap: &ObligationOwnerCap<P>,
        _clock: &Clock,
        _reserve_id: u64,
        _reward_index: u64,
        _is_deposit_reward: bool,
        _ctx: &mut TxContext,
    ): Coin<RewardType> { abort EDeprecated }

    public fun obligation_id<P>(_cap: &ObligationOwnerCap<P>): ID { abort EDeprecated }

    public fun obligation<P>(
        _lending_market: &LendingMarket<P>,
        _obligation_id: ID,
    ): &Obligation<P> { abort EDeprecated }

    public fun reserve_array_index<P, T>(_lending_market: &LendingMarket<P>): u64 { abort EDeprecated }

    public fun reserve<P, T>(_lending_market: &LendingMarket<P>): &Reserve<P> { abort EDeprecated }

    /// Test-only constructor. The stub's function bodies all abort, so a
    /// `LendingMarket<P>` value is useless for exercising Suilend logic — but
    /// it lets ember_vaults unit-test the market-identity commitments it stores
    /// at strategy activation (I-11), which are pure Ember-side checks.
    #[test_only]
    public fun new_for_testing<P>(ctx: &mut TxContext): LendingMarket<P> {
        LendingMarket<P> { id: object::new(ctx) }
    }

    #[test_only]
    public fun destroy_for_testing<P>(market: LendingMarket<P>) {
        let LendingMarket { id } = market;
        object::delete(id);
    }
}
