/// Stub of `suilend::reserve` — declares only the public types and functions
/// used by ember_vaults. Real implementations live at the published Suilend
/// package address. Do NOT publish this stub.
module suilend::reserve {

    /// Stub bodies never execute: at runtime these calls dispatch to the real
    /// on-chain package. Named so an accidental local execution is legible
    /// rather than a bare `abort 0`.
    const EDeprecated: u64 = 0;

    use sui::clock::Clock;

    use suilend::decimal::Decimal;

    public struct Reserve<phantom P> has key, store {
        id: UID,
    }

    /// Suilend's cToken — issued on supply, redeemed for the underlying T.
    /// Has only `drop`; held inside a `Coin<CToken<P, T>>` / `Balance<...>`.
    public struct CToken<phantom P, phantom T> has drop {}

    /// Hot potato produced by `lending_market::redeem_ctokens_and_withdraw_-
    /// liquidity_request` and consumed by `fulfill_liquidity_request`. No
    /// abilities, so it must be settled inside the same transaction. For
    /// `T = SUI` the reserve may hold its balance staked, so
    /// `lending_market::unstake_sui_from_staker` has to run against this
    /// request (by reference) before it can be fulfilled.
    public struct LiquidityRequest<phantom P, phantom T> {
        amount: u64,
        fee: u64,
    }

    /// Tokens-per-cToken ratio (always >= 1).
    public fun ctoken_ratio<P>(_reserve: &Reserve<P>): Decimal { abort EDeprecated }

    /// Same as ctoken_ratio but projects accrued interest forward to `clock`.
    public fun simulated_ctoken_ratio<P>(_reserve: &Reserve<P>, _clock: &Clock): Decimal {
        abort EDeprecated
    }
}
