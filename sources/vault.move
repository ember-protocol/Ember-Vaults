/*
  Copyright (c) 2026 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code 
  requires prior written permission from the Ember Protocol Inc.
*/

#[allow(lint(prefer_mut_tx_context))]
module ember_vaults::vault {

    // === Imports ===
    use ember_vaults::events;
    use ember_vaults::math;

    use std::string::String;
    use sui::transfer::Receiving;


    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::coin::{Self, TreasuryCap, Coin};
    use sui::clock::{Self, Clock};
    use ember_vaults::admin::{Self, AdminCap, ProtocolConfig};
    use ember_vaults::queue::{Self, Queue};
    use sui::dynamic_field;
    

    // === Errors ===

    const EInvalidPermission: u64 = 2000;
    const EInvalidAccount: u64 = 2001;
    const EInvalidRate: u64 = 2002;
    const EInvalidFeePercentage: u64 = 2003;
    const EZeroAmount: u64 = 2004;
    const EInvalidStatus: u64 = 2005;
    const EVaultPaused: u64 = 2006;
    const EInsufficientBalance: u64 = 2007;
    const EBlacklistedAccount: u64 = 2008;
    const EInsufficientShares: u64 = 2009;
    const EInvalidInterval: u64 = 2010;
    const EInvalidAmount: u64 = 2011;
    const EInvalidRequest: u64 = 2012;
    const EUserDoesNotHaveAccount: u64 = 2013;
    const ESameValue: u64 = 2014;
    const EAlreadyExists: u64 = 2015;
    const EMaxTVLReached: u64 = 2016;
    const EReceiptTokenTreasuryCapNotEmpty: u64 = 2017;
    const ESubAccount: u64 = 2018;
    const EDeprecatedFunctionUsage: u64 = 2019;
    const ESlippageToleranceExceeded: u64 = 2020;
    // === Constants ===

    #[allow(unused_const)]
    const ONE_DAY_MS: u64 = 24 * 60 * 60 * 1000; // 24 hours

    const FEE_DENOMINATOR: u128 = 31_536_000_000_000_000_000; // 1e9 * 365 days * 24 hours * 60 minutes * 60 seconds * 1000 milliseconds
    const RATE_MANGER_DYNAMIC_FIELD: vector<u8> = b"rate_manager";

    // === Structs ===

    /// Represents a withdrawal request
    public struct WithdrawalRequest has copy, drop, store {
        owner: address, 
        // the address of the receiver that will get the withdrawal amount
        receiver: address, 
        // the number of shares to redeem
        shares: u64, 
        // the estimated amount of assets user will receive after withdrawal
        estimated_withdraw_amount: u64,
        // the time at which withdrawal request was made
        timestamp: u64, 
        // this is the sequencer number of the vault at the time of requesting withdrawal
        sequence_number: u128 
    }

    /// Represents the platform fee accrued on the vault
    public struct PlatformFee has copy, drop, store {
        // the amount of platform fee accrued on the vault
        accrued: u64,
        // timestamp (ms) at which the platform fee was last charged
        last_charged_at: u64,
    }

    /// Represents the rate of the vault
    public struct Rate has copy, drop, store {
        // the rate of the vault (1e9)
        value: u64,
        // the max allowed change in rate per update
        max_rate_change_per_update: u64,
        // the time interval that must elapse before rate can be updated (ms)
        rate_update_interval: u64,
        // the last time the rate was updated (ms)
        last_updated_at: u64,
    }

    /// Represents an account in the vault. The struct is only created when a 
    /// user requests a withdrawal and is removed when the withdrawal is processed.
    public struct Account has copy, drop, store {
        // the amount of shares that the account has pending for withdrawal
        total_pending_withdrawal_shares: u64,
        // The sequencer numbers of the withdrawal requests that the account has made and are pending processing
        // @Dev if a user makes too many requests, the vector will grow and will eventually hit its max size.
        // That will cause a denial of service attack as user won't be able to cancel their requests.
        // The user will need to wait for vault operator to process their already pending requests before they
        // can request more withdrawals.
        pending_withdrawal_requests: vector<WithdrawalRequest>,
        // The sequencer numbers of the withdrawal requests that the account has cancelled
        cancel_withdraw_request: vector<u128>,
    }

    /// Represents an ember Vault
    public struct Vault<phantom T, phantom R> has key {
        // Unique id of the vault
        id: UID, 
        // Name of the vault (can be removed)
        name: String,
        // admin of the vault, can perform privileged operations like setting vault operator or adding/removing supported assets etc.
        admin: address,         
        // The vault operator, can perform operations like depositing/withdrawing assets, setting vault rate etc.
        operator: address,
        // the list of accounts blacklisted to perform any action on the vault
        blacklisted: vector<address>,
        // true if withdrawals, deposits and claims are paused
        paused: bool,        
        // the queue contains pending withdrawals that are yet not claimed by users
        pending_withdrawals: Queue<WithdrawalRequest>,
        // the table contains the accounts in the vault that have pending withdrawals
        accounts: Table<address,Account>, 
        // pending shares to burn upon processing withdrawal request
        pending_shares_to_burn: Balance<R>,
        // this is the list of accounts to which funds can be withdrawn from the vault and sent to by operator
        sub_accounts: vector<address>,
        // the rate of the vault
        rate: Rate,  
        // the fee percentage to be charged on the vault (annually)
        fee_percentage: u64,
        // the balance of the vault asset
        balance: Balance<T>,
        // the platform fee
        fee: PlatformFee,
        // the minimum amount of shares that can be withdrawn from the vault
        min_withdrawal_shares: u64,
        // the maximum TVL that the vault can hold
        max_tvl: u64,
        // treasury cap for the receipt token
        receipt_token_treasury_cap: TreasuryCap<R>,
        // an ever increasing number that is used to track the actions performed on the vault
        sequence_number: u128,
    }


    // === Public Functions ===
    
    /// Creates a new vault
    ///
    /// Parameters:
    /// - config: The protocol config
    /// - treasury_cap: The treasury cap for the receipt token
    /// - _: The admin capability
    /// - name: The name of the vault
    /// - admin: The admin of the vault
    /// - operator: The operator of the vault
    /// - max_rate_change_per_update: The max allowed change in rate per update
    /// - fee_percentage: The fee percentage to be charged on the vault (annually)
    /// - min_withdrawal_shares: The minimum amount of shares that can be withdrawn from the vault
    /// - max_tvl: The maximum TVL that the vault can hold. This is in the same decimals as the deposit asset.
    /// - sub_accounts: The sub accounts of the vault
    /// 
    /// Aborts with:
    /// - EInvalidAccount: If the admin or operator is the zero address or the same as the current admin.
    /// - EInvalidInterval: If the rate update interval is not within the allowed range.
    /// - EInvalidAmount: If the minimum withdrawal shares is not greater than 0.
    /// - EReceiptTokenTreasuryCapNotEmpty: If the receipt token treasury cap is not empty.
    /// - EInvalidFeePercentage: If the fee percentage is greater than the max allowed fee percentage.
    public fun create_vault<T,R>(
        config: &ProtocolConfig,
        treasury_cap: TreasuryCap<R>,
        _: &AdminCap,
        name: String,
        admin: address,
        operator: address,
        max_rate_change_per_update: u64,
        fee_percentage: u64,
        min_withdrawal_shares: u64,
        rate_update_interval: u64,
        max_tvl: u64,
        sub_accounts: vector<address>,
        ctx: &mut TxContext
    ): Vault<T,R> {

        admin::verify_supported_package(config);

        assert!(rate_update_interval >= admin::get_min_rate_interval(config) && rate_update_interval <= admin::get_max_rate_interval(config), EInvalidInterval);
        assert!(min_withdrawal_shares > 0, EInvalidAmount);
        assert!(coin::total_supply<R>(&treasury_cap) == 0, EReceiptTokenTreasuryCapNotEmpty);
        assert!(
            admin != @0 && 
            operator != @0 && 
            admin != operator &&
            !vector::contains(&sub_accounts, &admin) &&
            !vector::contains(&sub_accounts, &operator),
            EInvalidAccount
        );
        assert!(fee_percentage <= admin::get_max_allowed_fee_percentage(config), EInvalidFeePercentage);

        let id = object::new(ctx);
        let rate = Rate {
            value: admin::get_default_rate(config),
            max_rate_change_per_update,
            rate_update_interval,
            last_updated_at: 0
        };
       
        let vault = Vault { 
            id,
            name,
            admin,
            operator,
            blacklisted: vector::empty(),
            paused: false,
            pending_withdrawals: queue::new<WithdrawalRequest>(ctx),
            accounts: table::new<address, Account>(ctx),
            sub_accounts,
            rate,
            fee_percentage,
            fee: PlatformFee { accrued: 0, last_charged_at: 0 },
            balance: balance::zero<T>(),
            pending_shares_to_burn: balance::zero<R>(),
            receipt_token_treasury_cap: treasury_cap,
            sequence_number: 0,
            min_withdrawal_shares,
            max_tvl
        };

        let vault_id = object::uid_to_inner(&vault.id);

        events::emit_vault_created_event<T, R>( vault_id, name, admin, operator, sub_accounts, min_withdrawal_shares, fee_percentage, max_rate_change_per_update, rate_update_interval, rate.value, max_tvl);

        vault
    }



