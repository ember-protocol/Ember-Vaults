/*
  Copyright (c) 2026 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code 
  requires prior written permission from the Ember Protocol Inc.
*/

module ember_vaults::events {
    
    // === Imports ===
    use sui::event::emit;
    use std::string::String;

    

    // === Structs ===

    /// Event emitted when the protocol is paused or unpaused.
    /// 
    /// Parameters:
    /// - status: True if the protocol is paused, false if it is unpaused.
    public struct PauseNonAdminOperationsEvent has copy, drop {
        status: bool,
    }

    /// Event emitted when the supported version is updated.
    /// 
    /// Parameters:
    /// - old_version: The previous supported version.
    /// - new_version: The new supported version.
    public struct SupportedVersionUpdateEvent has copy, drop {
        old_version: u64,
        new_version: u64,
    }

    /// Event emitted when the platform fee recipient is updated.
    /// 
    /// Parameters:
    /// - previous_recipient: The previous platform fee recipient.
    /// - new_recipient: The new platform fee recipient.
    public struct PlatformFeeRecipientUpdateEvent has copy, drop {
        previous_recipient: address,
        new_recipient: address,
    }

    /// Event emitted when the min rate is updated.
    /// 
    /// Parameters:
    /// - previous_min_rate: The previous min rate.
    /// - new_min_rate: The new min rate.
    public struct MinRateUpdateEvent has copy, drop {
        previous_min_rate: u64,
        new_min_rate: u64,
    }

    /// Event emitted when the max rate is updated.
    /// 
    /// Parameters:
    /// - previous_max_rate: The previous max rate.
    /// - new_max_rate: The new max rate.
    public struct MaxRateUpdateEvent has copy, drop {
        previous_max_rate: u64,
        new_max_rate: u64,
    }

    /// Event emitted when the default rate is updated.
    /// 
    /// Parameters:
    /// - previous_default_rate: The previous default rate.
    /// - new_default_rate: The new default rate.
    public struct DefaultRateUpdateEvent has copy, drop {
        previous_default_rate: u64,
        new_default_rate: u64,
    }

    /// Event emitted when a vault is created.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - name: The name of the vault.
    /// - admin: The admin of the vault.
    /// - operator: The operator of the vault.
    /// - sub_accounts: The sub-accounts of the vault.
    public struct VaultCreatedEvent<phantom T, phantom R> has copy, drop, store {
        vault_id: ID,
        name: String,
        admin: address,
        operator: address,
        sub_accounts: vector<address>,
        min_withdrawal_shares: u64,
        max_rate_change_per_update: u64,
        fee_percentage: u64,
        rate_update_interval: u64,
        rate: u64,
        max_tvl: u64,
    }

