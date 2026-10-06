/*
  Copyright (c) 2026 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  Integration scenarios for the atomic vault's per-share utilization cap +
  fee multiplier curve. Walks the T0→T7 state-evolution example documented
  in ATOMIC_LIQUIDITY_VAULT.md against real source vaults (not mocks).

  Units: 1 = $1. Atomic vault and all 3 source vaults run with rate = 1e9
  (1:1 share-to-asset), fee = 0, holdback = 0 — so on-chain math matches
  the doc's example numbers exactly with no rounding drift.

  Scenarios covered:
    - scenario_walk_t0_through_t7      (happy path, success at every Tn)
    - scenario_t2_eacred_at_max_aborts (edge: max reached, new eACRED swap)
    - scenario_t3_insufficient_liquidity_aborts (edge: large swap, low USDC)
    - scenario_t7_eacred_over_max_aborts (edge: util drift after LP withdraw)
*/
#[test_only]
module ember_vaults::test_atomic_utilization_scenarios {

    use std::string;
    use sui::balance;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::test_scenario::{Self as ts, Scenario};

    use ember_vaults::admin::{Self, AdminCap, ProtocolConfig};
    use ember_vaults::atomic_liquidity_vault::{Self as al, AtomicLiquidityVault};
    use ember_vaults::vault::{Self, Vault};

    use ember_vaults::test_atomic_utils as au;
    use ember_vaults::test_utils::USDC;

    // === Receipt-token types — three distinct phantoms, one per source vault. ===
    public struct EEARN {}
    public struct ETHIRD {}
    public struct EACRED {}

    // === Actors ===
    fun lp(): address { @0xCAFE_BABE }
    fun user_a(): address { @0xA }
    fun user_b(): address { @0xB }
    fun liquidator(): address { @0xC }

    // === Constants ===
    /// $1 = 1 unit throughout. $1M = 1_000_000.
    const ONE_MILLION: u64 = 1_000_000;
    /// 1e9 = 100% in the protocol's fixed-point convention.
    const ONE_HUNDRED_PERCENT: u64 = 1_000_000_000;
    /// Single clock value used throughout each scenario — keeps platform-
    /// fee accrual at zero so on-chain math matches the doc's numbers.
    const CLOCK_T: u64 = 1_000_000_000_000;

    // === Helpers ===

    /// Build a clock at the fixed scenario time.
    fun clk(sc: &mut Scenario): Clock {
        let mut c = clock::create_for_testing(ts::ctx(sc));
        clock::set_for_testing(&mut c, CLOCK_T);
        c
    }

    /// Initialises the admin module ONCE, then sets the default rate and
    /// fee to 0 so the source vaults inherit zero fees. Mints the atomic
    /// vault via `au::create_vault` afterwards.
    fun initialize_with_zero_fee_atomic(sc: &mut Scenario) {
        ts::next_tx(sc, au::protocol_admin());
        admin::initialize_module(ts::ctx(sc));

        // Atomic vault — default rate, fee 0, max_tvl 100M so LP top-ups
        // never bump into the cap.
        ts::next_tx(sc, au::protocol_admin());
        let config = ts::take_shared<ProtocolConfig>(sc);
        let cap = ts::take_from_address<AdminCap>(sc, au::protocol_admin());
        let (vault_obj, ticket) = al::create_atomic_liquidity_vault<USDC>(
            &config,
            &cap,
            string::utf8(b"Atomic Vault"),
            au::protocol_admin(),
            au::bob(),
            au::alice(),
            50_000_000,
            0,                       // fee_percentage = 0
            1,
            86_400_000,
            100_000_000_000,        // max_tvl
            vector::empty(),
            ts::ctx(sc),
        );
        al::share_atomic_vault(vault_obj, ticket);
        ts::return_shared(config);
        ts::return_to_address(au::protocol_admin(), cap);
    }

