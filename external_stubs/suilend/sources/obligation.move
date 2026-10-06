/// Stub of `suilend::obligation` — declares only the public types and
/// functions used by ember_vaults. Real implementations live at the published
/// Suilend package address. Do NOT publish this stub.
module suilend::obligation {

    /// Stub bodies never execute: at runtime these calls dispatch to the real
    /// on-chain package. Named so an accidental local execution is legible
    /// rather than a bare `abort 0`.
    const EDeprecated: u64 = 0;

    /// A lending position inside a `LendingMarket<P>`. Lives in the market's
    /// `ObjectTable`, never owned directly — every mutation is authorised by an
    /// `ObligationOwnerCap<P>`, which is why the vault stores that cap rather
    /// than the obligation itself.
    public struct Obligation<phantom P> has key, store {
        id: UID,
    }

    /// One collateral position inside an `Obligation`, keyed by coin type.
    public struct Deposit has store {
        dummy: bool,
    }

    /// cTokens of coin type `T` currently deposited in this obligation.
    /// Returns 0 when the obligation holds no deposit for `T`.
    public fun deposited_ctoken_amount<P, T>(_obligation: &Obligation<P>): u64 { abort EDeprecated }

    /// Every collateral position, regardless of coin type. Needed because
    /// `deposited_ctoken_amount` answers only for a type the caller already
    /// knows, and Suilend's permissionless `claim_rewards_and_deposit` can add a
    /// position in a type the vault never chose.
    public fun deposits<P>(_obligation: &Obligation<P>): &vector<Deposit> { abort EDeprecated }

    public fun deposit_coin_type(_deposit: &Deposit): std::type_name::TypeName { abort EDeprecated }

    public fun deposit_deposited_ctoken_amount(_deposit: &Deposit): u64 { abort EDeprecated }
}
