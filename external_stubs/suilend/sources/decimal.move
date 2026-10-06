/// Stub of `suilend::decimal` — declares only the surface used by ember_vaults.
/// Bodies abort because real implementations live at the published Suilend
/// package address; these stubs exist purely so the Move type checker can
/// validate our cross-package calls at build time. Do NOT publish this stub.
module suilend::decimal {

    /// Stub bodies never execute: at runtime these calls dispatch to the real
    /// on-chain package. Named so an accidental local execution is legible
    /// rather than a bare `abort 0`.
    const EDeprecated: u64 = 0;

    public struct Decimal has copy, drop, store {
        value: u256,
    }

    public fun from(_v: u64): Decimal { abort EDeprecated }

    public fun mul(_a: Decimal, _b: Decimal): Decimal { abort EDeprecated }

    public fun div(_a: Decimal, _b: Decimal): Decimal { abort EDeprecated }

    public fun floor(_a: Decimal): u64 { abort EDeprecated }

    public fun ceil(_a: Decimal): u64 { abort EDeprecated }

    public fun to_scaled_val(_v: Decimal): u256 { abort EDeprecated }
}