    /// Spins up a source vault for receipt type `R` with admin = protocol
    /// admin, operator = bob, rate = 1e9, fee = 0, capacity = $100M.
    /// Returns the source vault's ID (looked up post-share).
    fun create_source_vault<R>(sc: &mut Scenario, name: vector<u8>): ID {
        let pa = au::protocol_admin();
        ts::next_tx(sc, pa);
        let treasury_cap = coin::create_treasury_cap_for_testing<R>(ts::ctx(sc));
        let config = ts::take_shared<ProtocolConfig>(sc);
        let cap = ts::take_from_address<AdminCap>(sc, pa);

        let vault_obj = vault::create_vault<USDC, R>(
            &config,
            treasury_cap,
            &cap,
            string::utf8(name),
            pa,            // admin
            au::bob(),     // operator
            50_000_000,
            0,             // fee_percentage
            1,             // min_withdrawal_shares
            86_400_000,
            100_000_000_000, // max_tvl
            vector::empty(),
            ts::ctx(sc),
        );
        let vid = vault::get_vault_id(&vault_obj);
        vault::share_vault(vault_obj);

        ts::return_shared(config);
        ts::return_to_address(pa, cap);
        vid
    }

    /// `user` deposits `amount` of USDC into source vault for type R,
    /// receives the resulting `Coin<R>` (transferred to `user`).
    fun deposit_into_source_vault<R>(sc: &mut Scenario, user: address, amount: u64) {
        ts::next_tx(sc, user);
        let mut source_vault = ts::take_shared<Vault<USDC, R>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        let c = clk(sc);

        let usdc_balance = balance::create_for_testing<USDC>(amount);
        let receipt = vault::deposit_asset_v2<USDC, R>(
            &mut source_vault, &config, usdc_balance, 0, &c, ts::ctx(sc),
        );
        // Hand the receipt to `user`.
        sui::transfer::public_transfer(receipt, user);

        clock::destroy_for_testing(c);
        ts::return_shared(source_vault);
        ts::return_shared(config);
    }

    /// Whitelists source vault `source_id` on the atomic vault with the
    /// given `max_utilization_percentage`. fee = 0, capacity = 100%, holdback = 0.
    fun whitelist_source(sc: &mut Scenario, source_id: ID, max_util_pct: u64) {
        let pa = au::protocol_admin();
        ts::next_tx(sc, pa);
        let mut atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        al::set_ember_share_whitelist<USDC>(
            &mut atomic, &config, source_id,
            true,
            0,                       // fee 0
            ONE_HUNDRED_PERCENT,     // capacity 100% (effectively disabled)
            0,                       // holdback 0
            max_util_pct,
            0,                       // min_swap_gross: dust floor disabled
            0,                       // max_held_value_absolute: absolute cap disabled
            ts::ctx(sc),
        );
        ts::return_shared(atomic);
        ts::return_shared(config);
    }

    /// `lp_address` deposits `amount` USDC into the atomic vault. Standard
    /// `al::deposit` flow.
    fun lp_deposit_into_atomic(sc: &mut Scenario, lp_address: address, amount: u64) {
        ts::next_tx(sc, lp_address);
        let mut atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        let c = clk(sc);

        let usdc = coin::from_balance(
            balance::create_for_testing<USDC>(amount),
            ts::ctx(sc),
        );
        al::deposit<USDC>(
            &mut atomic, &config, usdc, 0, lp_address, &c, ts::ctx(sc),
        );

        clock::destroy_for_testing(c);
        ts::return_shared(atomic);
        ts::return_shared(config);
    }

    /// `user` swaps `share_amount` of R for USDC on the atomic vault.
    /// Returns the gross collateral the swap moved (== share_amount since
    /// rate = 1e9 and fee/holdback = 0).
    fun user_swap<R>(
        sc: &mut Scenario,
        user: address,
        share_amount: u64,
    ): u64 {
        user_swap_min<R>(sc, user, share_amount, 0)
    }

    /// As `user_swap` but with an explicit `min_net_out` slippage floor.
    fun user_swap_min<R>(
        sc: &mut Scenario,
        user: address,
        share_amount: u64,
        min_net_out: u64,
    ): u64 {
        ts::next_tx(sc, user);
        let mut atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        let source_vault = ts::take_shared<Vault<USDC, R>>(sc);
        let mut user_coin = ts::take_from_address<Coin<R>>(sc, user);
        let c = clk(sc);

        let to_swap = coin::split(&mut user_coin, share_amount, ts::ctx(sc));
        al::swap_ember_shares<USDC, R>(
            &mut atomic, &config, &source_vault, to_swap,
            user, min_net_out, &c, ts::ctx(sc),
        );

        // Return any remainder back to user.
        ts::return_to_address(user, user_coin);
        clock::destroy_for_testing(c);
        ts::return_shared(atomic);
        ts::return_shared(config);
        ts::return_shared(source_vault);
        share_amount
    }

