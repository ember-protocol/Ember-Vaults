/*
  Copyright (c) 2026 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code
  requires prior written permission from the Ember Protocol Inc.
*/

/// Pure helpers shared across the Ember vault modules. This module deliberately
/// holds NO struct definitions and NO `&mut Vault<...>`-typed parameters: every
/// function takes primitives in and returns primitives (or aborts) so it can be
/// reused by both `ember_vaults::vault` and `ember_vaults::atomic_liquidity_vault`
/// without creating a module dependency cycle.
module ember_vaults::common {

    // === Imports ===

    use ember_vaults::math;

    // === Errors ===
    // Reserved range: 6000-6999.

    /// Caller passed `@0` as an account address.
    const EZeroAddress: u64 = 6000;
    /// Account being added to a list is already present.
    const EAlreadyExists: u64 = 6001;
    /// Account being removed from a list is not present.
    const ENotFound: u64 = 6002;
    /// A candidate role address collides with an existing privileged role on the
    /// vault (admin / operator / rate manager) or appears on the sub-account or
    /// blacklist vectors.
    const ERoleConflict: u64 = 6003;

    // === Constants ===

    /// Denominator for the annualized platform-fee math.
    /// Equals `1e9 (rate precision base) * 365 days * 24h * 60m * 60s * 1000ms`,
    /// so that `(tvl * fee_pct_1e9 * elapsed_ms) / FEE_DENOMINATOR` lands in the
    /// vault's collateral-decimal scale.
    const FEE_DENOMINATOR: u128 = 31_536_000_000_000_000_000;

    // === Public(package) Functions ===

    /// Returns `FEE_DENOMINATOR` as a `u128` so callers can compose their own math
    /// against the same constant without redeclaring it.
    public(package) fun fee_denominator(): u128 { FEE_DENOMINATOR }

    /// Computes the platform-fee delta accrued on `tvl` over `current_time -
    /// last_charged_at` ms at `fee_percentage` (1e9 = 100% / year).
    ///
    /// Returns `0` when no time has elapsed, the fee percentage is zero, or the
    /// vault is empty — callers are responsible for advancing `last_charged_at`
    /// in those cases (the original vault.move logic still bumps the timestamp
    /// when fee_percentage is zero so accrual restarts cleanly when a non-zero
    /// fee is later set).
    ///
    /// `tvl` is taken as `u128` so a TVL above `u64::MAX` (large, low-rate
    /// vault) does not abort here — this runs on every exit path and an abort
    /// would lock funds. The fee delta itself is expected to fit `u64` (it is a
    /// small fraction of TVL per accrual window and is added to the `u64`
    /// accrued-fee ledger); `math::safe_cast_to_u64` still aborts if it does
    /// not, which requires an astronomically larger TVL than the read overflow
    /// this widening removes.
    public(package) fun compute_platform_fee_delta(
        tvl: u128,
        fee_percentage: u64,
        last_charged_at: u64,
        current_time: u64,
    ): u64 {
        if (current_time <= last_charged_at || fee_percentage == 0 || tvl == 0) {
            return 0
        };
        let elapsed_time_ms = current_time - last_charged_at;
        // u256 intermediate: `tvl * fee_percentage * elapsed_ms` can overflow
        // u128 (tvl is itself u128) while the post-division fee still fits u64.
        // This helper runs on every exit path, so an overflow abort here would
        // lock funds and block administrative recovery.
        let numerator = (tvl as u256)
            * (fee_percentage as u256)
            * (elapsed_time_ms as u256);
        math::safe_cast_u256_to_u64(numerator / (FEE_DENOMINATOR as u256))
    }

    /// Adds (`status = true`) or removes (`status = false`) `account` from
    /// `accounts` enforcing list-membership invariants.
    ///
    /// Aborts:
    /// - `EZeroAddress` if `account == @0`
    /// - `EAlreadyExists` if `status == true` and `account` is already in the list
    /// - `ENotFound` if `status == false` and `account` is not in the list
    public(package) fun update_accounts(
        accounts: &mut vector<address>,
        account: address,
        status: bool,
    ) {
        assert!(account != @0, EZeroAddress);

        let (exists, index) = vector::index_of(accounts, &account);

        if (status) {
            assert!(!exists, EAlreadyExists);
            vector::push_back(accounts, account);
        } else {
            assert!(exists, ENotFound);
            vector::remove(accounts, index);
        };
    }

    /// Asserts that `candidate` is non-zero, distinct from each of the
    /// privileged role addresses, and not present on either the sub-account or
    /// blacklist vectors. Used when (re-)assigning admin / operator / rate
    /// manager — the same five-way check appears in multiple places in the live
    /// vault.move and is duplicated by the new atomic_liquidity_vault module.
    ///
    /// Pass `@0` for `rate_manager` if the vault has not yet set one (e.g. at
    /// initial create_vault time before update_vault_rate_manager is called).
    ///
    /// Aborts with `ERoleConflict` on any collision.
    public(package) fun assert_role_candidate_valid(
        candidate: address,
        admin: address,
        operator: address,
        rate_manager: address,
        sub_accounts: &vector<address>,
        blacklisted: &vector<address>,
    ) {
        assert!(
            candidate != @0
                && candidate != admin
                && candidate != operator
                && candidate != rate_manager
                && !vector::contains(sub_accounts, &candidate)
                && !vector::contains(blacklisted, &candidate),
            ERoleConflict,
        );
    }
}
