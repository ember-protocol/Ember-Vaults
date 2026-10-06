/*
  Copyright (c) 2025 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code 
  requires prior written permission from the Ember Protocol Inc.
*/

/// This gateway module has no logic baked into it and
/// just exposes entry methods that can be invoked from the client
module ember_vaults::gateway {

    use sui::balance;
    use sui::coin;

    use sui::coin::{TreasuryCap, Coin};
    use sui::clock::Clock;
    use sui::sui::SUI;
    use sui_system::sui_system::SuiSystemState;
    use std::string::String;

    use ember_vaults::vault::{Self,Vault};
    use ember_vaults::admin::{Self, AdminCap, ProtocolConfig};
    use ember_vaults::atomic_liquidity_vault::{Self, AtomicLiquidityVault};
    use sui::transfer::Receiving;

    use suilend::lending_market::LendingMarket;

    // === Errors ===
    const EDeprecatedFunctionUsage: u64 = 5000;

    // === ADMIN MODULE ENTRY FUNCTIONS ===

    entry fun increase_supported_package_version(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
    ) {
        admin::increase_supported_package_version(config, cap);
    }

    entry fun pause_non_admin_operations(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        status: bool
    ) {
        admin::pause_non_admin_operations(config, cap, status)
    }

    // === GUARDIAN ENTRY FUNCTIONS ===

    /// Sets or clears the guardian address. AdminCap-gated. Pass `@0x0`
    /// to unset — guardian-gated entry points then become unreachable.
    entry fun set_guardian(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        new_guardian: address,
    ) {
        admin::set_guardian(config, cap, new_guardian)
    }

    /// Guardian fast-path for `pause_non_admin_operations`.
    entry fun guardian_pause_non_admin_operations(
        config: &mut ProtocolConfig,
        status: bool,
        ctx: &TxContext,
    ) {
        admin::guardian_pause_non_admin_operations(config, status, ctx)
    }