    /// Simulates "source vault processes the redemption and the
    /// collateral arrives at the atomic vault" in one tx. Calls
    /// `al::test_simulate_source_settlement<USDC, R>` which drops
    /// `share_amount` of held receipt-R and credits `share_amount` of
    /// USDC to the atomic vault's idle balance (rate is 1:1 in these
    /// scenarios, so the conversion is identity).
    ///
    /// The real 3-tx cross-vault flow (`redeem_collected_ember_shares`
    /// → `vault::process_withdrawal_requests` →
    /// `claim_received_collateral`) is covered by `test_atomic_liquidity_vault`
    /// smoke tests. Using a shortcut here keeps the integration walk
    /// inside the default `sui move test` gas budget.
    fun settle_source_withdrawal<R>(
        sc: &mut Scenario,
        source_id: ID,
        share_amount: u64,
    ) {
        ts::next_tx(sc, au::bob()); // any signer — helper doesn't auth-check
        let mut atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        al::test_simulate_source_settlement<USDC, R>(
            &mut atomic, source_id, share_amount, share_amount,
        );
        ts::return_shared(atomic);
    }

    /// LP redeems `shares` from the atomic vault, then operator processes
    /// one withdrawal request. Used for T7's $800k LP withdrawal.
    fun lp_withdraw_from_atomic(sc: &mut Scenario, lp_address: address, shares: u64) {
        // Redeem
        ts::next_tx(sc, lp_address);
        let mut atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        let c = clk(sc);
        al::redeem_shares<USDC>(
            &mut atomic, &config, shares, lp_address, &c, ts::ctx(sc),
        );
        clock::destroy_for_testing(c);
        ts::return_shared(atomic);
        ts::return_shared(config);

        // Process
        ts::next_tx(sc, au::bob()); // operator
        let mut atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        let c = clk(sc);
        al::process_withdrawal_requests<USDC>(
            &mut atomic, &config, 1, &c, ts::ctx(sc),
        );
        clock::destroy_for_testing(c);
        ts::return_shared(atomic);
        ts::return_shared(config);
    }

    /// Reads current utilization for source `source_id` of type R.
    fun read_utilization<R>(sc: &mut Scenario): u64 {
        ts::next_tx(sc, au::protocol_admin());
        let atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let source_vault = ts::take_shared<Vault<USDC, R>>(sc);
        let util = al::get_ember_share_utilization<USDC, R>(&atomic, &source_vault);
        ts::return_shared(atomic);
        ts::return_shared(source_vault);
        util
    }

    /// Test-only one-line: assert that `actual` equals `expected_pct` percent
    /// expressed in 1e9 fixed-point. `expected_pct` is in *whole-number*
    /// percent units (so `10` means 10%, encoded as 100_000_000).
    fun assert_util_eq(actual: u64, expected_whole_pct: u64, tag: u64) {
        let expected = expected_whole_pct * 10_000_000; // 10_000_000 == 1%
        assert!(actual == expected, tag);
    }

    /// Slightly looser equality for percentages with halves (e.g., 22.5%
    /// = 225_000_000). Allow 1 unit of rounding noise either side.
    fun assert_util_close(actual: u64, expected: u64, tag: u64) {
        let diff = if (actual > expected) actual - expected else expected - actual;
        assert!(diff <= 1, tag);
    }

