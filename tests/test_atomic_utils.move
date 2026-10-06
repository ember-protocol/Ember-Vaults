/*
  Copyright (c) 2026 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  Test-only helpers for `atomic_liquidity_vault`. Mirrors `test_utils.move`
  but for the no-receipt-token vault flavour.
*/
#[test_only]
module ember_vaults::test_atomic_utils {

    use sui::test_scenario::{Self, Scenario};
    use sui::coin;
    use sui::balance;
    use sui::clock;
    use std::string;

    use ember_vaults::admin::{Self, AdminCap, ProtocolConfig};
    use ember_vaults::atomic_liquidity_vault::{Self, AtomicLiquidityVault};
    use ember_vaults::test_utils::{Self, USDC};

    // === Constants ===

    public fun protocol_admin(): address { test_utils::protocol_admin() }
    public fun bob(): address { test_utils::bob() }
    public fun alice(): address { test_utils::alice() }
    public fun charlie(): address { test_utils::charlie() }

    // === Lifecycle ===

    /// Initializes the admin module + creates a default atomic vault. Mirrors
    /// `test_utils::initialize` but for `AtomicLiquidityVault<USDC>`.
    public fun initialize(scenario: &mut Scenario) {
        let pa = protocol_admin();
        test_scenario::next_tx(scenario, pa);
        admin::initialize_module(test_scenario::ctx(scenario));
        create_vault(scenario);
    }

    /// Creates a default-config atomic vault under USDC. admin = protocol_admin,
    /// operator = bob, rate_manager = alice.
    public fun create_vault(scenario: &mut Scenario) {
        let pa = protocol_admin();
        test_scenario::next_tx(scenario, pa);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        let cap = test_scenario::take_from_address<AdminCap>(scenario, pa);

        let (vault, ticket) = atomic_liquidity_vault::create_atomic_liquidity_vault<USDC>(
            &config,
            &cap,
            string::utf8(b"Atomic Vault"),
            pa,         // admin
            bob(),      // operator
            alice(),    // rate manager
            50_000_000, // max_rate_change_per_update = 5%
            1_000_000,  // fee_percentage = 0.01%
            1,          // min_withdrawal_shares
            86_400_000, // rate_update_interval = 1 day
            1_000_000_000_000, // max_tvl
            vector::empty(), // sub_accounts
            test_scenario::ctx(scenario),
        );
        atomic_liquidity_vault::share_atomic_vault(vault, ticket);

        test_scenario::return_shared(config);
        test_scenario::return_to_address(pa, cap);
    }

    /// Deposits `amount` of fabricated USDC for `user` into the vault.
    /// Returns the shares minted.
    public fun deposit_at_time(
        scenario: &mut Scenario,
        user: address,
        amount: u64,
        clock_time: u64,
    ): u64 {
        test_scenario::next_tx(scenario, user);
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);

        let mut clk = clock::create_for_testing(test_scenario::ctx(scenario));
        clock::set_for_testing(&mut clk, clock_time);

        let coin = coin::from_balance(
            balance::create_for_testing<USDC>(amount),
            test_scenario::ctx(scenario),
        );
        let minted = atomic_liquidity_vault::deposit<USDC>(
            &mut vault,
            &config,
            coin,
            0, // min_shares (no slippage)
            user,
            &clk,
            test_scenario::ctx(scenario),
        );

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        minted
    }

    public fun deposit(scenario: &mut Scenario, user: address, amount: u64): u64 {
        deposit_at_time(scenario, user, amount, 10_000_000_000)
    }

    /// Deposit where the tx sender (`from`) and share recipient (`to`) differ,
    /// at a chosen clock time. Used to exercise custodial / griefing flows.
    public fun deposit_from_to_at_time(
        scenario: &mut Scenario,
        from: address,
        to: address,
        amount: u64,
        clock_time: u64,
    ): u64 {
        test_scenario::next_tx(scenario, from);
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);

        let mut clk = clock::create_for_testing(test_scenario::ctx(scenario));
        clock::set_for_testing(&mut clk, clock_time);

        let coin = coin::from_balance(
            balance::create_for_testing<USDC>(amount),
            test_scenario::ctx(scenario),
        );
        let minted = atomic_liquidity_vault::deposit<USDC>(
            &mut vault, &config, coin, 0, to, &clk, test_scenario::ctx(scenario),
        );

        clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        minted
    }

    /// Inflates the vault's idle balance (test-only) so liquidity-dependent
    /// flows can be exercised without going through the strategy.
    public fun fund_vault_balance(scenario: &mut Scenario, amount: u64) {
        test_scenario::next_tx(scenario, protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(scenario);
        atomic_liquidity_vault::test_fund_balance<USDC>(&mut vault, amount);
        test_scenario::return_shared(vault);
    }

    // === Admin shortcuts used by tests ===

    public fun set_max_instant_withdraw_shares(scenario: &mut Scenario, new_max: u64) {
        test_scenario::next_tx(scenario, protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        atomic_liquidity_vault::set_max_instant_withdraw_shares(
            &mut vault, &config, new_max, test_scenario::ctx(scenario),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    public fun set_instant_withdraw_fee(scenario: &mut Scenario, fee_pct: u64) {
        test_scenario::next_tx(scenario, protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        atomic_liquidity_vault::set_instant_withdraw_fee_percentage(
            &mut vault, &config, fee_pct, test_scenario::ctx(scenario),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    public fun set_pause(scenario: &mut Scenario, op: vector<u8>, paused: bool) {
        test_scenario::next_tx(scenario, protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        atomic_liquidity_vault::set_pause_status(
            &mut vault, &config, op, paused, test_scenario::ctx(scenario),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    public fun blacklist(scenario: &mut Scenario, account: address, status: bool) {
        test_scenario::next_tx(scenario, bob()); // operator
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        atomic_liquidity_vault::set_blacklisted_account(
            &mut vault, &config, account, status, test_scenario::ctx(scenario),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }
}
