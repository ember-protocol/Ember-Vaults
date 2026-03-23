/*
  Copyright (c) 2026 Ember Protocol Inc.
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
    use std::string::String;

    use ember_vaults::vault::{Self,Vault};
    use ember_vaults::admin::{Self, AdminCap, ProtocolConfig};
    use sui::transfer::Receiving;

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

    entry fun collect_platform_fee<T, R>(
        vault: &mut Vault<T, R>,
        config: &ProtocolConfig,
        ctx: &mut TxContext
    ) {
        vault::collect_platform_fee(vault, config, ctx)
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

}