    /// Builds a fresh scenario with the atomic vault, 3 source vaults, all
    /// whitelisted on the atomic with their max-utilization caps. Returns
    /// the source-vault IDs (used by edge-case tests that need to assert
    /// on a specific share).
    ///
    /// State after this returns:
    /// - Atomic vault: rate 1e9, fee 0, no LP deposit yet, max_tvl 100M.
    /// - Source eEARN: 100M-cap, $1M LP deposit by user_a → user_a holds 1M eEARN.
    /// - Source eTHIRD: 100M-cap, $1M LP deposit by user_b → user_b holds 1M eTHIRD.
    /// - Source eACRED: 100M-cap, $1M LP deposit by liquidator → liquidator holds 1M eACRED.
    ///   (Liquidator is used as eACRED-holder so the swap names align with the doc.)
    /// - Whitelists: eEARN max 60%, eTHIRD max 50%, eACRED max 20%.
    /// - LP deposit into atomic: $1M from `lp()` — matches "AL Vault has $1M".
    fun setup_scenario(sc: &mut Scenario): (ID, ID, ID) {
        initialize_with_zero_fee_atomic(sc);
        let eearn_id = create_source_vault<EEARN>(sc, b"eEARN");
        let ethird_id = create_source_vault<ETHIRD>(sc, b"eTHIRD");
        let eacred_id = create_source_vault<EACRED>(sc, b"eACRED");

        // Seed users with R coins (real source-vault deposits — source-side
        // total_shares becomes 1M each so the per-share `max_capacity_percentage`
        // check doesn't bite during swaps).
        deposit_into_source_vault<EEARN>(sc, user_a(), ONE_MILLION);
        deposit_into_source_vault<ETHIRD>(sc, user_b(), ONE_MILLION);
        deposit_into_source_vault<EACRED>(sc, liquidator(), ONE_MILLION);

        whitelist_source(sc, eearn_id, 600_000_000);   // 60%
        whitelist_source(sc, ethird_id, 500_000_000);  // 50%
        whitelist_source(sc, eacred_id, 200_000_000);  // 20%

        // Starting condition: AL vault holds $1M of USDC.
        lp_deposit_into_atomic(sc, lp(), ONE_MILLION);

        (eearn_id, ethird_id, eacred_id)
    }

    // ============================================================
    // === T0 → T7 happy-path walk ================================
    // ============================================================