    /// Guardian fast-path to pause / unpause a specific operation on a
    /// regular vault. `operation` is one of `b"deposits"`, `b"withdrawals"`,
    /// `b"privileged_operations"` — same vocabulary as the atomic-vault
    /// variant and EVM's `EmberProtocolConfig.setVaultPausedStatus`.
    entry fun guardian_set_vault_paused_status<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        operation: vector<u8>,
        paused: bool,
        ctx: &mut TxContext,
    ) {
        vault::guardian_set_vault_paused_status(vault, config, operation, paused, ctx)
    }

    /// Guardian fast-path to blacklist / unblacklist on a regular vault.
    entry fun guardian_set_blacklisted_account<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        account: address,
        status: bool,
        ctx: &TxContext,
    ) {
        vault::guardian_set_blacklisted_account(vault, config, account, status, ctx)
    }

    /// Guardian fast-path to pause a specific operation on an atomic
    /// liquidity vault. `operation` is one of `b"deposits"`, `b"withdrawals"`,
    /// `b"privileged_operations"`.
    entry fun atomic_guardian_set_pause_status<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        operation: vector<u8>,
        paused: bool,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::guardian_set_pause_status(vault, config, operation, paused, ctx)
    }

    /// Guardian fast-path to blacklist / unblacklist on an atomic liquidity vault.
    entry fun atomic_guardian_set_blacklisted_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        account: address,
        status: bool,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::guardian_set_blacklisted_account(vault, config, account, status, ctx)
    }

    entry fun update_platform_fee_recipient(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        recipient: address
    ) {
        admin::update_platform_fee_recipient(config, cap, recipient)
    }

    entry fun update_min_rate(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        min_rate: u64
    ) {
        admin::update_min_rate(config, cap, min_rate)
    }

    entry fun update_max_rate(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        max_rate: u64
    ) {
        admin::update_max_rate(config, cap, max_rate)
    }

    entry fun update_default_rate(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        default_rate: u64
    ) {
        admin::update_default_rate(config, cap, default_rate)
    }

    entry fun update_min_rate_interval(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        min_rate_interval: u64
    ) {
        admin::update_min_rate_interval(config, cap, min_rate_interval)
    }

    entry fun update_max_rate_interval(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        max_rate_interval: u64
    ) {
        admin::update_max_rate_interval(config, cap, max_rate_interval)
    }

    entry fun update_max_fee_percentage(
        config: &mut ProtocolConfig,
        cap: &admin::AdminCap,
        max_fee_percentage: u64
    ) {
        admin::update_max_fee_percentage(config, cap, max_fee_percentage)
    }

    entry fun update_vault_name<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        name: String,
        ctx: &mut TxContext
    ) {
        vault::update_vault_name(vault, config, name, ctx)
    }

    // === VAULT MODULE ENTRY FUNCTIONS ===

    // === PROTOCOL ADMIN FUNCTIONS ===

    entry fun create_vault<T, R>(
        config: &ProtocolConfig,
        receipt_token_treasury_cap: TreasuryCap<R>,
        cap: &admin::AdminCap,
        name: String,
        admin_addr: address,
        operator: address,
        max_allowed_rate_change: u64,
        fee_percentage: u64,
        min_withdrawal_shares: u64,
        rate_update_interval: u64,
        max_tvl: u64,
        sub_accounts: vector<address>,
        ctx: &mut TxContext
    ) {
        let vault = vault::create_vault<T, R>(
            config,
            receipt_token_treasury_cap,
            cap,
            name,
            admin_addr,
            operator,
            max_allowed_rate_change,
            fee_percentage,
            min_withdrawal_shares,
            rate_update_interval,
            max_tvl,
            sub_accounts,
            ctx
        );

        vault::share_vault(vault);
    }

    entry fun change_vault_admin<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        cap: &AdminCap,
        new_admin: address,
    ) {
        vault::change_vault_admin(vault, config, cap, new_admin);
    }

    // === VAULT ADMIN FUNCTIONS ===

    entry fun set_vault_paused_status<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        status: bool,
        ctx: &mut TxContext
    ) {
        vault::set_vault_paused_status(vault, config, status, ctx)
    }

    entry fun change_vault_operator<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        new_operator: address,
        ctx: &TxContext
    ) {
        vault::change_vault_operator(vault, config, new_operator, ctx);
    }

    entry fun change_vault_rate_manager<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        new_rate_manager: address,
        ctx: &TxContext
    ) {
        vault::update_vault_rate_manager(vault, config, new_rate_manager, ctx)
    }

    entry fun set_sub_account<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        sub_account: address,
        status: bool,
        ctx: &TxContext
    ) {
        vault::set_sub_account(vault, config, sub_account, status, ctx)
    }

    entry fun update_vault_fee_percentage<T, R>(
        _: &mut Vault<T, R>,
        _: &ProtocolConfig,
        _: u64,
        _: &TxContext
    ) {
        abort EDeprecatedFunctionUsage
    }

    entry fun update_vault_fee_percentage_v2<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        new_fee_percentage: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        vault::update_vault_fee_percentage_v2(vault, config, new_fee_percentage, clock, ctx)
    }

    entry fun set_min_withdrawal_shares<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        new_min_withdrawal_shares: u64,
        ctx: &TxContext
    ) {
        vault::set_min_withdrawal_shares(vault, config, new_min_withdrawal_shares, ctx)
    }

    entry fun change_vault_rate_update_interval<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        new_rate_update_interval: u64,
        ctx: &TxContext
    ) {
        vault::change_vault_rate_update_interval(vault, config, new_rate_update_interval, ctx)
    }


    // === VAULT OPERATOR FUNCTIONS ===

    entry fun set_blacklisted_account<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        account: address,
        status: bool,
        ctx: &TxContext
    ) {
        vault::set_blacklisted_account(vault, config, account, status, ctx)
    }

    entry fun update_vault_rate<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        new_rate: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        vault::update_vault_rate(vault, config, new_rate, clock, ctx)
    }

    entry fun deposit_to_vault_without_minting_shares<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        sub_account: address,
        coin: Coin<T>,
        ctx: &TxContext
    ) {
        let balance = coin::into_balance(coin);
        vault::deposit_to_vault_without_minting_shares(vault, config, balance, sub_account, ctx)
    }

    entry fun deposit_to_vault_without_minting_shares_v2<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        sub_account: address,
        token: Receiving<Coin<T>>,
        ctx: &TxContext
    ) {
        vault::deposit_to_vault_without_minting_shares_v2(vault, config, token, sub_account, ctx)
    }

    entry fun deposit_to_vault_without_minting_shares_v3<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        sub_account: address,
        amount: u64,
        ctx: &TxContext
    ) {
        vault::deposit_to_vault_without_minting_shares_v3(vault, config, amount, sub_account, ctx)
    }


    entry fun withdraw_from_vault_without_redeeming_shares<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        sub_account: address,
        amount: u64,
        ctx: &mut TxContext
    ) { 
        vault::withdraw_from_vault_without_redeeming_shares(vault, config, sub_account, amount, ctx)
    }

    entry fun process_withdrawal_requests<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        max_requests_to_process: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        vault::process_withdrawal_requests(vault, config, max_requests_to_process, clock, ctx)
    }

    entry fun process_withdrawal_requests_up_to_timestamp<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        vault::process_withdrawal_requests_up_to_timestamp(vault, config, timestamp, clock, ctx)
    }



    entry fun charge_platform_fee<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        vault::charge_platform_fee(vault, config, clock, ctx)
    }

    /// Deprecated — retained only for on-chain upgrade compatibility.
    /// Callers must switch to `collect_platform_fee_v2` which additionally
    /// takes `&Clock` so accrued fees are settled up to `now` before payout.
    entry fun collect_platform_fee<T, R>(
        _: &mut Vault<T, R>,
        _: &ProtocolConfig,
        _: &mut TxContext
    ) {
        abort EDeprecatedFunctionUsage
    }

    entry fun collect_platform_fee_v2<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        vault::collect_platform_fee_v2(vault, config, clock, ctx)
    }

    // === USER FUNCTIONS ===

    entry fun deposit_asset<T, R>(
        _: &mut Vault<T, R>,
        _: &ProtocolConfig,
        _: Coin<T>,
        _: &mut TxContext
    ){
        abort EDeprecatedFunctionUsage
    }

    entry fun deposit_asset_v2<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        coin: Coin<T>,
        min_shares: u64,
        receiver: Option<address>,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        let balance = coin::into_balance(coin);
        let receipt_token = vault::deposit_asset_v2(vault, config, balance, min_shares, clock, ctx);

        let send_to = if(option::is_some(&receiver)){
            *option::borrow(&receiver)
        } else {
            ctx.sender()
        };

        transfer::public_transfer(receipt_token, send_to);
    }

    entry fun mint_shares<T, R>(
        _: &mut Vault<T, R>,
        _: &ProtocolConfig,
        _: Coin<T>,
        _: u64,
        _: Option<address>,
        _: &mut TxContext
    ) {     
        abort EDeprecatedFunctionUsage
    }

    entry fun mint_shares_v2<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        assets: Coin<T>,
        shares: u64,
        max_amount: u64,
        receiver: Option<address>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {     
        let mut balance = coin::into_balance(assets);
        let receipt_token = vault::mint_shares_v2(vault, config, &mut balance, shares, max_amount, clock, ctx);

        let send_to = if(option::is_some(&receiver)){
            *option::borrow(&receiver)
        } else {
            ctx.sender()
        };

        if(balance::value(&balance) > 0){   
            transfer::public_transfer(coin::from_balance(balance, ctx), ctx.sender());
        } else{
            balance::destroy_zero(balance);
        };

        transfer::public_transfer(receipt_token, send_to);
    }

    entry fun redeem_shares<T, R>(
        clock: &Clock,
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        shares: Coin<R>,
        receiver: Option<address>,
        ctx: &mut TxContext
    ) {
        let balance = coin::into_balance(shares);

        let send_to = if(option::is_some(&receiver)){
            *option::borrow(&receiver)
        } else {
            ctx.sender()
        };

        vault::redeem_shares(vault, config,  balance, send_to, clock, ctx);

    }

    entry fun cancel_pending_withdrawal_request<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        sequence_number: u128,
        ctx: &mut TxContext
    ) {
        vault::cancel_pending_withdrawal_request(vault, config, sequence_number, ctx)
    }


    entry fun update_vault_max_tvl<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        max_tvl: u64,
        ctx: &TxContext
    ) {
        vault::update_vault_max_tvl(vault, config, max_tvl, ctx)
    }   


    entry fun update_vault_max_rate_change_per_update<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        max_rate_change_percentage: u64,
        ctx: &mut TxContext
    ) {
        vault::update_vault_max_rate_change_per_update(vault, config, max_rate_change_percentage, ctx)
    }

    entry fun set_deposit_user_list<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        user: address,
        status: bool,
        ctx: &mut TxContext
    ) {
        vault::set_deposit_user_list(vault, config, user, status, ctx)
    }

    entry fun set_fee_exemption_list<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        user: address,
        status: bool,
        ctx: &mut TxContext
    ) {
        vault::set_fee_exemption_list(vault, config, user, status, ctx)
    }

    entry fun set_permanent_fee_percentage<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        permanent_fee_percentage: u64,
        ctx: &mut TxContext
    ) {
        vault::set_permanent_fee_percentage(vault, config, permanent_fee_percentage, ctx)
    }

    entry fun set_time_based_fee_percentage<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        time_based_fee_percentage: u64,
        ctx: &mut TxContext
    ) {
        vault::set_time_based_fee_percentage(vault, config, time_based_fee_percentage, ctx)
    }

    entry fun set_time_based_fee_threshold<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        time_based_fee_threshold: u64,
        ctx: &mut TxContext
    ) {
        vault::set_time_based_fee_threshold(vault, config, time_based_fee_threshold, ctx)
    }


    // ===========================================================================
    // === Atomic Liquidity Vault Entry Functions                              ===
    // ===========================================================================
    //
    // All entries below are prefixed `atomic_*` to keep the gateway namespace
    // clear of vault.move's existing entries. The atomic_liquidity_vault
    // module's public functions are NOT entry-callable directly; PTB
    // submitters call these wrappers.

    // === Protocol Admin ===

    entry fun create_atomic_vault<T>(
        config: &ProtocolConfig,
        cap: &AdminCap,
        name: String,
        admin_addr: address,
        operator: address,
        rate_manager: address,
        max_rate_change_per_update: u64,
        fee_percentage: u64,
        min_withdrawal_shares: u64,
        rate_update_interval: u64,
        max_tvl: u64,
        sub_accounts: vector<address>,
        ctx: &mut TxContext,
    ) {
        let (vault, ticket) = atomic_liquidity_vault::create_atomic_liquidity_vault<T>(
            config, cap, name, admin_addr, operator, rate_manager,
            max_rate_change_per_update, fee_percentage, min_withdrawal_shares,
            rate_update_interval, max_tvl, sub_accounts, ctx,
        );
        atomic_liquidity_vault::share_atomic_vault(vault, ticket);
    }

    entry fun atomic_change_vault_admin<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        cap: &AdminCap,
        new_admin: address,
    ) {
        atomic_liquidity_vault::change_vault_admin(vault, config, cap, new_admin);
    }

    // === Vault Admin ===

    entry fun atomic_update_vault_name<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        name: String,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::update_vault_name(vault, config, name, ctx)
    }

    entry fun atomic_update_vault_max_tvl<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        max_tvl: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::update_vault_max_tvl(vault, config, max_tvl, ctx)
    }

    entry fun atomic_update_vault_max_rate_change_per_update<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        max_rate_change_per_update: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::update_vault_max_rate_change_per_update(
            vault, config, max_rate_change_per_update, ctx,
        )
    }

    entry fun atomic_change_vault_rate_update_interval<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        interval: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::change_vault_rate_update_interval(vault, config, interval, ctx)
    }

    entry fun atomic_change_vault_operator<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_operator: address,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::change_vault_operator(vault, config, new_operator, ctx)
    }

    entry fun atomic_update_vault_rate_manager<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_rate_manager: address,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::update_vault_rate_manager(vault, config, new_rate_manager, ctx)
    }

    entry fun atomic_update_vault_fee_percentage<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        fee_percentage: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::update_vault_fee_percentage(vault, config, fee_percentage, clock, ctx)
    }

    entry fun atomic_set_min_withdrawal_shares<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        min_withdrawal_shares: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_min_withdrawal_shares(vault, config, min_withdrawal_shares, ctx)
    }

    entry fun atomic_set_sub_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        account: address,
        status: bool,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_sub_account(vault, config, account, status, ctx)
    }

    entry fun atomic_set_pause_status<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        operation: vector<u8>,
        paused: bool,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_pause_status(vault, config, operation, paused, ctx)
    }

    entry fun atomic_set_max_instant_withdraw_shares<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_max: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_max_instant_withdraw_shares(vault, config, new_max, ctx)
    }

    entry fun atomic_set_instant_withdraw_fee_percentage<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_fee_percentage: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_instant_withdraw_fee_percentage(vault, config, new_fee_percentage, ctx)
    }

    entry fun atomic_set_ember_share_whitelist<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        whitelisted: bool,
        fee_percentage: u64,
        max_capacity_percentage: u64,
        holdback_percentage: u64,
        max_utilization_percentage: u64,
        min_swap_gross: u64,
        max_held_value_absolute: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_ember_share_whitelist(
            vault, config, share_vault_id, whitelisted,
            fee_percentage, max_capacity_percentage, holdback_percentage,
            max_utilization_percentage, min_swap_gross, max_held_value_absolute,
            ctx,
        )
    }

    entry fun atomic_set_ember_share_max_utilization<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        max_utilization_percentage: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_ember_share_max_utilization(
            vault, config, share_vault_id, max_utilization_percentage, ctx,
        )
    }

    entry fun atomic_set_ember_share_fee_multiplier_tier<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        threshold: u64,
        multiplier: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_ember_share_fee_multiplier_tier(
            vault, config, share_vault_id, threshold, multiplier, ctx,
        )
    }

    entry fun atomic_remove_ember_share_fee_multiplier_tier<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        threshold: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::remove_ember_share_fee_multiplier_tier(
            vault, config, share_vault_id, threshold, ctx,
        )
    }

    entry fun atomic_set_swap_waiver<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        account: address,
        fee_waived: bool,
        holdback_waived: bool,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_swap_waiver(vault, config, account, fee_waived, holdback_waived, ctx)
    }

    // === Withdrawal Fees (Admin / Operator) ===

    entry fun atomic_set_permanent_fee_percentage<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        permanent_fee_percentage: u64,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::set_permanent_fee_percentage(
            vault, config, permanent_fee_percentage, ctx,
        )
    }

    entry fun atomic_set_time_based_fee_percentage<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        time_based_fee_percentage: u64,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::set_time_based_fee_percentage(
            vault, config, time_based_fee_percentage, ctx,
        )
    }

    entry fun atomic_set_time_based_fee_threshold<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        time_based_fee_threshold: u64,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::set_time_based_fee_threshold(
            vault, config, time_based_fee_threshold, ctx,
        )
    }

    entry fun atomic_set_fee_exemption_list<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        user: address,
        status: bool,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::set_fee_exemption_list(vault, config, user, status, ctx)
    }

    // === Strategy Management (Vault Admin) ===

    /// Switches the vault from Suilend strategy to STRATEGY_NONE, auto-draining
    /// all held cTokens back into vault.balance in the same call.
    entry fun atomic_set_strategy_none_from_suilend<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::set_strategy_none_from_suilend<T, P>(
            vault, config, market, clock, ctx,
        )
    }

    /// SUI-vault variant of `atomic_set_strategy_none_from_suilend`. Threads
    /// `&mut SuiSystemState` for Suilend's `unstake_sui_from_staker`.
    entry fun atomic_set_strategy_none_from_suilend_sui<P>(
        vault: &mut AtomicLiquidityVault<SUI>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::set_strategy_none_from_suilend_sui<P>(
            vault, config, market, system_state, clock, ctx,
        )
    }

    entry fun atomic_set_strategy_suilend<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &LendingMarket<P>,
        reserve_array_index: u64,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_strategy_suilend<T, P>(vault, config, market, reserve_array_index, ctx)
    }

    /// Second half of Suilend activation: opens the obligation the supply is
    /// held in, which is what makes it eligible for Suilend's deposit-side
    /// liquidity mining. Must run after `atomic_set_strategy_suilend` and before
    /// the first supply. Callable by either the admin or the operator.
    entry fun atomic_open_suilend_obligation<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::open_suilend_obligation<T, P>(vault, config, market, ctx)
    }

    // === Vault Operator ===

    entry fun atomic_set_blacklisted_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        account: address,
        status: bool,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_blacklisted_account(vault, config, account, status, ctx)
    }

    entry fun atomic_set_deposit_user_list<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        user: address,
        status: bool,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::set_deposit_user_list(vault, config, user, status, ctx)
    }

    entry fun atomic_supply_to_sub_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        sub_account: address,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::supply_to_sub_account(vault, config, sub_account, amount, ctx)
    }

    entry fun atomic_deposit_from_sub_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        token: Receiving<Coin<T>>,
        sub_account: address,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::deposit_from_sub_account(vault, config, token, sub_account, ctx)
    }

    /// Argument order follows `atomic_deposit_from_sub_account` above — the
    /// funds source precedes `sub_account` — rather than the classic vault's
    /// `deposit_to_vault_without_minting_shares_v3`, which takes `sub_account`
    /// first.
    entry fun atomic_deposit_from_sub_account_v2<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        amount: u64,
        sub_account: address,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::deposit_from_sub_account_v2(vault, config, amount, sub_account, ctx)
    }

    entry fun atomic_collect_platform_fee<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        loss: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::collect_platform_fee(vault, config, loss, clock, ctx)
    }

    entry fun atomic_process_withdrawal_requests<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        max_requests: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::process_withdrawal_requests(vault, config, max_requests, clock, ctx)
    }

    entry fun atomic_process_withdrawal_requests_up_to_timestamp<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::process_withdrawal_requests_up_to_timestamp(
            vault, config, timestamp, clock, ctx,
        )
    }

    entry fun atomic_supply_to_suilend_strategy<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::supply_to_suilend_strategy<T, P>(
            vault, config, market, amount, clock, ctx,
        );
    }

    entry fun atomic_withdraw_from_suilend_strategy<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::withdraw_from_suilend_strategy<T, P>(
            vault, config, market, amount, clock, ctx,
        );
    }

    /// SUI-vault variant of `atomic_withdraw_from_suilend_strategy`. Threads
    /// `&mut SuiSystemState` for Suilend's `unstake_sui_from_staker`.
    entry fun atomic_withdraw_from_suilend_strategy_sui<P>(
        vault: &mut AtomicLiquidityVault<SUI>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::withdraw_from_suilend_strategy_sui<P>(
            vault, config, market, system_state, amount, clock, ctx,
        );
    }

    /// Admin OR operator claims one accrued Suilend pool reward of coin type
    /// `RewardType` and forwards it to a whitelisted vault sub-account
    /// (`EInvalidAccount` otherwise). Either trusted role, for the same reason
    ///
    /// Suilend accounts rewards per `(reserve, reward slot, deposit-or-borrow)`
    /// triple, so call once per triple — batch them in one PTB. Sweep EVERY
    /// occupied slot, not just the live campaign: ended campaigns keep their
    /// `UserReward` entries and stay claimable.
    ///
    /// `RewardSourceType` names the reserve the reward accrues on — the vault's
    /// collateral for the strategy position, but the foreign type's own reserve
    /// for rewards earned by secondary collateral sitting in the obligation.
    ///
    /// `reward_index` must be resolved off chain per claim and never cached.
    /// `add_pool_reward` fills the first vacant slot, so indices are reused, not
    /// merely vacated — a stale `(index, RewardType)` pair aborts on Suilend's
    /// `EInvalidType` rather than claiming the wrong token.
    ///
    /// Sweep before exiting the strategy, which discards the obligation cap and
    /// strands anything unclaimed.
    entry fun atomic_claim_suilend_strategy_reward<T, P, RewardSourceType, RewardType>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        sub_account: address,
        reward_index: u64,
        is_deposit_reward: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::claim_suilend_strategy_reward<T, P, RewardSourceType, RewardType>(
            vault, config, market, sub_account, reward_index, is_deposit_reward, clock, ctx,
        );
    }

    /// Drains a foreign collateral position from the vault's Suilend obligation
    /// and forwards it to a whitelisted sub-account.
    ///
    /// Needed because Suilend's `claim_rewards_and_deposit` is permissionless:
    /// anyone can deposit this vault's claimed rewards into its obligation as
    /// collateral in a type the vault never chose. Teardown refuses to discard
    /// the obligation cap while any deposit remains, so this is what keeps a
    /// third party from blocking the exit. Read the foreign types off the
    /// obligation's `deposits` vector and call once per type.
    entry fun atomic_withdraw_suilend_secondary_collateral<T, P, RewardType>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        sub_account: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::withdraw_suilend_secondary_collateral<T, P, RewardType>(
            vault, config, market, sub_account, clock, ctx,
        );
    }

    /// SUI variant of `atomic_withdraw_suilend_secondary_collateral`. Threads
    /// `&mut SuiSystemState` for Suilend's request -> unstake -> fulfill path,
    /// which the generic redemption lacks — it aborts once the reserve holds its
    /// SUI staked. Use this whenever the foreign position is SUI, regardless of
    /// the vault's own collateral type.
    entry fun atomic_withdraw_suilend_secondary_collateral_sui<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        sub_account: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::withdraw_suilend_secondary_collateral_sui<T, P>(
            vault, config, market, system_state, sub_account, clock, ctx,
        );
    }

    entry fun atomic_release_users_holdback<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        unwinding_percentage: u64,
        max_entries: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::release_users_holdback<T>(
            vault, config, share_vault_id, unwinding_percentage, max_entries, clock, ctx,
        );
    }

    entry fun atomic_redeem_collected_ember_shares<T, R>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &mut Vault<T, R>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::redeem_collected_ember_shares<T, R>(
            atomic, config, source_vault, amount, clock, ctx,
        )
    }

    entry fun atomic_claim_received_collateral<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        token: Receiving<Coin<T>>,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::claim_received_collateral(vault, config, token, ctx)
    }

    entry fun atomic_claim_returned_ember_shares<T, R>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &Vault<T, R>,
        token: Receiving<Coin<R>>,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::claim_returned_ember_shares<T, R>(
            vault, config, source_vault, token, ctx,
        )
    }

    // === Rate Manager ===

    entry fun atomic_update_vault_rate<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_rate: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::update_vault_rate(vault, config, new_rate, clock, ctx)
    }

    // === User-Callable ===

    entry fun atomic_deposit<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        coin: Coin<T>,
        min_shares: u64,
        receiver: Option<address>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let send_to = if (option::is_some(&receiver)) *option::borrow(&receiver) else ctx.sender();
        atomic_liquidity_vault::deposit(vault, config, coin, min_shares, send_to, clock, ctx);
    }

    entry fun atomic_redeem_shares<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        shares: u64,
        receiver: Option<address>,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let send_to = if (option::is_some(&receiver)) *option::borrow(&receiver) else ctx.sender();
        atomic_liquidity_vault::redeem_shares<T>(vault, config, shares, send_to, clock, ctx);
    }

    entry fun atomic_cancel_pending_withdrawal_request<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        sequence_number: u128,
        ctx: &TxContext,
    ) {
        atomic_liquidity_vault::cancel_pending_withdrawal_request(vault, config, sequence_number, ctx)
    }

    entry fun atomic_instant_withdraw<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        shares: u64,
        receiver: Option<address>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let send_to = if (option::is_some(&receiver)) *option::borrow(&receiver) else ctx.sender();
        atomic_liquidity_vault::instant_withdraw<T>(vault, config, shares, send_to, clock, ctx);
    }

    entry fun atomic_instant_withdraw_with_suilend<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        shares: u64,
        receiver: Option<address>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let send_to = if (option::is_some(&receiver)) *option::borrow(&receiver) else ctx.sender();
        atomic_liquidity_vault::instant_withdraw_with_suilend<T, P>(
            vault, config, market, shares, send_to, clock, ctx,
        );
    }

    /// SUI-vault variant of `atomic_instant_withdraw_with_suilend`. Threads
    /// `&mut SuiSystemState` for Suilend's `unstake_sui_from_staker` on the
    /// auto-pull path.
    entry fun atomic_instant_withdraw_with_suilend_sui<P>(
        vault: &mut AtomicLiquidityVault<SUI>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        shares: u64,
        receiver: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::instant_withdraw_with_suilend_sui<P>(
            vault, config, market, system_state, shares, receiver, clock, ctx,
        );
    }

    entry fun atomic_swap_ember_shares<T, R>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &Vault<T, R>,
        share_coin: Coin<R>,
        receiver: Option<address>,
        min_net_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let send_to = if (option::is_some(&receiver)) *option::borrow(&receiver) else ctx.sender();
        atomic_liquidity_vault::swap_ember_shares<T, R>(
            atomic, config, source_vault, share_coin, send_to, min_net_out, clock, ctx,
        );
    }

    entry fun atomic_swap_ember_shares_with_suilend<T, R, P>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &Vault<T, R>,
        market: &mut LendingMarket<P>,
        share_coin: Coin<R>,
        receiver: Option<address>,
        min_net_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let send_to = if (option::is_some(&receiver)) *option::borrow(&receiver) else ctx.sender();
        atomic_liquidity_vault::swap_ember_shares_with_suilend<T, R, P>(
            atomic, config, source_vault, market, share_coin, send_to, min_net_out, clock, ctx,
        );
    }

    /// SUI-vault variant of `atomic_swap_ember_shares_with_suilend`. Threads
    /// `&mut SuiSystemState` for Suilend's `unstake_sui_from_staker` on the
    /// auto-pull path.
    entry fun atomic_swap_ember_shares_with_suilend_sui<R, P>(
        atomic: &mut AtomicLiquidityVault<SUI>,
        config: &ProtocolConfig,
        source_vault: &Vault<SUI, R>,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        share_coin: Coin<R>,
        receiver: address,
        min_net_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        atomic_liquidity_vault::swap_ember_shares_with_suilend_sui<R, P>(
            atomic, config, source_vault, market, system_state, share_coin,
            receiver, min_net_out, clock, ctx,
        );
    }

}