    /// Shares the vault publicly
    ///
    /// Parameters:
    /// - vault: The vault to share
    public fun share_vault<T,R>(vault: Vault<T,R>){
        transfer::share_object(vault);
    }

    /// Sets the address of the vault rate manager
    /// 
    /// Parameters:
    /// - vault: The vault to set the rate manager of
    /// - config: The protocol config
    /// - rate_manager: The new rate manager
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - ESameValue: If the rate manager is the same as the current rate manager.
    public fun update_vault_rate_manager<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, rate_manager: address, ctx: &TxContext){
        admin::verify_supported_package(config);

        assert!(ctx.sender() == vault.admin, EInvalidPermission);

        if(!dynamic_field::exists_(&vault.id, RATE_MANGER_DYNAMIC_FIELD)){
            dynamic_field::add<vector<u8>, address>(&mut vault.id, RATE_MANGER_DYNAMIC_FIELD, @0);
        };

        let manager = dynamic_field::borrow_mut<vector<u8>, address>(&mut vault.id, RATE_MANGER_DYNAMIC_FIELD);
        let previous_manager = *manager;

        assert!(previous_manager != rate_manager, ESameValue);
        assert!(
            rate_manager != @0 &&
            rate_manager != previous_manager &&
            rate_manager != vault.admin &&
            rate_manager != vault.operator &&
            !vector::contains(&vault.sub_accounts, &rate_manager) &&
            !vector::contains(&vault.blacklisted, &rate_manager), EInvalidAccount);

        *manager = rate_manager;

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        let vault_id = object::uid_to_inner(&vault.id);

        events::emit_vault_rate_manager_updated_event(vault_id, previous_manager, rate_manager, vault.sequence_number);
    }

    /// Updates the max TVL of the vault
    /// @dev only the vault admin can update the max TVL of the vault
    /// Parameters:
    /// - vault: The vault to update
    /// - config: The protocol config
    /// - max_tvl: The new max TVL
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - EInvalidAmount: If the max TVL is not greater than 0.
    /// - ESameValue: If the max TVL is the same as the current max TVL.
    /// - EMaxTVLReached: If the max TVL is less than the current TVL.
    public fun update_vault_max_tvl<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, max_tvl: u64, ctx: &TxContext){
        admin::verify_supported_package(config);

        assert!(ctx.sender() == vault.admin, EInvalidPermission);
        assert!(max_tvl > 0, EInvalidAmount);
        assert!(max_tvl != vault.max_tvl, ESameValue);
        assert!(get_vault_tvl(vault) <= max_tvl, EMaxTVLReached);

        let previous_max_tvl = vault.max_tvl;
        vault.max_tvl = max_tvl;

        let vault_id = object::uid_to_inner(&vault.id);
        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        events::emit_vault_max_tvl_updated_event(vault_id, previous_max_tvl, max_tvl, vault.sequence_number);
    }
    
    /// Updates the rate of the vault
    /// @dev only the rate manage can update the rate of the vault
    /// Parameters:
    /// - vault: The vault to update
    /// - config: The protocol config
    /// - rate: The new rate
    /// - clock: The clock object
    /// - ctx: The transaction context
    ///
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EInvalidPermission: If the sender is not the rate manager.
    /// - EInvalidInterval: If the rate has not been updated since the last update.
    /// - EInvalidRate: If the rate is not within the allowed range.
    /// - ESameValue: If the rate is the same as the current rate.
    public fun update_vault_rate<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, rate: u64, clock: &Clock, ctx: &TxContext){
        
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);

        assert!(
            dynamic_field::exists_(&vault.id, RATE_MANGER_DYNAMIC_FIELD) && 
            *dynamic_field::borrow<vector<u8>, address>(&vault.id, RATE_MANGER_DYNAMIC_FIELD) == ctx.sender(), EInvalidPermission);
    
        let current_time = clock::timestamp_ms(clock);
        let last_updated_at = vault.rate.last_updated_at;

        assert!(current_time - last_updated_at >= vault.rate.rate_update_interval, EInvalidInterval);

        vault.rate.last_updated_at = current_time;

        let diff = math::percent_change_from(vault.rate.value, rate);

        assert!(
            rate >= admin::get_min_rate(config) && 
            rate <= admin::get_max_rate(config) && 
            diff <= vault.rate.max_rate_change_per_update, 
            EInvalidRate
        );

        assert!(rate != vault.rate.value, ESameValue);
        
        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        charge_accrued_platform_fees(vault, clock);

        let previous_rate = vault.rate.value;
        vault.rate.value = rate;

        let vault_id = object::uid_to_inner(&vault.id);

        events::emit_vault_rate_updated_event(vault_id,previous_rate, rate, vault.sequence_number);
    }


    /// Changes the rate update interval of the vault
    /// @dev only the vault admin can change the rate update interval of the vault
    /// Parameters:
    /// - vault: The vault to change the rate update interval of
    /// - config: The protocol config
    /// - interval: The new rate update interval
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - EInvalidInterval: If the rate update interval is not within the allowed range.
    /// - ESameValue: If the rate update interval is the same as the current rate update interval.
    public fun change_vault_rate_update_interval<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, interval: u64, ctx: &TxContext){

        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);

        assert!(ctx.sender() == vault.admin, EInvalidPermission);

        assert!(interval >= admin::get_min_rate_interval(config) && interval <= admin::get_max_rate_interval(config), EInvalidInterval);

        assert!(interval != vault.rate.rate_update_interval, ESameValue);

        let previous_interval = vault.rate.rate_update_interval;

        vault.rate.rate_update_interval = interval;

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;
        
        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_vault_rate_update_interval_changed_event(vault_id, previous_interval, interval, vault.sequence_number);
    }

    /// Changes the admin of the vault
    /// @dev only the admin can change the admin of the vault
    /// Parameters:
    /// - vault: The vault to change the admin of
    /// - config: The protocol config
    /// - _: The admin capability
    /// - admin: The new admin
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidAccount: If the new admin is the same as the current admin.
    public fun change_vault_admin<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, _: &AdminCap, admin: address){

        admin::verify_supported_package(config);

        let rate_manager = get_vault_rate_manager(vault);
        assert!(
            admin != @0 && 
            admin != vault.admin && 
            admin != rate_manager && 
            admin != vault.operator && 
            !vector::contains(&vault.sub_accounts, &admin) &&
            !vector::contains(&vault.blacklisted, &admin), EInvalidAccount);


        let vault_id = object::uid_to_inner(&vault.id);
        let previous_admin = vault.admin;
        vault.admin = admin;

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        events::emit_vault_admin_changed_event(vault_id, previous_admin, admin, vault.sequence_number);
    }


    /// Changes the operator of the vault
    /// @dev only the vault admin can change the operator of the vault
    /// Parameters:
    /// - vault: The vault to change the operator of
    /// - config: The protocol config
    /// - operator: The new operator
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - EInvalidAccount: If the operator is the same as the current operator.
    public fun change_vault_operator<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, operator: address, ctx: &TxContext){

        admin::verify_supported_package(config);

        assert!(ctx.sender() == vault.admin, EInvalidPermission);

        let rate_manager = get_vault_rate_manager(vault);
        assert!(
            operator != @0 && 
            operator != vault.operator && 
            operator != rate_manager && 
            operator != vault.admin && 
            !vector::contains(&vault.sub_accounts, &operator) &&
            !vector::contains(&vault.blacklisted, &operator), EInvalidAccount);


        let vault_id = object::uid_to_inner(&vault.id);
        let previous_operator = vault.operator;
        vault.operator = operator;

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        events::emit_vault_operator_changed_event(vault_id, previous_operator, operator, vault.sequence_number);
    
    }

    /// @dev Deprecated function, use update_vault_fee_percentage_v2 instead
    /// Updates the fee percentage of the vault v2
    /// @dev only the vault admin can update the fee percentage of the vault
    /// Parameters:
    /// - vault: The vault to update
    /// - config: The protocol config
    /// - fee_percentage: The new fee percentage
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - EInvalidFeePercentage: If the fee percentage is greater than the max allowed fee percentage.
    /// - ESameValue: If the fee percentage is the same as the current fee percentage.
    public fun update_vault_fee_percentage<T,R>(_: &mut Vault<T,R>, _: &ProtocolConfig, _: u64, _: &TxContext){
        abort EDeprecatedFunctionUsage
    }


    /// Updates the fee percentage of the vault
    /// @dev only the vault admin can update the fee percentage of the vault
    /// Parameters:
    /// - vault: The vault to update
    /// - config: The protocol config
    /// - fee_percentage: The new fee percentage
    /// - clock: The clock object
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - EInvalidFeePercentage: If the fee percentage is greater than the max allowed fee percentage.
    /// - ESameValue: If the fee percentage is the same as the current fee percentage.
    public fun update_vault_fee_percentage_v2<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, fee_percentage: u64, clock: &Clock, ctx: &TxContext){

        admin::verify_supported_package(config);
        
        assert!(ctx.sender() == vault.admin, EInvalidPermission);

        assert!(fee_percentage <= admin::get_max_allowed_fee_percentage(config), EInvalidFeePercentage);
        assert!(fee_percentage != vault.fee_percentage, ESameValue);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        charge_accrued_platform_fees(vault, clock);

        let previous_fee_percentage = vault.fee_percentage;
        vault.fee_percentage = fee_percentage;

        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_vault_fee_percentage_updated_event(vault_id, previous_fee_percentage, fee_percentage, vault.sequence_number);
    }

    /// Charges the platform fee on the vault based on current TVL (shares / rate) * fee_percentage
    /// @dev only the operator can charge the platform fee on the vault once every 24 hours
    /// Parameters:
    /// - vault: The vault to charge the platform fee on
    /// - config: The protocol config
    /// - clock: The clock object
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EInvalidPermission: If the sender is not the operator.
    /// - EInvalidInterval: If the platform fee has not been charged since the last charge.
    /// - EZeroAmount: If the fee amount is zero.
    public fun charge_platform_fee<T,R>(_: &mut Vault<T,R>, _: &ProtocolConfig, _: &Clock, _: &mut TxContext){
        abort EDeprecatedFunctionUsage   
    }


    /// Collects all the platform fee from the vault
    /// @dev only the operator can collect the platform fee from the vault
    /// Parameters:
    /// - vault: The vault to collect the platform fee from
    /// - config: The protocol config
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EInvalidPermission: If the sender is not the operator.
    /// - EZeroAmount: If the collected fee is zero.
    /// - EInsufficientBalance: If the vault balance is less than the collected fee.
    public fun collect_platform_fee<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, ctx: &mut TxContext){

        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);

        assert!(ctx.sender() == vault.operator, EInvalidPermission);

        let collected_fee = vault.fee.accrued;
        assert!(collected_fee > 0, EZeroAmount);

        let vault_balance = balance::value(&vault.balance);

        assert!(vault_balance >= vault.fee.accrued, EInsufficientBalance);

        vault.fee.accrued = 0;


        let withdraw_balance = vault.balance.split(collected_fee);


        let token = coin::from_balance(withdraw_balance, ctx);

        let recipient = admin::get_platform_fee_recipient(config);

        transfer::public_transfer(token, recipient);

        let current_vault_balance = balance::value(&vault.balance);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_protocol_fee_collected_event<T>(vault_id, collected_fee, current_vault_balance, recipient, vault.sequence_number);

    }


    /// Updates the paused status of the vault
    /// @dev only the admin can update the paused status of the vault
    /// Parameters:
    /// - vault: The vault to update the paused status of
    /// - config: The protocol config
    /// - status: The new paused status
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - EInvalidStatus: If the paused status is the same as the current paused status.
    public fun set_vault_paused_status<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, status: bool, ctx: &mut TxContext){
        admin::verify_supported_package(config);
        
        assert!(ctx.sender() == vault.admin, EInvalidPermission);
        assert!(vault.paused != status, EInvalidStatus);
        vault.paused = status;

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_vault_paused_status_updated_event(vault_id, status, vault.sequence_number);
    }

    /// Updates the sub account of the vault
    /// @dev only the vault admin can update the sub account of the vault
    /// Parameters:
    /// - vault: The vault to update the sub account of
    /// - config: The protocol config
    /// - account: The sub account to update
    /// - status: The new status of the sub account (true for whitelisting, false for blacklisting)
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - EInvalidAccount: If the sub account is blacklisted.
    public fun set_sub_account<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, account: address, status: bool, ctx: &TxContext){
        admin::verify_supported_package(config);

        assert!(ctx.sender() == vault.admin, EInvalidPermission);
        assert!(!status || !vector::contains(&vault.blacklisted, &account), EBlacklistedAccount);
        assert!(
            account != vault.admin && 
            account != vault.operator &&
            account != get_vault_rate_manager(vault), EInvalidAccount);

        let previous_sub_accounts = vault.sub_accounts;

        update_accounts(&mut vault.sub_accounts, account, status);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_vault_sub_account_updated_event(vault_id, previous_sub_accounts, vault.sub_accounts, account, status, vault.sequence_number);
    }


    /// Updates the blacklisted accounts of the vault
    /// @dev only the vault operator can update the blacklisted accounts of the vault
    /// Parameters:
    /// - vault: The vault to update the blacklisted accounts of
    /// - config: The protocol config
    /// - account: The account to update
    /// - status: The new status of the account (true for whitelisting, false for blacklisting)
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EInvalidPermission: If the sender is not the operator.
    /// - EInvalidAccount: If the account is blacklisted and the status is true.
    public fun set_blacklisted_account<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, account: address, status: bool, ctx: &TxContext){
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        
        assert!(ctx.sender() == vault.operator, EInvalidPermission);

        assert!(!status || !vector::contains(&vault.sub_accounts, &account), EInvalidAccount);

        let previous_blacklisted = vault.blacklisted;

        update_accounts(&mut vault.blacklisted, account, status);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_vault_blacklisted_account_updated_event(vault_id, previous_blacklisted, vault.blacklisted, account, status, vault.sequence_number);
    }


    /// Updates the name of the vault
    /// @dev only the admin can update the name of the vault
    /// Parameters:
    /// - vault: The vault to update the name of
    /// - config: The protocol config
    /// - name: The new name of the vault
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - ESameValue: If the name is the same as the current name.
    public fun update_vault_name<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, name: String, ctx: &mut TxContext){
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        
        assert!(ctx.sender() == vault.admin, EInvalidPermission);
        assert!(name != vault.name, ESameValue);
        let previous_name = vault.name;
        vault.name = name;
        vault.sequence_number = vault.sequence_number + 1;
        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_vault_name_updated_event(vault_id, previous_name, name, vault.sequence_number);
    }


    /// Withdraws from the vault without redeeming shares. The method is used to
    /// withdraw funds from the vault to one of the whitelisted sub accounts.
    /// @dev only the vault operator can withdraw from the vault
    /// Parameters:
    /// - vault: The vault to withdraw from
    /// - config: The protocol config
    /// - amount: The amount to withdraw
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EZeroAmount: If the withdrawal amount is zero.
    /// - EInvalidPermission: If the sender is not the operator.
    /// - EInvalidAccount: If the sub account is not whitelisted.
    /// - EInsufficientBalance: If the withdrawal amount is greater than the vault balance.
    public fun withdraw_from_vault_without_redeeming_shares<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, sub_account: address, amount: u64, ctx: &mut TxContext){
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        
        assert!(ctx.sender() == vault.operator, EInvalidPermission);
        assert!(vector::contains(&vault.sub_accounts, &sub_account), EInvalidAccount);

        assert!(amount > 0 && amount <= balance::value(&vault.balance), EInsufficientBalance);

        let previous_balance = balance::value(&vault.balance);

        let balance = vault.balance.split(amount);

        let coin = coin::from_balance(balance, ctx);

        transfer::public_transfer(coin, sub_account);

        let vault_id = object::uid_to_inner(&vault.id);
        let new_balance = balance::value(&vault.balance);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        events::emit_vault_withdrawal_without_redeeming_shares_event<T>(vault_id, sub_account, previous_balance, new_balance, amount, vault.sequence_number);
    }

    /// Deposits to the vault without minting shares. The method is used to
    /// deposit funds to the vault from one of the whitelisted sub accounts.
    /// @dev only the vault operator can deposit to the vault
    /// Parameters:
    /// - vault: The vault to deposit to
    /// - config: The protocol config
    /// - amount: The amount to deposit from the sub account
    /// - sub_account: The sub account to deposit from
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EZeroAmount: If the deposit amount is zero.
    /// - EInvalidPermission: If the sender is not the vaultoperator.
    /// - EInvalidAccount: If the sub account is not whitelisted.
    public fun deposit_to_vault_without_minting_shares<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, amount: Balance<T>, sub_account: address, ctx: &TxContext){
        deposit_coin_into_vault_without_minting_shares_internal(vault, config, amount, sub_account, ctx);
    }


    /// Deposits to the vault without minting shares. The method is used to
    /// deposit funds to the vault from one of the whitelisted sub accounts.
    /// The difference between this method and the previous one is that this method
    /// allows the vault operator to move an already deposited token to vault.id into the vault.
    /// @dev only the vault operator can deposit to the vault
    /// Parameters:
    /// - vault: The vault to deposit to
    /// - config: The protocol config
    /// - token: The id of the token to deposit
    /// - sub_account: The sub account to deposit from
    /// - ctx: The transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EZeroAmount: If the deposit amount is zero.
    /// - EInvalidPermission: If the sender is not the vault operator.
    /// - EInvalidAccount: If the sub account is not whitelisted.
    public fun deposit_to_vault_without_minting_shares_v2<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, token: Receiving<Coin<T>>, sub_account: address, ctx: &TxContext){

        let coin = transfer::public_receive(&mut vault.id, token);

        let coin_balance = coin::into_balance(coin);

        deposit_coin_into_vault_without_minting_shares_internal(vault, config, coin_balance, sub_account, ctx);


    }

    /// Allows a user to deposit assets into the vault and receive receipt tokens in return.
    /// 
    /// Parameters:
    /// - vault: The mutable reference to the vault to deposit into.
    /// - config: The protocol configuration.
    /// - balance: The balance of assets to deposit.
    /// - ctx: The mutable transaction context.
    /// 
    /// Returns:
    /// - Coin<R>: The minted receipt token coin corresponding to the deposited amount.
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EVaultPaused: If the vault is paused.
    /// - EZeroAmount: If the deposit amount is zero.
    /// - EMaxTVLReached: If the max TVL is reached.
    public fun deposit_asset<T,R>(_: &mut Vault<T,R>, _: &ProtocolConfig, _: Balance<T>, _: &mut TxContext): Coin<R> {
        abort EDeprecatedFunctionUsage
    }


    /// Allows a user to deposit assets into the vault and receive receipt tokens in return.
    /// 
    /// Parameters:
    /// - vault: The mutable reference to the vault to deposit into.
    /// - config: The protocol configuration.
    /// - balance: The balance of assets to deposit.
    /// - min_shares: The minimum number of shares to mint for given deposit amount.
    /// - clock: The clock reference.
    /// - ctx: The mutable transaction context.
    /// 
    /// Returns:
    /// - Coin<R>: The minted receipt token coin corresponding to the deposited amount.
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EVaultPaused: If the vault is paused.
    /// - EZeroAmount: If the deposit amount is zero.
    /// - EMaxTVLReached: If the max TVL is reached.
    public fun deposit_asset_v2<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, balance: Balance<T>, min_shares: u64, clock: &Clock, ctx: &mut TxContext): Coin<R> {

        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        verify_vault_not_paused(vault);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        charge_accrued_platform_fees(vault, clock);

        let owner = ctx.sender();
        verify_not_blacklisted(vault, owner);
        verify_not_sub_account(vault, owner);

        let total_amount = balance::value(&balance);

        assert!(total_amount > 0, EZeroAmount);

    
        let previous_balance = balance::value(&vault.balance);

        vault.balance.join(balance);

        let current_balance = balance::value(&vault.balance);
    
        let shares_minted = calculate_shares_from_amount(vault, total_amount);

        assert!(shares_minted > 0, EZeroAmount);
        assert!(shares_minted >= min_shares, ESlippageToleranceExceeded);

        let receipt_coin = coin::mint(&mut vault.receipt_token_treasury_cap, shares_minted, ctx);

        assert!(get_vault_tvl(vault) <= vault.max_tvl, EMaxTVLReached);

        let vault_id = object::uid_to_inner(&vault.id);
        let total_shares = get_vault_total_shares(vault);

        events::emit_vault_deposit_event<T>(vault_id, owner, total_amount, shares_minted, previous_balance, current_balance, total_shares, vault.sequence_number);

        receipt_coin

    }

    /// Allows a user to mint shares from the vault and receive receipt tokens in return.
    /// 
    /// Parameters:
    /// - vault: The mutable reference to the vault to mint shares from.
    /// - config: The protocol configuration.
    /// - balance: The balance of assets to mint shares from.
    /// - shares: The number of shares to mint.
    /// 
    /// Returns:
    /// - Coin<R>: The minted receipt token coin corresponding to the minted shares.
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EVaultPaused: If the vault is paused.
    /// - EZeroAmount: If the shares to mint is zero.
    /// - EInsufficientBalance: If the balance is insufficient to mint the shares.
    /// - EMaxTVLReached: If the max TVL is reached.
    public fun mint_shares<T,R>(_: &mut Vault<T,R>, _: &ProtocolConfig, _: &mut Balance<T>, _: u64, _: &mut TxContext): Coin<R> {
        abort EDeprecatedFunctionUsage
    }

    /// Allows a user to mint shares from the vault and receive receipt tokens in return.
    /// 
    /// Parameters:
    /// - vault: The mutable reference to the vault to mint shares from.
    /// - config: The protocol configuration.
    /// - balance: The balance of assets to mint shares from.
    /// - shares: The number of shares to mint.
    /// - max_amount: The maximum amount of assets to mint the shares from.
    /// - clock: The clock reference.
    /// - ctx: The mutable transaction context.
    /// 
    /// Returns:
    /// - Coin<R>: The minted receipt token coin corresponding to the minted shares.
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EVaultPaused: If the vault is paused.
    /// - EZeroAmount: If the shares to mint is zero.
    /// - EInsufficientBalance: If the balance is insufficient to mint the shares.
    /// - EMaxTVLReached: If the max TVL is reached.
    public fun mint_shares_v2<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, balance: &mut Balance<T>, shares: u64, max_amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<R> {

        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        verify_vault_not_paused(vault);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        charge_accrued_platform_fees(vault, clock);

        let owner = ctx.sender();
        verify_not_blacklisted(vault, owner);
        verify_not_sub_account(vault, owner);

        assert!(shares > 0, EZeroAmount);

        // Calculate the deposit amount needed for the requested shares
        // shares = deposit_amount * vault.rate  => deposit_amount = shares / vault.rate
        // But since vault.rate is a fixed-point (1e9), we use integer division
        let total_amount = calculate_amount_from_shares(vault, shares);

        assert!(total_amount > 0, EZeroAmount);
        assert!(total_amount <= max_amount, ESlippageToleranceExceeded);


        let available = balance::value(balance);
        assert!(available >= total_amount, EInsufficientBalance);

        let previous_balance = balance::value(&vault.balance);

        // Withdraw the deposit amount from the user's balance and join to vault
        let deposit_balance = balance.split(total_amount);
        vault.balance.join(deposit_balance);

        let current_balance = balance::value(&vault.balance);

        // Mint the specified shares to the user
        let receipt_coin = coin::mint(&mut vault.receipt_token_treasury_cap, shares, ctx);

        assert!(get_vault_tvl(vault) <= vault.max_tvl, EMaxTVLReached);

        let vault_id = object::uid_to_inner(&vault.id);
        let total_shares = get_vault_total_shares(vault);

        events::emit_vault_deposit_event<T>(
            vault_id, 
            owner, 
            total_amount, 
            shares, 
            previous_balance, 
            current_balance, 
            total_shares,
            vault.sequence_number
        );

        receipt_coin
    }



    /// Allows a user to redeem shares of a vault and receive underlying assets.
    /// The shares are locked into vault upon request and only when the vault operator processes
    /// the withdrawal request, the shares are burnt and the under lying asset based on the vault rate at the time of processing claim
    /// request is sent to the user.
    /// Parameters:
    /// - vault: The mutable reference to the vault to redeem shares from.
    /// - config: The protocol configuration.
    /// - shares: The balance containing shares to redeem
    /// - receiver: The address to send the underlying assets to
    /// - clock: The clock reference
    /// - ctx: The mutable transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EVaultPaused: If the vault is paused.
    /// - EZeroAmount: If the shares to redeem is zero.
    /// - EInsufficientShares: If the shares to redeem is less than the minimum withdrawal shares.
    public fun redeem_shares<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, shares: Balance<R>, receiver: address, clock: &Clock, ctx: &mut TxContext): WithdrawalRequest {

        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        verify_vault_not_paused(vault);

        let owner = ctx.sender();
        verify_not_blacklisted(vault, owner);
        verify_not_blacklisted(vault, receiver);
        let vault_id = object::uid_to_inner(&vault.id);

        // the number of shares to redeem
        let shares_to_redeem =  balance::value(&shares);

        assert!(shares_to_redeem >= vault.min_withdrawal_shares, EInsufficientShares);

        // store the shares to redeem in the pending shares to burn balance
        vault.pending_shares_to_burn.join(shares);

        // the estimated withdraw amount based on the current vault rate
        let estimated_withdraw_amount = calculate_amount_from_shares(vault, shares_to_redeem);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        let request = WithdrawalRequest {
            owner: owner,
            receiver: receiver,
            shares: shares_to_redeem,
            estimated_withdraw_amount,
            timestamp: clock::timestamp_ms(clock),
            sequence_number: vault.sequence_number,
        };

        queue::enqueue(&mut vault.pending_withdrawals, request);

        // update the shares to be redeemed for the account
        update_account_state(vault, &request, true,  option::none());

        let total_shares = get_vault_total_shares(vault);
        let total_shares_pending_to_burn = balance::value(&vault.pending_shares_to_burn);

        events::emit_request_redeemed_event<T>(
            vault_id, 
            request.owner,
            request.receiver,
            request.shares,
            request.timestamp,
            total_shares,
            total_shares_pending_to_burn, 
            vault.sequence_number
        );

        request
    }

    /// Allows the vault operator to process withdrawal requests from the queue.
    /// The request is removed from the queue and the shares are burnt and the underlying assets are sent to the user.
    /// Parameters:
    /// - vault: The mutable reference to the vault to claim funds from.
    /// - config: The protocol configuration.
    /// - num_requests: The number of requests to process
    /// - clock: The clock reference
    /// - ctx: The mutable transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EVaultPaused: If the vault is paused.
    /// - EInvalidPermission: If the sender is not the vault operator.
    /// - EZeroAmount: If the number of requests is zero.
    public fun process_withdrawal_requests<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, num_requests: u64, clock: &Clock, ctx: &mut TxContext){


        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        verify_vault_not_paused(vault);

        let sender = ctx.sender();
        assert!(sender == vault.operator, EInvalidPermission);

        assert!(num_requests > 0, EZeroAmount);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        charge_accrued_platform_fees(vault, clock);

        let mut total_shares_burnt = 0;
        let mut total_request_processed = 0;
        let mut total_amount_withdrawn = 0;
        let mut requests_skipped = 0;
        let mut requests_cancelled = 0;
        let current_time = clock::timestamp_ms(clock);
        let vault_id = object::uid_to_inner(&vault.id);

        let queue_len = queue::len(&vault.pending_withdrawals);
        let num_requests = if(num_requests < queue_len){ num_requests } else { queue_len };

        let mut i =0;
        while(i < num_requests){
            let request = queue::dequeue(&mut vault.pending_withdrawals);


            let (skipped, cancelled, withdraw_amount, shares_burnt) = process_request(vault, &request, current_time, ctx);
            
            total_request_processed = total_request_processed + 1;
            total_shares_burnt = total_shares_burnt + shares_burnt;
            total_amount_withdrawn = total_amount_withdrawn + withdraw_amount;

            if(skipped){
                requests_skipped = requests_skipped + 1;
            }; 

            if(cancelled){
                requests_cancelled = requests_cancelled + 1;
            };

            // increment the counter
            i = i + 1;

        };

        let total_shares = get_vault_total_shares(vault);
        let total_shares_pending_to_burn = balance::value(&vault.pending_shares_to_burn);

        events::emit_process_requests_summary_event(
            vault_id,
            total_request_processed,
            requests_skipped,
            requests_cancelled,
            total_shares_burnt,
            total_amount_withdrawn,
            total_shares,
            total_shares_pending_to_burn,
            vault.rate.value,
            vault.sequence_number
        );

    }


    /// Allows the vault operator to process withdrawal requests from the queue up to a given timestamp.
    /// The request is removed from the queue and the shares are burnt and the underlying assets are sent to the user.
    /// Parameters:
    /// - vault: The mutable reference to the vault to claim funds from.
    /// - config: The protocol configuration.
    /// - timestamp: The timestamp to process requests up to
    /// - clock: The clock reference
    /// - ctx: The mutable transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EVaultPaused: If the vault is paused.
    /// - EInvalidPermission: If the sender is not the vault operator.
    public fun process_withdrawal_requests_up_to_timestamp<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, timestamp: u64, clock: &Clock, ctx: &mut TxContext){


        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        verify_vault_not_paused(vault);

        let sender = ctx.sender();
        assert!(sender == vault.operator, EInvalidPermission);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;

        charge_accrued_platform_fees(vault, clock);
        
        let mut total_shares_burnt = 0;
        let mut total_request_processed = 0;
        let mut total_amount_withdrawn = 0;
        let mut requests_skipped = 0;
        let mut requests_cancelled = 0;
        let current_time = clock::timestamp_ms(clock);
        let vault_id = object::uid_to_inner(&vault.id);

        while(!queue::is_empty(&vault.pending_withdrawals)){
            // Peek at the front request to check timestamp before dequeuing
            let front_request = queue::peek(&vault.pending_withdrawals);
            
            // if the request is newer than the timestamp, stop processing
            if(front_request.timestamp > timestamp){
                break
            };
            
            // Now safely dequeue since we know the timestamp is acceptable
            let request = queue::dequeue(&mut vault.pending_withdrawals);

            let (skipped, cancelled, withdraw_amount, shares_burnt) = process_request(vault, &request, current_time, ctx);
            
            total_request_processed = total_request_processed + 1;
            total_shares_burnt = total_shares_burnt + shares_burnt;
            total_amount_withdrawn = total_amount_withdrawn + withdraw_amount;

            if(skipped){
                requests_skipped = requests_skipped + 1;
            }; 

            if(cancelled){
                requests_cancelled = requests_cancelled + 1;
            };

        };


        let total_shares = get_vault_total_shares(vault);
        let total_shares_pending_to_burn = balance::value(&vault.pending_shares_to_burn);

        events::emit_process_requests_summary_event(
            vault_id,
            total_request_processed,
            requests_skipped,
            requests_cancelled,
            total_shares_burnt,
            total_amount_withdrawn,
            total_shares,
            total_shares_pending_to_burn,
            vault.rate.value,
            vault.sequence_number
        );

    }


    /// Allows the admin to set the minimum amount of shares that can be withdrawn from the vault
    /// Parameters:
    /// - vault: The mutable reference to the vault to set the minimum amount of shares to withdraw from.
    /// - config: The protocol configuration.
    /// - min_withdrawal_shares: The minimum amount of shares that can be withdrawn from the vault.
    /// - ctx: The mutable transaction context.
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EInvalidPermission: If the sender is not the admin.
    /// - EZeroAmount: If the minimum withdrawal shares is not greater than 0.
    /// - EInvalidAmount: If the minimum withdrawal shares is the same as the current minimum withdrawal shares.
    public fun set_min_withdrawal_shares<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, min_withdrawal_shares: u64, ctx: &TxContext){

        admin::verify_supported_package(config);

        let sender = ctx.sender();
        assert!(sender == vault.admin, EInvalidPermission);

        assert!(min_withdrawal_shares > 0, EZeroAmount);
        assert!(min_withdrawal_shares != vault.min_withdrawal_shares, EInvalidAmount);

        let previous_min_withdrawal_shares = vault.min_withdrawal_shares;

        vault.min_withdrawal_shares = min_withdrawal_shares;

        vault.sequence_number = vault.sequence_number + 1;
        let vault_id = object::uid_to_inner(&vault.id);

        events::emit_min_withdrawal_shares_updated_event(vault_id, previous_min_withdrawal_shares, min_withdrawal_shares, vault.sequence_number);


    }


    /// Allows an owner to cancel a pending withdrawal request
    /// Parameters:
    /// - vault: The mutable reference to the vault to cancel the withdrawal request from.
    /// - config: The protocol configuration.
    /// - sequence_number: The sequence number of the withdrawal request to cancel.
    /// - ctx: The mutable transaction context
    /// 
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EProtocolPaused: If the protocol is paused.
    /// - EVaultPaused: If the vault is paused.
    /// - EUserDoesNotHaveAccount: If the user does not have an account in the vault.
    /// - EInvalidRequest: If the request is already pending cancellation.
    public fun cancel_pending_withdrawal_request<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, sequence_number: u128, ctx: &mut TxContext){
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        verify_vault_not_paused(vault);

        let sender = ctx.sender();
        assert!(table::contains(&vault.accounts, sender), EUserDoesNotHaveAccount);

        let account_state = table::borrow_mut(&mut vault.accounts, sender);
        let (cancelled, _) = vector::index_of(&account_state.cancel_withdraw_request, &sequence_number);

        // revert if the request is already pending cancellation
        assert!(!cancelled, EInvalidRequest);

        // if no withdrawal request with the sequence number is found, revert
        let index = account_state.pending_withdrawal_requests.find_index!(|request| request.sequence_number == sequence_number);
        assert!(index.is_some(), EInvalidRequest);
        let request = vector::borrow(&account_state.pending_withdrawal_requests, *option::borrow(&index));

        account_state.cancel_withdraw_request.push_back(sequence_number);

        let vault_id = object::uid_to_inner(&vault.id);

        events::emit_request_cancelled_event(vault_id, request.owner, request.sequence_number, account_state.cancel_withdraw_request);

        
    }

    /// Updates the max rate change per update of the vault
    /// @dev only the vault admin can update the max rate change per update of the vault
    /// Parameters:
    /// - vault: The vault to update the max rate change per update of
    /// - config: The protocol config
    /// - max_rate_change_percentage: The new max rate change per update
    /// - ctx: The transaction context
    /// Aborts with:
    /// - EInvalidPermission: If the sender is not the vault admin
    /// - EInvalidAmount: If the max rate change per update is not within the allowed range
    public fun update_vault_max_rate_change_per_update<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, max_rate_change_percentage: u64, ctx: &mut TxContext){
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);

        let sender = ctx.sender();
        assert!(sender == vault.admin, EInvalidPermission);

        assert!(max_rate_change_percentage > 0 && max_rate_change_percentage <  1000000000 && max_rate_change_percentage != vault.rate.max_rate_change_per_update, EInvalidAmount);

        let previous_max_rate_change_percentage = vault.rate.max_rate_change_per_update;
        vault.rate.max_rate_change_per_update = max_rate_change_percentage;

        vault.sequence_number = vault.sequence_number + 1;
        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_vault_max_rate_change_per_update_updated_event(vault_id, previous_max_rate_change_percentage, max_rate_change_percentage, vault.sequence_number);
    }

    // === View Functions ===

    public fun get_vault_id<T,R>(vault: &Vault<T,R>): ID {
        object::uid_to_inner(&vault.id)
    }

    public fun get_vault_name<T,R>(vault: &Vault<T,R>): String {
        vault.name
    }

    public fun get_vault_admin<T,R>(vault: &Vault<T,R>): address {
        vault.admin
    }

    public fun get_vault_operator<T,R>(vault: &Vault<T,R>): address {
        vault.operator
    }

    public fun get_vault_blacklisted<T,R>(vault: &Vault<T,R>): vector<address> {
        vault.blacklisted
    }

    public fun get_vault_paused<T,R>(vault: &Vault<T,R>): bool {
        vault.paused
    }

    /// Returns the amount of shares that the account has pending for withdrawal
    /// Parameters:
    /// - vault: The vault to get the pending shares from
    /// - account: The account to get the pending shares from
    /// Returns: The amount of shares that the account has pending for withdrawal
    public fun get_account_total_pending_withdrawal_shares<T,R>(vault: &Vault<T,R>, account: address): u64 {
        if(!table::contains(&vault.accounts, account)){
            0
        } else {
            table::borrow(&vault.accounts, account)
                .total_pending_withdrawal_shares
        }
    }

    public fun get_account_pending_withdrawal_requests<T,R>(vault: &Vault<T,R>, account: address): vector<WithdrawalRequest> {
        if(!table::contains(&vault.accounts, account)){
            vector::empty()
        } else {
            table::borrow(&vault.accounts, account)
                .pending_withdrawal_requests
        }
    }

    public fun get_account_cancelled_withdraw_request_sequencer_numbers<T,R>(vault: &Vault<T,R>, account: address): vector<u128> {
        if(!table::contains(&vault.accounts, account)){
            vector::empty()
        } else {
            table::borrow(&vault.accounts, account)
                .cancel_withdraw_request
        }
    }

    public fun get_pending_shares_to_redeem<T,R>(vault: &Vault<T,R>): u64 {
        balance::value(&vault.pending_shares_to_burn)
    }

    public fun get_vault_sub_accounts<T,R>(vault: &Vault<T,R>): vector<address> {
        vault.sub_accounts
    }

    public fun get_vault_rate<T,R>(vault: &Vault<T,R>): u64 {
        vault.rate.value
    }

    public fun get_vault_rate_update_interval<T,R>(vault: &Vault<T,R>): u64 {
        vault.rate.rate_update_interval
    }

    public fun get_vault_max_rate_change_per_update<T,R>(vault: &Vault<T,R>): u64 {
        vault.rate.max_rate_change_per_update
    }

    public fun get_vault_last_updated_at<T,R>(vault: &Vault<T,R>): u64 {
        vault.rate.last_updated_at
    }
    public fun get_vault_balance<T,R>(vault: &Vault<T,R>): u64 {
        balance::value(&vault.balance)
    }

    public fun get_vault_sequence_number<T,R>(vault: &Vault<T,R>): u128 {
        vault.sequence_number
    }

    public fun get_vault_fee_percentage<T,R>(vault: &Vault<T,R>): u64 {
        vault.fee_percentage
    }

    public fun get_vault_min_withdrawal_shares<T,R>(vault: &Vault<T,R>): u64 {
        vault.min_withdrawal_shares
    }

    public fun get_vault_max_tvl<T,R>(vault: &Vault<T,R>): u64 {
        vault.max_tvl
    }

    public fun get_accrued_platform_fee<T,R>(vault: &Vault<T,R>): u64 {
        vault.fee.accrued
    }

    public fun get_last_charged_at_platform_fee<T,R>(vault: &Vault<T,R>): u64 {
        vault.fee.last_charged_at
    }

    public fun verify_vault_not_paused<T,R>(vault: &Vault<T,R>){
        assert!(!vault.paused, EVaultPaused);
    }

    public fun get_vault_blacklisted_accounts<T,R>(vault: &Vault<T,R>): vector<address> {
        vault.blacklisted
    }

    public fun get_vault_total_shares_in_circulation<T,R>(vault: &Vault<T,R>): u64 {
        coin::total_supply<R>(&vault.receipt_token_treasury_cap) - balance::value(&vault.pending_shares_to_burn)
    }

    public fun get_vault_total_shares<T,R>(vault: &Vault<T,R>): u64 {
        coin::total_supply<R>(&vault.receipt_token_treasury_cap)
    }

    public fun verify_not_blacklisted<T,R>(vault: &Vault<T,R>, account: address){
        assert!(!vector::contains(&vault.blacklisted, &account), EBlacklistedAccount);
    }

    public fun verify_not_sub_account<T,R>(vault: &Vault<T,R>, account: address){
        assert!(!vector::contains(&vault.sub_accounts, &account), ESubAccount);
    }

    public fun is_blacklisted<T,R>(vault: &Vault<T,R>, account: address): bool {
        vector::contains(&vault.blacklisted, &account)
    }

    public fun get_withdrawal_queue<T,R>(vault: &Vault<T,R>): &Queue<WithdrawalRequest> {
        &vault.pending_withdrawals
    }

    public fun decode_withdrawal_request(request: &WithdrawalRequest): (address, address, u64, u64, u64, u128) {
        (request.owner, request.receiver, request.shares, request.estimated_withdraw_amount, request.timestamp, request.sequence_number)
    }

    public fun get_vault_tvl<T,R>(vault: &Vault<T,R>): u64 {
        let shares = get_vault_total_shares(vault);
        math::div(shares, vault.rate.value)
    }

    public fun calculate_shares_from_amount<T,R>(vault: &Vault<T,R>, amount: u64): u64 {
        math::mul(amount, vault.rate.value)
    }

    public fun calculate_amount_from_shares<T,R>(vault: &Vault<T,R>, shares: u64): u64 {
        math::div_ceil(shares, vault.rate.value)
    }

    public fun get_vault_rate_manager<T,R>(vault: &Vault<T,R>): address {
        if(!dynamic_field::exists_(&vault.id, RATE_MANGER_DYNAMIC_FIELD)){
            @0
        } else {
            *dynamic_field::borrow<vector<u8>, address>(&vault.id, RATE_MANGER_DYNAMIC_FIELD)
        }
    }

    // === Internal Functions ===

    /// Helper method to add/remove an account from provided vector used for setting vault sub accounts and blacklisted accounts
    /// Parameters:
    /// - accounts: The vector to update
    /// - account: The account to update
    /// - status: The new status of the account (true for whitelisting, false for blacklisting)
    fun update_accounts(accounts: &mut vector<address>, account: address, status: bool){

        assert!(account != @0, EInvalidAccount);

        let(exists, index) = vector::index_of(accounts, &account);

        // if the sub account is to be whitelisted
        if(status){
            assert!(!exists, EAlreadyExists);
            vector::push_back(accounts, account);
        } else {
            assert!(exists, EInvalidRequest);
            vector::remove(accounts, index);
        };

    }


    /// Helper method to update the account state for a withdrawal request or redeem shares
    /// Parameters:
    /// - vault: The mutable reference to the vault to update
    /// - request: The withdrawal request to update
    /// - add: Whether to add or subtract the shares
    /// - index: An optional index indicating the index of request that got cancelled
    fun update_account_state<T,R>(vault: &mut Vault<T,R>, request: &WithdrawalRequest, add: bool, index: Option<u64>){

        assert!(!(add && index.is_some()), EInvalidRequest);

        if(!table::contains(&vault.accounts, request.owner)){
            table::add(&mut vault.accounts, request.owner, Account {
                total_pending_withdrawal_shares: 0,
                pending_withdrawal_requests: vector::empty(),
                cancel_withdraw_request: vector::empty()
            });
        };

        let account_state = table::borrow_mut(&mut vault.accounts, request.owner);
        if(add){
            account_state.total_pending_withdrawal_shares = account_state.total_pending_withdrawal_shares + request.shares;
            vector::push_back(&mut account_state.pending_withdrawal_requests, *request);            
        } else {
            account_state.total_pending_withdrawal_shares = account_state.total_pending_withdrawal_shares - request.shares;
            // Requests are always processed from the queue and are always in increasing sequencer number order
            // We can safely remove the first request from the vector when an account state is being updated
            vector::remove(&mut account_state.pending_withdrawal_requests, 0);

            // if this request was skipped due to cancellation remove its sequencer number
            // from user's cancel withdraw request vector
            // if it was skipped due to cancellation, the index will be 0...length-1
            if(index.is_some() && *option::borrow(&index) < vector::length(&account_state.cancel_withdraw_request)){
                vector::remove(&mut account_state.cancel_withdraw_request, *option::borrow(&index));
            }
        };

        if(account_state.total_pending_withdrawal_shares == 0){
            table::remove(&mut vault.accounts, request.owner);
        }
    }


    /// Helper method to burn shares from the pending shares to burn balance
    /// Parameters:
    /// - vault: The mutable reference to the vault to burn shares from
    /// - shares: The number of shares to burn
    /// - ctx: The mutable transaction context
    fun burn_shares<T,R>(vault: &mut Vault<T,R>, shares: u64, ctx: &mut TxContext){
        assert!(balance::value(&vault.pending_shares_to_burn) >= shares, EInsufficientShares);
        let balance = vault.pending_shares_to_burn.split(shares);
        coin::burn(&mut vault.receipt_token_treasury_cap, coin::from_balance(balance, ctx));
    }
    
    /// Helper method to return shares to the owner.
    /// @Dev use this method only during request processing if the owner is blacklisted
    /// Parameters:
    /// - vault: The mutable reference to the vault to return shares to
    /// - shares: The number of shares to return
    /// - owner: The address to return the shares to
    /// - ctx: The mutable transaction context
    fun return_shares_to_owner<T,R>(vault: &mut Vault<T,R>, shares: u64, owner: address, ctx: &mut TxContext){
        let balance = vault.pending_shares_to_burn.split(shares);
        transfer::public_transfer(coin::from_balance(balance, ctx), owner);
    }

    /// Helper method to process a withdrawal request.
    /// If a blacklisted account's request is processed, it will be skipped and the shares will be sent back to the owners
    /// Parameters:
    /// - vault: The mutable reference to the vault to process the request from
    /// - request: The withdrawal request to process
    /// - current_time: The current time
    /// - ctx: The mutable transaction context
    /// Returns: A tuple containing a boolean indicating if the request was skipped, the amount withdrawn, and the number of shares burnt
    fun process_request<T,R>(vault: &mut Vault<T,R>, request: &WithdrawalRequest, current_time: u64, ctx: &mut TxContext): (bool, bool, u64, u64){

        let vault_id = object::uid_to_inner(&vault.id);

        let mut withdraw_amount = math::div(request.shares, vault.rate.value);
        let account_state = table::borrow(&vault.accounts, request.owner);
        let num_cancelled_requests = vector::length(&account_state.cancel_withdraw_request);
        let (cancelled, index) = vector::index_of(&account_state.cancel_withdraw_request, &request.sequence_number);

        
        let mut option_index = if(cancelled){ option::some(index) } else { option::none() };

        if(is_blacklisted(vault, request.owner) || is_blacklisted(vault, request.receiver) || cancelled || withdraw_amount == 0) {
            
            // if the withdrawal request is being skipped due to blacklisting or withdrawal amount being zero,
            // set the index as the number of cancelled requests.
            if(!cancelled){
                option_index = option::some(num_cancelled_requests);
            };

            withdraw_amount = 0;   
            return_shares_to_owner(vault, request.shares, request.owner, ctx);
        } else {

            burn_shares(vault, request.shares, ctx);

            assert!(balance::value(&vault.balance) >= withdraw_amount, EInsufficientBalance);

            // transfer the funds to the receiver
            let withdraw_coin = vault.balance.split(withdraw_amount).into_coin(ctx);
            transfer::public_transfer(withdraw_coin, request.receiver);
 
        };

        update_account_state(vault, request, false, option_index);

        let total_shares = get_vault_total_shares(vault);
        let total_shares_pending_to_burn = balance::value(&vault.pending_shares_to_burn);


        events::emit_request_processed_event<T>(
            vault_id,
            request.owner,
            request.receiver,
            request.shares,
            withdraw_amount,
            request.timestamp,
            current_time,
            option_index.is_some(),
            cancelled,
            total_shares,
            total_shares_pending_to_burn,
            vault.sequence_number,
            request.sequence_number
        );

        (option_index.is_some(), cancelled, withdraw_amount, request.shares)
    }

    // Helper method for depositing coins into vault without minting shares
    fun deposit_coin_into_vault_without_minting_shares_internal<T,R>(vault: &mut Vault<T,R>, config: &ProtocolConfig, amount: Balance<T>, sub_account: address, ctx: &TxContext){
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        
        assert!(ctx.sender() == vault.operator, EInvalidPermission);
        assert!(vector::contains(&vault.sub_accounts, &sub_account), EInvalidAccount);


        let deposit_amount = balance::value(&amount);
        assert!(deposit_amount > 0, EZeroAmount);

        let previous_balance = balance::value(&vault.balance);

        balance::join<T>(&mut vault.balance, amount);

        let vault_id = object::uid_to_inner(&vault.id);
        let new_balance = balance::value(&vault.balance);

        // increment the sequence number
        vault.sequence_number = vault.sequence_number + 1;
        
        events::emit_vault_deposit_without_minting_shares_event<T>(vault_id, sub_account, previous_balance, new_balance, deposit_amount, vault.sequence_number);


    }

    /// Internal method to charge any applicable fee
    fun charge_accrued_platform_fees<T,R>(vault: &mut Vault<T,R>, clock: &Clock){
        
        let current_time = clock::timestamp_ms(clock);

        let last_charged_at = vault.fee.last_charged_at;

        let elapsed_time_ms = current_time - last_charged_at;

        if (elapsed_time_ms <= 0) {
            return
        };

        if(vault.fee_percentage == 0){
            vault.fee.last_charged_at = current_time;
            return
        };

        let tvl = get_vault_tvl(vault);

        // tvl: 100 = 100e6
        // fee_percentage: 10% = 0.1 * 1e9
        // elapsed_time_ms: 1 year = 31536000000
        // fee_amount = (100e6 * 0.1 * 1e9 * 31536000000) / 31_536_000_000_000_000
        let numerator = (tvl as u128) * (vault.fee_percentage as u128) * (elapsed_time_ms as u128);
        let fee_amount = math::safe_cast_to_u64(numerator / FEE_DENOMINATOR);

        vault.fee.accrued = vault.fee.accrued + fee_amount;
        vault.fee.last_charged_at = current_time;

        let vault_id = object::uid_to_inner(&vault.id);
        events::emit_vault_platform_fee_charged_event(vault_id, fee_amount, vault.fee.accrued, vault.fee.last_charged_at, vault.sequence_number);
    }

    // ==== Test Only Functions ====

    #[test_only]
    public fun increment_pending_withdrawal_shares<T,R>(vault: &mut Vault<T,R>, account: address, shares: u64){

        if(!table::contains(&vault.accounts, account)){
            table::add(&mut vault.accounts, account, Account {
                total_pending_withdrawal_shares: 0,
                pending_withdrawal_requests: vector::empty(),
                cancel_withdraw_request: vector::empty()
            });
        };

        let account = table::borrow_mut(&mut vault.accounts, account);
        account.total_pending_withdrawal_shares = account.total_pending_withdrawal_shares + shares;
    }

    #[test_only]
    public fun increase_platform_fee_accrued<T,R>(vault: &mut Vault<T,R >, amount: u64, last_charged_at: u64){
        vault.fee.accrued = vault.fee.accrued + amount;
        vault.fee.last_charged_at = last_charged_at;

        let balance = balance::create_for_testing<T>(amount);
        vault.balance.join(balance);
    }

    #[test_only]
    public fun increase_vault_balance<T,R>(vault: &mut Vault<T,R>, amount: u64){
        let new_balance = balance::create_for_testing<T>(amount);
        vault.balance.join(new_balance);
    }

    #[test_only]
    public fun get_withdrawal_receipt_nonce(receipt: &WithdrawalRequest): u128 {
        receipt.sequence_number
    }

    #[test_only]
    public fun set_withdrawal_request_nonce(receipt: &mut WithdrawalRequest, nonce: u128) {
        receipt.sequence_number = nonce;
    }

    #[test_only]
    public fun set_withdrawal_request_receiver(receipt: &mut WithdrawalRequest, receiver: address) {
        receipt.receiver = receiver;
    }

    #[test_only]
    public fun set_vault_balance<T,R>(vault: &mut Vault<T,R>, amount: u64){
        let balance = vault.balance.withdraw_all();
        vault.balance.join(balance::create_for_testing<T>(amount));
        balance::destroy_for_testing(balance);
    }

    #[test_only]
    public fun test_charge_accrued_platform_fees<T,R>(vault: &mut Vault<T,R>, clock: &Clock){
        charge_accrued_platform_fees(vault, clock);
    }
}