    #[test]
    fun scenario_walk_t0_through_t7() {
        let mut sc = ts::begin(au::protocol_admin());
        let (eearn_id, _ethird_id, _eacred_id) = setup_scenario(&mut sc);

        // ---- T0: everything in USDC, no swaps yet --------------
        assert_util_eq(read_utilization<EEARN>(&mut sc), 0, 0);
        assert_util_eq(read_utilization<ETHIRD>(&mut sc), 0, 1);
        assert_util_eq(read_utilization<EACRED>(&mut sc), 0, 2);

        // ---- T1: user_a swaps $200k eEARN, liquidator swaps $100k eACRED ----
        // After: AL holds $700k USDC, $200k eEARN, $100k eACRED. TVL = $1M.
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        assert_util_eq(read_utilization<EEARN>(&mut sc), 20, 3);
        assert_util_eq(read_utilization<ETHIRD>(&mut sc), 0, 4);
        assert_util_eq(read_utilization<EACRED>(&mut sc), 10, 5);

        // ---- T2: more swaps — $200k eEARN, $100k eACRED ---------
        // After: AL holds $400k USDC, $400k eEARN, $200k eACRED. TVL = $1M.
        // eEARN util 40%, eACRED util 20% (at max).
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        assert_util_eq(read_utilization<EEARN>(&mut sc), 40, 6);
        assert_util_eq(read_utilization<EACRED>(&mut sc), 20, 7);

        // ---- T4: First $200k eEARN withdrawal processed -----------
        // After: AL holds $600k USDC, $200k eEARN.
        settle_source_withdrawal<EEARN>(&mut sc, eearn_id, 200_000);
        assert_util_eq(read_utilization<EEARN>(&mut sc), 20, 8);
        assert_util_eq(read_utilization<EACRED>(&mut sc), 20, 9);

        // ---- T5: LP deposits another $1M into AL vault ----------
        // TVL = $2M, USDC balance = $1.6M, eEARN $200k (10%), eACRED $200k (10%).
        lp_deposit_into_atomic(&mut sc, lp(), ONE_MILLION);
        assert_util_eq(read_utilization<EEARN>(&mut sc), 10, 10);
        assert_util_eq(read_utilization<ETHIRD>(&mut sc), 0, 11);
        assert_util_eq(read_utilization<EACRED>(&mut sc), 10, 12);

        // ---- T6: Liquidator swaps $450k eTHIRD + $100k more eEARN + $100k more eACRED ----
        // Final held: $300k eEARN, $450k eTHIRD, $300k eACRED. USDC = 1.6M-450k-100k-100k = $950k.
        // TVL still = $2M.
        // Utilizations: eEARN 15%, eTHIRD 22.5%, eACRED 15%.
        let _ = user_swap<ETHIRD>(&mut sc, user_b(), 450_000);
        let _ = user_swap<EEARN>(&mut sc, user_a(), 100_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        assert_util_eq(read_utilization<EEARN>(&mut sc), 15, 13);
        // 22.5% = 225_000_000 in 1e9 fixed-point.
        assert_util_close(read_utilization<ETHIRD>(&mut sc), 225_000_000, 14);
        assert_util_eq(read_utilization<EACRED>(&mut sc), 15, 15);

        // ---- T7 (edge case): LPs redeem $800k ---------------------
        // After: TVL = $1.2M. Holdings unchanged. USDC down to $150k.
        // Utilizations spike: eEARN 25%, eTHIRD 37.5%, eACRED 25%.
        // (eACRED's 25% > 20% max — fresh swaps for eACRED will abort,
        // tested separately in scenario_t7_eacred_over_max_aborts.)
        lp_withdraw_from_atomic(&mut sc, lp(), 800_000);
        assert_util_eq(read_utilization<EEARN>(&mut sc), 25, 16);
        assert_util_close(read_utilization<ETHIRD>(&mut sc), 375_000_000, 17);
        assert_util_eq(read_utilization<EACRED>(&mut sc), 25, 18);

        ts::end(sc);
    }

    // ============================================================
    // === Edge cases =============================================
    // ============================================================

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EEmberShareUtilizationCapExceeded)]
    fun scenario_t2_eacred_at_max_aborts() {
        // Walks to T2 state (eACRED at 20% cap), then attempts another
        // eACRED swap of any size — should abort with the utilization-cap
        // error because POST-swap util would exceed 20%.
        let mut sc = ts::begin(au::protocol_admin());
        let (_, _, _) = setup_scenario(&mut sc);

        // T1
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        // T2
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        // Now eACRED is at exactly 20% (the cap). One more unit of swap
        // pushes us over → abort.
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 1);

        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInsufficientBalance)]
    fun scenario_t3_insufficient_liquidity_aborts() {
        // At T2 state the AL vault holds only $400k USDC. A $450k eTHIRD
        // swap would PASS the utilization check (eTHIRD util goes 0% →
        // 45%, below the 50% max) but FAIL because there isn't enough
        // idle USDC for the immediate payout.
        let mut sc = ts::begin(au::protocol_admin());
        let (_, _, _) = setup_scenario(&mut sc);

        // Walk to T2
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        // Vault now has $400k USDC. Attempt $450k eTHIRD swap → abort.
        let _ = user_swap<ETHIRD>(&mut sc, user_b(), 450_000);

        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EEmberShareUtilizationCapExceeded)]
    fun scenario_t7_eacred_over_max_aborts() {
        // After T7's LP withdrawal, eACRED is at 25% (above its 20% max).
        // Any new eACRED swap should abort even though there's idle USDC
        // available — the utilization cap is the gate.
        let mut sc = ts::begin(au::protocol_admin());
        let (eearn_id, _, _) = setup_scenario(&mut sc);

        // Walk to T6 state
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);
        settle_source_withdrawal<EEARN>(&mut sc, eearn_id, 200_000);
        lp_deposit_into_atomic(&mut sc, lp(), ONE_MILLION);
        let _ = user_swap<ETHIRD>(&mut sc, user_b(), 450_000);
        let _ = user_swap<EEARN>(&mut sc, user_a(), 100_000);
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 100_000);

        // T7
        lp_withdraw_from_atomic(&mut sc, lp(), 800_000);
        // eACRED util now at 25% — over its 20% cap. New swap aborts.
        let _ = user_swap<EACRED>(&mut sc, liquidator(), 1);

        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::ESlippageToleranceExceeded)]
    /// A-9: the swap slippage guard aborts when the immediate payout is below
    /// `min_net_out`. Fee/holdback are 0 and rate is 1e9 here, so a 200k swap
    /// yields exactly 200k immediate collateral — demanding 200_001 must abort.
    fun swap_slippage_guard_aborts_below_min_net_out() {
        let mut sc = ts::begin(au::protocol_admin());
        let (_, _, _) = setup_scenario(&mut sc);
        let _ = user_swap_min<EEARN>(&mut sc, user_a(), 200_000, 200_001);
        ts::end(sc);
    }

    #[test]
    /// The guard is satisfied when the payout exactly meets `min_net_out`.
    fun swap_meets_exact_min_net_out() {
        let mut sc = ts::begin(au::protocol_admin());
        let (_, _, _) = setup_scenario(&mut sc);
        let _ = user_swap_min<EEARN>(&mut sc, user_a(), 200_000, 200_000);
        assert_util_eq(read_utilization<EEARN>(&mut sc), 20, 0);
        ts::end(sc);
    }

    #[test]
    /// A-12: redeeming twice at the SAME source must not abort — the per-source
    /// redemption cache guards its `vec_set::insert` against duplicates (a
    /// source can be redeemed at repeatedly). Also exercises the utilization
    /// read against a NON-empty cache (the `vec_set::contains` branch), which
    /// the redemption-free scenario walks never hit.
    fun redeem_twice_same_source_ok() {
        let mut sc = ts::begin(au::protocol_admin());
        let (_eearn_id, _, _) = setup_scenario(&mut sc);

        // Collect 200k eEARN shares into the atomic vault via a swap.
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);

        // Operator redeems collected eEARN shares twice (same source) — the
        // second call would abort on a duplicate vec_set::insert if unguarded.
        ts::next_tx(&mut sc, au::bob());
        let mut atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = ts::take_shared<ProtocolConfig>(&sc);
        let mut eearn = ts::take_shared<Vault<USDC, EEARN>>(&sc);
        let c = clk(&mut sc);
        al::redeem_collected_ember_shares<USDC, EEARN>(
            &mut atomic, &config, &mut eearn, 100_000, &c, ts::ctx(&mut sc),
        );
        al::redeem_collected_ember_shares<USDC, EEARN>(
            &mut atomic, &config, &mut eearn, 50_000, &c, ts::ctx(&mut sc),
        );
        clock::destroy_for_testing(c);
        ts::return_shared(atomic);
        ts::return_shared(config);
        ts::return_shared(eearn);

        // Utilization read now traverses the non-empty cache without error.
        let _ = read_utilization<EEARN>(&mut sc);
        ts::end(sc);
    }

    // ============================================================
    // === OtterSec audit regressions =============================
    // ============================================================

    /// Installs `guardian` as the protocol guardian (AdminCap-gated).
    fun set_protocol_guardian(sc: &mut Scenario, guardian: address) {
        let pa = au::protocol_admin();
        ts::next_tx(sc, pa);
        let mut config = ts::take_shared<ProtocolConfig>(sc);
        let cap = ts::take_from_address<AdminCap>(sc, pa);
        admin::set_guardian(&mut config, &cap, guardian);
        ts::return_to_address(pa, cap);
        ts::return_shared(config);
    }

    /// Guardian pauses ONE operation on source vault `R`, leaving the legacy
    /// whole-vault `paused` bit untouched.
    fun guardian_pause_source_op<R>(sc: &mut Scenario, guardian: address, op: vector<u8>) {
        ts::next_tx(sc, guardian);
        let mut source_vault = ts::take_shared<Vault<USDC, R>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        vault::guardian_set_vault_paused_status<USDC, R>(
            &mut source_vault, &config, op, true, ts::ctx(sc),
        );
        ts::return_shared(source_vault);
        ts::return_shared(config);
    }

    /// Reads `preview_swap_ember_shares` for source `R`.
    fun read_preview<R>(sc: &mut Scenario, share_amount: u64, owner: address): u64 {
        ts::next_tx(sc, au::protocol_admin());
        let atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let source_vault = ts::take_shared<Vault<USDC, R>>(sc);
        let out = al::preview_swap_ember_shares<USDC, R>(
            &atomic, &source_vault, share_amount, owner,
        );
        ts::return_shared(atomic);
        ts::return_shared(source_vault);
        out
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::ESourceVaultWithdrawalsPaused)]
    /// M-02: a WITHDRAWALS-ONLY source pause must block the swap. The legacy
    /// `paused` bit stays false, so the old `get_vault_paused` check let the
    /// swap through and handed the atomic vault receipts it could not redeem.
    fun swap_aborts_when_source_withdrawals_only_paused() {
        let mut sc = ts::begin(au::protocol_admin());
        let (_, _, _) = setup_scenario(&mut sc);

        set_protocol_guardian(&mut sc, au::charlie());
        guardian_pause_source_op<EEARN>(&mut sc, au::charlie(), b"withdrawals");

        // Legacy bit is still false — only the granular flag is set.
        ts::next_tx(&mut sc, au::protocol_admin());
        let source_vault = ts::take_shared<Vault<USDC, EEARN>>(&sc);
        assert!(!vault::get_vault_paused(&source_vault), 0);
        assert!(vault::is_withdrawals_paused(&source_vault), 1);
        ts::return_shared(source_vault);

        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        ts::end(sc);
    }

    #[test]
    /// M-02: the preview must mirror the core's source-exit guard so callers
    /// don't pull strategy liquidity for a swap that will abort.
    fun preview_zero_when_source_withdrawals_paused() {
        let mut sc = ts::begin(au::protocol_admin());
        let (_, _, _) = setup_scenario(&mut sc);

        assert!(read_preview<EEARN>(&mut sc, 200_000, user_a()) == 200_000, 0);

        set_protocol_guardian(&mut sc, au::charlie());
        guardian_pause_source_op<EEARN>(&mut sc, au::charlie(), b"withdrawals");

        assert!(read_preview<EEARN>(&mut sc, 200_000, user_a()) == 0, 1);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EEmberShareUtilizationCapExceeded)]
    /// L-03: a 0% utilization cap is a hard stop, not "unlimited". Floor
    /// division used to round a small exposure down to 0 utilization, which
    /// passed `new_utilization <= 0`.
    fun swap_aborts_when_utilization_cap_is_zero() {
        let mut sc = ts::begin(au::protocol_admin());
        let (eearn_id, _, _) = setup_scenario(&mut sc);

        // Atomic TVL must exceed 1e9 so `math::div(1, tvl)` floors to 0 —
        // otherwise utilization is positive and the old `<= 0` check already
        // rejected, and the test would not exercise the zero-cap stop.
        lp_deposit_into_atomic(&mut sc, lp(), 2_000_000_000);
        assert!(read_utilization<EEARN>(&mut sc) == 0, 0);

        whitelist_source(&mut sc, eearn_id, 0); // 0% cap
        // Pre-fix: util floors to 0 and `0 <= 0` passed, so this swap settled.
        let _ = user_swap<EEARN>(&mut sc, user_a(), 1);
        ts::end(sc);
    }

    #[test]
    /// L-03: the preview mirrors the zero-cap hard stop.
    fun preview_zero_when_utilization_cap_is_zero() {
        let mut sc = ts::begin(au::protocol_admin());
        let (eearn_id, _, _) = setup_scenario(&mut sc);

        lp_deposit_into_atomic(&mut sc, lp(), 2_000_000_000);
        // With a positive cap the 1-unit swap previews at face value.
        assert!(read_preview<EEARN>(&mut sc, 1, user_a()) == 1, 0);

        whitelist_source(&mut sc, eearn_id, 0);
        assert!(read_preview<EEARN>(&mut sc, 1, user_a()) == 0, 1);
        ts::end(sc);
    }

    // ============================================================
    // === L-04 half 2: aggregate-then-convert exposure ===========
    // ============================================================

    /// Points the source vault's rate manager at `alice` and moves the rate to
    /// `new_rate`. A non-1e9 rate is what makes share->collateral conversion
    /// lossy, which is the precondition for the double-floor gap.
    fun set_source_rate<R>(sc: &mut Scenario, new_rate: u64) {
        let pa = au::protocol_admin();
        ts::next_tx(sc, pa);
        let mut source = ts::take_shared<Vault<USDC, R>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        vault::update_vault_rate_manager<USDC, R>(
            &mut source, &config, au::alice(), ts::ctx(sc),
        );
        ts::return_shared(source);
        ts::return_shared(config);

        ts::next_tx(sc, au::alice());
        let mut source = ts::take_shared<Vault<USDC, R>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        let c = clk(sc);
        vault::update_vault_rate<USDC, R>(&mut source, &config, new_rate, &c, ts::ctx(sc));
        clock::destroy_for_testing(c);
        ts::return_shared(source);
        ts::return_shared(config);
    }

    /// Re-whitelists `source_id` with an explicit absolute held-value cap.
    fun whitelist_source_with_abs_cap(
        sc: &mut Scenario, source_id: ID, max_util_pct: u64, abs_cap: u64,
    ) {
        let pa = au::protocol_admin();
        ts::next_tx(sc, pa);
        let mut atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = ts::take_shared<ProtocolConfig>(sc);
        al::set_ember_share_whitelist<USDC>(
            &mut atomic, &config, source_id,
            true, 0, ONE_HUNDRED_PERCENT, 0, max_util_pct, 0, abs_cap, ts::ctx(sc),
        );
        ts::return_shared(atomic);
        ts::return_shared(config);
    }

    /// Drives the L-04 boundary: source rate 1.05e9, 101 shares already
    /// custodied, 2 shares incoming.
    ///
    ///   separate floors : floor(101/1.05) + floor(2/1.05) = 96 + 1 = 97
    ///   aggregated      : floor(103/1.05)                 =        98
    ///
    /// With an absolute cap of 97 the separate-floor figure passes and the
    /// true aggregate does not.
    fun drive_l04_boundary(sc: &mut Scenario, eearn_id: ID) {
        set_source_rate<EEARN>(sc, 1_050_000_000);
        let _ = user_swap<EEARN>(sc, user_a(), 101);
        whitelist_source_with_abs_cap(sc, eearn_id, 600_000_000, 97);
    }

    #[test]
    /// L-04 half 2: the preview must reject the swap the core will reject.
    /// Pre-fix it reported a viable payout because the two conversions were
    /// floored independently and summed to exactly the cap.
    fun preview_rejects_swap_that_exceeds_cap_only_when_aggregated() {
        let mut sc = ts::begin(au::protocol_admin());
        let (eearn_id, _, _) = setup_scenario(&mut sc);
        drive_l04_boundary(&mut sc, eearn_id);

        assert!(read_preview<EEARN>(&mut sc, 2, user_a()) == 0, 0);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EEmberShareHeldValueCapExceeded)]
    /// L-04 half 2: and the core itself must reject it. `floor(a/r) +
    /// floor(b/r) <= floor((a+b)/r)`, so summing separate conversions let a
    /// swap commit one collateral base unit more exposure than the cap allows.
    fun swap_rejected_when_aggregate_exposure_exceeds_cap() {
        let mut sc = ts::begin(au::protocol_admin());
        let (eearn_id, _, _) = setup_scenario(&mut sc);
        drive_l04_boundary(&mut sc, eearn_id);

        let _ = user_swap<EEARN>(&mut sc, user_a(), 2);
        ts::end(sc);
    }

    // ============================================================
    // === I-07: one action sequence per swap entry ===============
    // ============================================================

    /// Reads the atomic vault's current action sequence.
    fun read_sequence(sc: &mut Scenario): u128 {
        ts::next_tx(sc, au::protocol_admin());
        let atomic = ts::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let seq = al::get_vault_sequence_number(&atomic);
        ts::return_shared(atomic);
        seq
    }

    #[test]
    /// I-07: a swap entry function reserves EXACTLY ONE action sequence.
    ///
    /// The sequence is now reserved by the entry (after charging fees) and
    /// handed down to `do_swap_ember_shares_core`, which no longer bumps. That
    /// is what lets a strategy wrapper's `ensure_liquidity_*` child event carry
    /// the same sequence as the parent `EmberShareSwappedEvent` — the child is
    /// emitted before the core runs, so a core-side bump put it one behind.
    ///
    /// This pins the convention: if a bump is ever re-added to the core, the
    /// delta becomes 2 and this fails. The clock is fixed in these scenarios so
    /// `charge_accrued_platform_fees` returns early and contributes no bump of
    /// its own.
    fun swap_entry_reserves_exactly_one_sequence() {
        let mut sc = ts::begin(au::protocol_admin());
        let (_, _, _) = setup_scenario(&mut sc);

        let before = read_sequence(&mut sc);
        let _ = user_swap<EEARN>(&mut sc, user_a(), 200_000);
        let after = read_sequence(&mut sc);

        assert!(after == before + 1, 0);
        ts::end(sc);
    }
}