    /// Event emitted when the max TVL of a vault is updated.
    /// 
    /// @dev This event is emitted when the max TVL of a vault is updated.
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_max_tvl: The previous max TVL of the vault.
    /// - new_max_tvl: The new max TVL of the vault.
    /// - sequence_number: The sequence number of the event.
    public struct VaultMaxTVLUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_max_tvl: u64,
        new_max_tvl: u64,
        sequence_number: u128,
    }

    /// Event emitted when the rate of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_rate: The previous rate of the vault.
    /// - new_rate: The new rate of the vault.
    public struct VaultRateUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_rate: u64,
        new_rate: u64,
        sequence_number: u128,
    }

    /// Event emitted when the admin of a vault is changed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_admin: The previous admin of the vault.
    /// - new_admin: The new admin of the vault.    
    public struct VaultAdminChangedEvent has copy, drop, store {
        vault_id: ID,
        previous_admin: address,
        new_admin: address,
        sequence_number: u128,
    }

    /// Event emitted when the operator of a vault is changed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_operator: The previous operator of the vault.
    /// - new_operator: The new operator of the vault.
    public struct VaultOperatorChangedEvent has copy, drop, store {
        vault_id: ID,
        previous_operator: address,
        new_operator: address,
        sequence_number: u128,
    }

    /// Event emitted when the max allowed fee percentage is updated.
    /// 
    /// Parameters:
    /// - previous_max_fee_percentage: The previous max allowed fee percentage.
    /// - new_max_fee_percentage: The new max allowed fee percentage.
    public struct MaxAllowedFeePercentageUpdatedEvent has copy, drop, store {
        previous_max_fee_percentage: u64,
        new_max_fee_percentage: u64,
    }

    /// Event emitted when the fee percentage of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_fee_percentage: The previous fee percentage of the vault.
    /// - new_fee_percentage: The new fee percentage of the vault.
    public struct VaultFeePercentageUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_fee_percentage: u64,
        new_fee_percentage: u64,
        sequence_number: u128,
    }

    /// Event emitted when the protocol fee is collected.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - collected_fee: The amount of fee collected.
    /// - current_vault_balance: The current balance of the vault.
    public struct ProtocolFeeCollectedEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        collected_fee: u64,
        current_vault_balance: u64,
        recipient: address,
        sequence_number: u128,
    }

    /// Event emitted when the paused status of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - status: True if the vault is paused, false if it is unpaused.
    public struct VaultPausedStatusUpdatedEvent has copy, drop, store {
        vault_id: ID,
        status: bool,
        sequence_number: u128,
    }

    /// Event emitted when the sub-accounts of a vault are updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_sub_accounts: The previous sub-accounts of the vault.
    /// - new_sub_accounts: The new sub-accounts of the vault.
    public struct VaultSubAccountUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_sub_accounts: vector<address>,
        new_sub_accounts: vector<address>,
        account: address,
        status: bool,
        sequence_number: u128,
    }

    /// Event emitted when the blacklisted accounts of a vault are updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_blacklisted: The previous blacklisted accounts of the vault.
    /// - new_blacklisted: The new blacklisted accounts of the vault.
    public struct VaultBlacklistedAccountUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_blacklisted: vector<address>,
        new_blacklisted: vector<address>,
        account: address,
        status: bool,
        sequence_number: u128,
    }

    /// Event emitted when a withdrawal is made without redeeming shares.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - sub_account: The sub-account that made the withdrawal.
    /// - previous_balance: The previous balance of the sub-account.
    public struct VaultWithdrawalWithoutRedeemingSharesEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        sub_account: address,
        previous_balance: u64,
        new_balance: u64,
        amount: u64,
        sequence_number: u128,
    }

    /// Event emitted when a deposit is made without minting shares.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - sub_account: The sub-account that made the deposit.
    /// - previous_balance: The previous balance of the sub-account.
    public struct VaultDepositWithoutMintingSharesEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        sub_account: address,
        previous_balance: u64,
        new_balance: u64,
        amount: u64,
        sequence_number: u128,
    }

    /// Event emitted when a deposit is made.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - owner: The owner of the deposit.
    /// - total_amount: The total amount of the deposit.
    public struct VaultDepositEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        owner: address,
        total_amount: u64,
        shares_minted: u64,
        previous_balance: u64,
        current_balance: u64,
        total_shares: u64,
        sequence_number: u128,
    }

    /// Event emitted when a request is redeemed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - owner: The owner of the request.
    /// - receiver: The receiver of the request.
    public struct RequestRedeemedEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        owner: address,
        receiver: address,
        shares: u64,
        timestamp: u64,
        total_shares: u64,
        total_shares_pending_to_burn: u64,
        sequence_number: u128,
    }

    /// Event emitted when the platform fee is charged.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - fee_amount: The amount of fee charged.
    /// - total_fee_accrued: The total amount of fee accrued.
    public struct VaultPlatformFeeChargedEvent has copy, drop, store {
        vault_id: ID,
        fee_amount: u64,
        total_fee_accrued: u64,
        last_charged_at: u64,
        sequence_number: u128,
    }

    /// Event emitted when a request is processed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - owner: The owner of the request.
    /// - receiver: The receiver of the request.
    public struct RequestProcessedEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        owner: address,
        receiver: address,
        shares: u64,
        withdraw_amount: u64,
        request_timestamp: u64,
        processed_timestamp: u64,
        request_sequence_number: u128,
        skipped: bool,
        cancelled: bool,
        total_shares: u64,
        total_shares_pending_to_burn: u64,
        sequence_number: u128,
    }

    /// Event emitted when the summary of processed requests is emitted.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - total_request_processed: The total number of requests processed.
    /// - requests_skipped: The number of requests skipped.
    public struct ProcessRequestsSummaryEvent has copy, drop, store {
        vault_id: ID,
        total_request_processed: u64,
        requests_skipped: u64,
        requests_cancelled: u64,
        total_shares_burnt: u64,
        total_amount_withdrawn: u64,
        total_shares: u64,
        total_shares_pending_to_burn: u64,
        rate: u64,
        sequence_number: u128,
    }

    /// Event emitted when the min withdrawal shares is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_min_withdrawal_shares: The previous min withdrawal shares.
    /// - new_min_withdrawal_shares: The new min withdrawal shares.
    public struct MinWithdrawalSharesUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_min_withdrawal_shares: u64,
        new_min_withdrawal_shares: u64,
        sequence_number: u128,
    }

    /// Event emitted when the rate update interval of a vault is changed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_interval: The previous rate update interval.
    /// - new_interval: The new rate update interval.
    public struct VaultRateUpdateIntervalChangedEvent has copy, drop, store {
        vault_id: ID,
        previous_interval: u64,
        new_interval: u64,
        sequence_number: u128,
    }   

    /// Event emitted when a request is cancelled.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - owner: The owner of the request.
    /// - sequence_number: The sequence number of the request.
    public struct RequestCancelledEvent has copy, drop, store {
        vault_id: ID,
        owner: address,
        sequence_number: u128,
        cancel_withdraw_request: vector<u128>,
    }

    /// Event emitted when the min rate interval is updated.

    /// 
    /// Parameters:
    /// - previous_min_rate_interval: The previous min rate interval.
    /// - new_min_rate_interval: The new min rate interval.
    public struct MinRateIntervalUpdateEvent has copy, drop, store {
        previous_min_rate_interval: u64,
        new_min_rate_interval: u64,
    }

    /// Event emitted when the max rate interval is updated.

    /// 
    /// Parameters:
    /// - previous_max_rate_interval: The previous max rate interval.
    /// - new_max_rate_interval: The new max rate interval.
    public struct MaxRateIntervalUpdateEvent has copy, drop, store {
        previous_max_rate_interval: u64,
        new_max_rate_interval: u64,
    }

    /// Event emitted when the default rate interval is updated.
    /// 
    /// Parameters:
    /// - previous_default_rate_interval: The previous default rate interval.
    /// - new_default_rate_interval: The new default rate interval.
    public struct DefaultRateIntervalUpdateEvent has copy, drop, store {
        previous_default_rate_interval: u64,
        new_default_rate_interval: u64,
    }

    /// Event emitted when the name of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_name: The previous name of the vault.
    /// - new_name: The new name of the vault.
    public struct VaultNameUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_name: String,
        new_name: String,
        sequence_number: u128,
    }

    /// Event emitted when the rate manager of a vault is updated.
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_manager: The previous rate manager of the vault.
    /// - new_manager: The new rate manager of the vault.
    public struct VaultRateManagerUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_manager: address,
        new_manager: address,
        sequence_number: u128,
    }

    /// Event emitted when the max rate change per update of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_max_rate_change_per_update: The previous max rate change per update of the vault.
    /// - new_max_rate_change_per_update: The new max rate change per update of the vault.
    public struct VaultMaxRateChangePerUpdateUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_max_rate_change_per_update: u64,
        new_max_rate_change_per_update: u64,
        sequence_number: u128,
    }

    // === Public Functions ===

    /// Emits an event when the protocol is paused or unpaused.
    /// 
    /// Parameters:
    /// - status: True if the protocol is paused, false if it is unpaused.
    public(package) fun emit_pause_non_admin_operations_event(status: bool) {
        emit(PauseNonAdminOperationsEvent { status });
    }

    /// Emits an event when the supported version is updated.
    /// 
    /// Parameters:
    /// - old_version: The previous supported version.
    /// - new_version: The new supported version.
    public(package) fun emit_supported_version_update_event(old_version: u64, new_version: u64) {
        emit(SupportedVersionUpdateEvent { old_version, new_version });
    }

    /// Emits an event when the platform fee recipient is updated.
    /// 
    /// Parameters:
    /// - previous_recipient: The previous platform fee recipient.
    /// - new_recipient: The new platform fee recipient.
    public(package) fun emit_platform_fee_recipient_update_event(previous_recipient: address, new_recipient: address) {
        emit(PlatformFeeRecipientUpdateEvent { previous_recipient, new_recipient });
    }

    /// Emits an event when the min rate is updated.
    /// 
    /// Parameters:
    /// - previous_min_rate: The previous min rate.
    /// - new_min_rate: The new min rate.
    public(package) fun emit_min_rate_update_event(previous_min_rate: u64, new_min_rate: u64) {
        emit(MinRateUpdateEvent { previous_min_rate, new_min_rate });
    }

    /// Emits an event when the max rate is updated.
    /// 
    /// Parameters:
    /// - previous_max_rate: The previous max rate.
    /// - new_max_rate: The new max rate.
    public(package) fun emit_max_rate_update_event(previous_max_rate: u64, new_max_rate: u64) {
        emit(MaxRateUpdateEvent { previous_max_rate, new_max_rate });
    }

    /// Emits an event when the default rate is updated.
    /// 
    /// Parameters:
    /// - previous_default_rate: The previous default rate.
    /// - new_default_rate: The new default rate.
    public(package) fun emit_default_rate_update_event(previous_default_rate: u64, new_default_rate: u64) {
        emit(DefaultRateUpdateEvent { previous_default_rate, new_default_rate });
    }

    /// Emits an event when a vault is created.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - name: The name of the vault.
    /// - admin: The admin of the vault.
    /// - operator: The operator of the vault.
    /// - sub_accounts: The sub-accounts of the vault.
    /// - min_withdrawal_shares: The minimum withdrawal shares of the vault.
    /// - fee_percentage: The fee percentage of the vault.
    /// - max_rate_change_per_update: The maximum rate change per update of the vault.
    /// - rate_update_interval: The rate update interval of the vault.
    /// - rate: The rate of the vault.
    /// - max_tvl: The maximum TVL of the vault.
    public(package) fun emit_vault_created_event<T, R>(vault_id: ID, name: String, admin: address, operator: address, sub_accounts: vector<address>, min_withdrawal_shares: u64, fee_percentage: u64, max_rate_change_per_update: u64, rate_update_interval: u64, rate: u64, max_tvl: u64) {
        emit(VaultCreatedEvent<T, R> { vault_id, name, admin, operator, sub_accounts, min_withdrawal_shares, fee_percentage, max_rate_change_per_update, rate_update_interval, rate, max_tvl });
    }

    /// Emits an event when the rate of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_rate: The previous rate of the vault.
    /// - new_rate: The new rate of the vault.
    public(package) fun emit_vault_rate_updated_event(vault_id: ID, previous_rate: u64, new_rate: u64, sequence_number: u128) {
        emit(VaultRateUpdatedEvent { vault_id, previous_rate, new_rate, sequence_number });
    }

    /// Emits an event when the admin of a vault is changed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_admin: The previous admin of the vault.
    /// - new_admin: The new admin of the vault.
    public(package) fun emit_vault_admin_changed_event(vault_id: ID, previous_admin: address, new_admin: address, sequence_number: u128) {
        emit(VaultAdminChangedEvent { vault_id, previous_admin, new_admin, sequence_number });
    }

    /// Emits an event when the operator of a vault is changed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_operator: The previous operator of the vault.
    /// - new_operator: The new operator of the vault.
    public(package) fun emit_vault_operator_changed_event(vault_id: ID, previous_operator: address, new_operator: address, sequence_number: u128) {
        emit(VaultOperatorChangedEvent { vault_id, previous_operator, new_operator, sequence_number });
    }

    /// Emits an event when the max allowed fee percentage is updated.
    /// 
    /// Parameters:
    /// - previous_max_fee_percentage: The previous max allowed fee percentage.
    /// - new_max_fee_percentage: The new max allowed fee percentage.
    public(package) fun emit_max_allowed_fee_percentage_updated_event(previous_max_fee_percentage: u64, new_max_fee_percentage: u64) {
        emit(MaxAllowedFeePercentageUpdatedEvent { previous_max_fee_percentage, new_max_fee_percentage });
    }

    /// Emits an event when the fee percentage of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_fee_percentage: The previous fee percentage of the vault.
    /// - new_fee_percentage: The new fee percentage of the vault.
    public(package) fun emit_vault_fee_percentage_updated_event(vault_id: ID, previous_fee_percentage: u64, new_fee_percentage: u64, sequence_number: u128) {
        emit(VaultFeePercentageUpdatedEvent { vault_id, previous_fee_percentage, new_fee_percentage, sequence_number });
    }

    /// Emits an event when the protocol fee is collected.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - collected_fee: The amount of fee collected.
    /// - current_vault_balance: The current balance of the vault.
    public(package)  fun emit_protocol_fee_collected_event<T>(vault_id: ID, collected_fee: u64, current_vault_balance: u64, recipient: address, sequence_number: u128) {
        emit(ProtocolFeeCollectedEvent<T> { vault_id, collected_fee, current_vault_balance, recipient, sequence_number });
    }

    /// Emits an event when the paused status of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - status: True if the vault is paused, false if it is unpaused.
    public(package)  fun emit_vault_paused_status_updated_event(vault_id: ID, status: bool, sequence_number: u128) {
        emit(VaultPausedStatusUpdatedEvent { vault_id, status, sequence_number });
    }

    /// Emits an event when the sub-accounts of a vault are updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_sub_accounts: The previous sub-accounts of the vault.
    /// - new_sub_accounts: The new sub-accounts of the vault.
    public(package)  fun emit_vault_sub_account_updated_event(vault_id: ID, previous_sub_accounts: vector<address>, new_sub_accounts: vector<address>, account: address, status: bool, sequence_number: u128) {
        emit(VaultSubAccountUpdatedEvent { vault_id, previous_sub_accounts, new_sub_accounts, account, status, sequence_number });
    }

    /// Emits an event when the blacklisted accounts of a vault are updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_blacklisted: The previous blacklisted accounts of the vault.
    /// - new_blacklisted: The new blacklisted accounts of the vault.   
    public(package)  fun emit_vault_blacklisted_account_updated_event(vault_id: ID, previous_blacklisted: vector<address>, new_blacklisted: vector<address>, account: address, status: bool, sequence_number: u128) {
        emit(VaultBlacklistedAccountUpdatedEvent { vault_id, previous_blacklisted, new_blacklisted, account, status, sequence_number });
    }

    /// Emits an event when a deposit is made without minting shares.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - sub_account: The sub-account that made the deposit.
    /// - previous_balance: The previous balance of the sub-account.
    public(package)  fun emit_vault_deposit_without_minting_shares_event<T>(vault_id: ID, sub_account: address, previous_balance: u64, new_balance: u64, amount: u64, sequence_number: u128) {
        emit(VaultDepositWithoutMintingSharesEvent<T> { vault_id, sub_account, previous_balance, new_balance, amount, sequence_number });
    }

    /// Emits an event when a deposit is made.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - owner: The owner of the deposit.
    /// - total_amount: The total amount of the deposit.
    public(package)  fun emit_vault_deposit_event<T>(vault_id: ID, owner: address, total_amount: u64, shares_minted: u64, previous_balance: u64, current_balance: u64, total_shares: u64, sequence_number: u128) {
        emit(VaultDepositEvent<T> { vault_id, owner, total_amount, shares_minted, previous_balance, current_balance, total_shares, sequence_number });
    }

    /// Emits an event when a request is redeemed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - owner: The owner of the request.
    /// - receiver: The receiver of the request.
    public(package)  fun emit_request_redeemed_event<T>(vault_id: ID, owner: address, receiver: address, shares: u64, timestamp: u64, total_shares: u64, total_shares_pending_to_burn: u64, sequence_number: u128) {
        emit(RequestRedeemedEvent<T> { vault_id, owner, receiver, shares, timestamp, total_shares, total_shares_pending_to_burn, sequence_number });
    }

    /// Emits an event when the platform fee is charged.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - fee_amount: The amount of fee charged.
    /// - total_fee_accrued: The total amount of fee accrued.
    public(package)  fun emit_vault_platform_fee_charged_event(vault_id: ID, fee_amount: u64, total_fee_accrued: u64, last_charged_at: u64, sequence_number: u128) {
        emit(VaultPlatformFeeChargedEvent { vault_id, fee_amount, total_fee_accrued, last_charged_at, sequence_number });
    }

    /// Emits an event when a withdrawal is made without redeeming shares.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - sub_account: The sub-account that made the withdrawal.
    /// - previous_balance: The previous balance of the sub-account.
    public(package)  fun emit_vault_withdrawal_without_redeeming_shares_event<T>(vault_id: ID, sub_account: address, previous_balance: u64, new_balance: u64, amount: u64, sequence_number: u128) {
        emit(VaultWithdrawalWithoutRedeemingSharesEvent<T> { vault_id, sub_account, previous_balance, new_balance, amount, sequence_number });
    }   

    /// Emits an event when a request is processed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - owner: The owner of the request.
    /// - receiver: The receiver of the request.
    public(package)  fun emit_request_processed_event<T>(vault_id: ID, owner: address, receiver: address, shares: u64, withdraw_amount: u64, request_timestamp: u64, processed_timestamp: u64, skipped: bool, cancelled: bool, total_shares: u64, total_shares_pending_to_burn: u64, sequence_number: u128, request_sequence_number: u128) {
        emit(RequestProcessedEvent<T> { vault_id, owner, receiver, shares, withdraw_amount, request_timestamp, processed_timestamp, skipped, cancelled, total_shares, total_shares_pending_to_burn, sequence_number, request_sequence_number });
    }   

    /// Emits an event when the summary of processed requests is emitted.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - total_request_processed: The total number of requests processed.
    /// - requests_skipped: The number of requests skipped. 
    public(package)  fun emit_process_requests_summary_event(vault_id: ID, total_request_processed: u64, requests_skipped: u64, requests_cancelled: u64, total_shares_burnt: u64, total_amount_withdrawn: u64, total_shares: u64, total_shares_pending_to_burn: u64, rate: u64, sequence_number: u128) {
        emit(ProcessRequestsSummaryEvent { vault_id, total_request_processed, requests_skipped, requests_cancelled, total_shares_burnt, total_amount_withdrawn, total_shares, total_shares_pending_to_burn, rate, sequence_number });
    }

    /// Emits an event when the min withdrawal shares is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_min_withdrawal_shares: The previous min withdrawal shares.
    /// - new_min_withdrawal_shares: The new min withdrawal shares.
    public(package)  fun emit_min_withdrawal_shares_updated_event(vault_id: ID, previous_min_withdrawal_shares: u64, new_min_withdrawal_shares: u64, sequence_number: u128) {
        emit(MinWithdrawalSharesUpdatedEvent { vault_id, previous_min_withdrawal_shares, new_min_withdrawal_shares, sequence_number });
    }

    /// Emits an event when the rate update interval of a vault is changed.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_interval: The previous rate update interval.
    /// - new_interval: The new rate update interval.
    public(package)  fun emit_vault_rate_update_interval_changed_event(vault_id: ID, previous_interval: u64, new_interval: u64, sequence_number: u128) {
        emit(VaultRateUpdateIntervalChangedEvent { vault_id, previous_interval, new_interval, sequence_number });
    }

    /// Emits an event when a request is cancelled.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - owner: The owner of the request.
    /// - sequence_number: The sequence number of the request.
    public(package)  fun emit_request_cancelled_event(vault_id: ID, owner: address, sequence_number: u128, cancel_withdraw_request: vector<u128>) {
        emit(RequestCancelledEvent { vault_id, owner, sequence_number, cancel_withdraw_request });
    }

    /// Emits an event when the min rate interval is updated.
    /// 
    /// Parameters:
    /// - previous_min_rate_interval: The previous min rate interval.
    /// - new_min_rate_interval: The new min rate interval.
    public(package) fun emit_min_rate_interval_update_event(previous_min_rate_interval: u64, new_min_rate_interval: u64) {
        emit(MinRateIntervalUpdateEvent { previous_min_rate_interval, new_min_rate_interval });
    }

    /// Emits an event when the max rate interval is updated.
    /// 
    /// Parameters:
    /// - previous_max_rate_interval: The previous max rate interval.
    /// - new_max_rate_interval: The new max rate interval.
    public(package) fun emit_max_rate_interval_update_event(previous_max_rate_interval: u64, new_max_rate_interval: u64) {
        emit(MaxRateIntervalUpdateEvent { previous_max_rate_interval, new_max_rate_interval });
    }

    /// Emits an event when the default rate interval is updated.
    /// 
    /// Parameters:
    /// - previous_default_rate_interval: The previous default rate interval.
    /// - new_default_rate_interval: The new default rate interval.
    public(package) fun emit_default_rate_interval_update_event(previous_default_rate_interval: u64, new_default_rate_interval: u64) {
        emit(DefaultRateIntervalUpdateEvent { previous_default_rate_interval, new_default_rate_interval });
    }

    /// Emits an event when the max TVL of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_max_tvl: The previous max TVL of the vault.
    /// - new_max_tvl: The new max TVL of the vault.
    /// - sequence_number: The sequence number of the event.
    public(package) fun emit_vault_max_tvl_updated_event(vault_id: ID, previous_max_tvl: u64, new_max_tvl: u64, sequence_number: u128) {
        emit(VaultMaxTVLUpdatedEvent { vault_id, previous_max_tvl, new_max_tvl, sequence_number });
    }

    /// Emits an event when the name of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_name: The previous name of the vault.
    /// - new_name: The new name of the vault.
    /// - sequence_number: The sequence number of the event.
    public(package) fun emit_vault_name_updated_event(vault_id: ID, previous_name: String, new_name: String, sequence_number: u128) {
        emit(VaultNameUpdatedEvent { vault_id, previous_name, new_name, sequence_number });
    }

    /// Emits an event when the rate manager of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_manager: The previous rate manager of the vault.
    /// - new_manager: The new rate manager of the vault.
    /// - sequence_number: The sequence number of the event.
    public(package) fun emit_vault_rate_manager_updated_event(vault_id: ID, previous_manager: address, new_manager: address, sequence_number: u128) {
        emit(VaultRateManagerUpdatedEvent { vault_id, previous_manager, new_manager, sequence_number });
    }

    /// Emits an event when the max rate change per update of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_max_rate_change_per_update: The previous max rate change per update of the vault.
    /// - new_max_rate_change_per_update: The new max rate change per update of the vault.
    /// - sequence_number: The sequence number of the event.
    public(package) fun emit_vault_max_rate_change_per_update_updated_event(vault_id: ID, previous_max_rate_change_per_update: u64, new_max_rate_change_per_update: u64, sequence_number: u128) {
        emit(VaultMaxRateChangePerUpdateUpdatedEvent { vault_id, previous_max_rate_change_per_update, new_max_rate_change_per_update, sequence_number });
    }

}