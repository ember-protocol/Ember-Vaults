/*
  Copyright (c) 2025 Ember Protocol Inc.
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

    /// Event emitted when the guardian address is set or cleared. `@0x0` in
    /// either field means "no guardian" (either the previous state was unset
    /// or the guardian has been cleared).
    ///
    /// Parameters:
    /// - previous: Previous guardian address (or `@0x0` if unset)
    /// - new: New guardian address (or `@0x0` if unset)
    public struct GuardianUpdatedEvent has copy, drop {
        previous: address,
        new: address,
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

    /// Event emitted when one of a (regular) vault's per-operation pause flags
    /// toggles. `operation` is one of `b"deposits"`, `b"withdrawals"`, or
    /// `b"privileged_operations"`. Distinct from {VaultPausedStatusUpdatedEvent},
    /// which is emitted by the legacy global-bit pause setter.
    public struct VaultOperationPausedUpdatedEvent has copy, drop, store {
        vault_id: ID,
        operation: String,
        paused: bool,
        sequence_number: u128,
    }

    /// Event emitted when the sub-accounts of a vault are updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_sub_accounts: The previous sub-accounts of the vault.
    /// - new_sub_accounts: The new sub-accounts of the vault.
    /// - account: The account that triggered the update.
    /// - status: The new status of the sub-account (added or removed).
    /// - sequence_number: The sequence number of the event.
    public struct VaultSubAccountUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_sub_accounts: vector<address>,
        new_sub_accounts: vector<address>,
        account: address,
        status: bool,
        sequence_number: u128,
    }


    /// Event emitted when the deposit user list of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_deposit_users: The previous deposit users of the vault.
    /// - new_deposit_users: The new deposit users of the vault.
    /// - account: The account that triggered the update.
    /// - status: The new status of the deposit user (added or removed).
    /// - sequence_number: The sequence number of the event.
    public struct VaultDepositUserListUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_deposit_users: vector<address>,
        new_deposit_users: vector<address>,
        account: address,
        status: bool,
        sequence_number: u128,
    }


    /// Event emitted when the vault fee exempt list of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_fee_exempt_users: The previous fee exempt users of the vault.
    /// - new_fee_exempt_users: The new fee exempt users of the vault.
    /// - account: The account that triggered the update.
    /// - status: The new status of the fee exempt user (added or removed).
    /// - sequence_number: The sequence number of the event.
    public struct VaultFeeExemptListUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_fee_exempt_users: vector<address>,
        new_fee_exempt_users: vector<address>,
        account: address,
        status: bool,
        sequence_number: u128,
    }

    /// Event emitted when the permanent fee percentage of a vault's withdrawal fee is updated.
    public struct VaultPermanentFeePercentageUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_permanent_fee_percentage: u64,
        new_permanent_fee_percentage: u64,
        sequence_number: u128,
    }

    /// Event emitted when the time based fee percentage of a vault's withdrawal fee is updated.
    public struct VaultTimeBasedFeePercentageUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_time_based_fee_percentage: u64,
        new_time_based_fee_percentage: u64,
        sequence_number: u128,
    }

    /// Event emitted when the time based fee threshold of a vault's withdrawal fee is updated.
    public struct VaultTimeBasedFeeThresholdUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_time_based_fee_threshold: u64,
        new_time_based_fee_threshold: u64,
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
    /// - sub_account: The allowlisted sub-account the OPERATOR attributed this
    ///   deposit to. Not authenticated: neither TTO nor accumulator funds carry
    ///   sender provenance, so this is a descriptive label rather than proof of
    ///   origin (I-12). Do not build per-sub-account accounting on it without
    ///   adding source-bound evidence upstream.
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

    /// Event emitted when withdrawal fees are charged for a processed request.
    public struct WithdrawalFeeChargedEvent has copy, drop, store {
        vault_id: ID,
        owner: address,
        request_sequence_number: u128,
        permanent_fee_charged: u64,
        time_based_fee_charged: u64,
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

    /// Emits an event when the guardian address is set or cleared.
    public(package) fun emit_guardian_updated_event(previous: address, new: address) {
        emit(GuardianUpdatedEvent { previous, new });
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

    /// Emits an event when one of a (regular) vault's per-operation pause flags toggles.
    public(package) fun emit_vault_operation_paused_updated_event(
        vault_id: ID,
        operation: String,
        paused: bool,
        sequence_number: u128,
    ) {
        emit(VaultOperationPausedUpdatedEvent { vault_id, operation, paused, sequence_number });
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

    /// Emits an event when the deposit user list of a vault is updated.
    /// 
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_deposit_users: The previous deposit users of the vault.
    /// - new_deposit_users: The new deposit users of the vault.
    public(package)  fun emit_vault_deposit_user_list_updated_event(vault_id: ID, previous_deposit_users: vector<address>, new_deposit_users: vector<address>, account: address, status: bool, sequence_number: u128) {
        emit(VaultDepositUserListUpdatedEvent { vault_id, previous_deposit_users, new_deposit_users, account, status, sequence_number });
    }


    /// Emits an event when the fee exempt list of a vault is updated.
    ///
    /// Parameters:
    /// - vault_id: The ID of the vault.
    /// - previous_fee_exempt_users: The previous fee exempt users of the vault.
    /// - new_fee_exempt_users: The new fee exempt users of the vault.
    public(package)  fun emit_vault_fee_exempt_list_updated_event(vault_id: ID, previous_fee_exempt_users: vector<address>, new_fee_exempt_users: vector<address>, account: address, status: bool, sequence_number: u128) {
        emit(VaultFeeExemptListUpdatedEvent { vault_id, previous_fee_exempt_users, new_fee_exempt_users, account, status, sequence_number });
    }

    /// Emits an event when the permanent fee percentage of a vault's withdrawal fee is updated.
    public(package) fun emit_vault_permanent_fee_percentage_updated_event(vault_id: ID, previous_permanent_fee_percentage: u64, new_permanent_fee_percentage: u64, sequence_number: u128) {
        emit(VaultPermanentFeePercentageUpdatedEvent { vault_id, previous_permanent_fee_percentage, new_permanent_fee_percentage, sequence_number });
    }

    /// Emits an event when the time based fee percentage of a vault's withdrawal fee is updated.
    public(package) fun emit_vault_time_based_fee_percentage_updated_event(vault_id: ID, previous_time_based_fee_percentage: u64, new_time_based_fee_percentage: u64, sequence_number: u128) {
        emit(VaultTimeBasedFeePercentageUpdatedEvent { vault_id, previous_time_based_fee_percentage, new_time_based_fee_percentage, sequence_number });
    }

    /// Emits an event when the time based fee threshold of a vault's withdrawal fee is updated.
    public(package) fun emit_vault_time_based_fee_threshold_updated_event(vault_id: ID, previous_time_based_fee_threshold: u64, new_time_based_fee_threshold: u64, sequence_number: u128) {
        emit(VaultTimeBasedFeeThresholdUpdatedEvent { vault_id, previous_time_based_fee_threshold, new_time_based_fee_threshold, sequence_number });
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
    /// - sub_account: The allowlisted sub-account the OPERATOR attributed this
    ///   deposit to. Not authenticated: neither TTO nor accumulator funds carry
    ///   sender provenance, so this is a descriptive label rather than proof of
    ///   origin (I-12). Do not build per-sub-account accounting on it without
    ///   adding source-bound evidence upstream.
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

    /// Emits an event when withdrawal fees are charged while processing a request.
    public(package) fun emit_withdrawal_fee_charged_event(vault_id: ID, owner: address, request_sequence_number: u128, permanent_fee_charged: u64, time_based_fee_charged: u64) {
        emit(WithdrawalFeeChargedEvent { vault_id, owner, request_sequence_number, permanent_fee_charged, time_based_fee_charged });
    }

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


    // ===========================================================================
    // === Atomic Liquidity Vault Events                                       ===
    // ===========================================================================
    //
    // The atomic_liquidity_vault module reuses the role/rate/fee/sub-account/
    // deposit/redeem/process events declared above (keyed by `vault_id: ID`).
    // The events declared in this section are either atomic-vault-specific or
    // have a different shape from their `vault.move` counterpart (e.g. a 3-flag
    // pause status vs. a single `paused: bool`).

    /// Event emitted when an atomic liquidity vault is created. Mirrors
    /// VaultCreatedEvent but is single-typed (no receipt-token type R) since
    /// atomic vault shares live in an internal table rather than a Coin<R>.
    public struct AtomicVaultCreatedEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        name: String,
        admin: address,
        operator: address,
        rate_manager: address,
        sub_accounts: vector<address>,
        min_withdrawal_shares: u64,
        fee_percentage: u64,
        max_rate_change_per_update: u64,
        rate_update_interval: u64,
        rate: u64,
        max_tvl: u64,
    }

    /// Event emitted when one of the atomic vault's three pause flags toggles.
    /// `operation` is one of `b"deposits"`, `b"withdrawals"`, or
    /// `b"privileged_operations"`.
    public struct AtomicVaultPauseStatusUpdatedEvent has copy, drop, store {
        vault_id: ID,
        operation: String,
        paused: bool,
        sequence_number: u128,
    }

    /// Event emitted when the active strategy tag of an atomic vault changes.
    /// `0 = none`, `1 = suilend`. Switching strategies does
    /// not auto-migrate funds — the operator must withdraw fully from the old
    /// strategy before this event fires.
    public struct StrategyUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_strategy: u8,
        new_strategy: u8,
        sequence_number: u128,
    }

    /// Event emitted when the operator supplies idle vault assets into the
    /// configured external strategy.
    public struct StrategySuppliedEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        strategy: u8,
        assets_supplied: u64,
        sequence_number: u128,
    }

    /// Event emitted when assets are pulled back from the external strategy
    /// into the atomic vault. Triggered by both operator-initiated withdrawals
    /// and the auto-pull liquidity path inside `instant_withdraw` and
    /// `release_users_holdback`.
    public struct StrategyWithdrawnEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        strategy: u8,
        assets_withdrawn: u64,
        sequence_number: u128,
    }

    /// Event emitted when accrued strategy rewards of coin type `C` are
    /// collected from the vault's position and forwarded to `recipient`. `C`
    /// carries the reward token type.
    ///
    /// `strategy` identifies which strategy the reward came from; only Suilend
    /// emits it today. `recipient` is an allowlisted vault
    /// sub-account, never the protocol platform-fee recipient: rewards are
    /// vault-earned value and a sub-account is the only destination with a route
    /// back into `vault.balance`.
    ///
    /// Indexers: this is the outbound half only. The return leg is a separate
    /// `deposit_from_sub_account`, unlinked on chain, so pairing them is a
    /// monitoring exercise rather than something the events guarantee.
    public struct StrategyRewardCollectedEvent<phantom C> has copy, drop, store {
        vault_id: ID,
        strategy: u8,
        amount: u64,
        recipient: address,
        sequence_number: u128,
    }

    /// Event emitted when the vault opens its Suilend obligation. Carries
    /// `obligation_id` so an indexer can resolve the object the deposit and the
    /// reward accounting live under — the obligation sits in the lending
    /// market's `ObjectTable` and is not otherwise derivable from vault state.
    public struct SuilendObligationOpenedEvent has copy, drop, store {
        vault_id: ID,
        market_id: ID,
        obligation_id: ID,
        reserve_array_index: u64,
        sequence_number: u128,
    }

    /// Event emitted when a user burns shares for an immediate (capped, fee-
    /// charged) collateral payout via `instant_withdraw`.
    public struct InstantWithdrawnEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        owner: address,
        receiver: address,
        shares_burnt: u64,
        gross_amount: u64,
        fee_amount: u64,
        net_amount: u64,
        cumulative_instant_withdraw_shares: u64,
        total_shares: u64,
        sequence_number: u128,
    }

    /// Event emitted when admin raises (or lowers) the cumulative instant
    /// withdraw cap. Setting `new_max` below `cumulative_instant_withdraw_shares`
    /// effectively halts further instant withdrawals until raised again.
    public struct InstantWithdrawLimitUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_max: u64,
        new_max: u64,
        cumulative_instant_withdraw_shares: u64,
        sequence_number: u128,
    }

    /// Event emitted when admin updates the instant-withdraw fee percentage
    /// (1e9 = 100%). Fee is deducted from the gross asset payout and accrues
    /// into platform_fee.
    public struct InstantWithdrawFeeUpdatedEvent has copy, drop, store {
        vault_id: ID,
        previous_fee_percentage: u64,
        new_fee_percentage: u64,
        sequence_number: u128,
    }

    /// Event emitted when admin whitelists (or de-lists) an Ember vault's
    /// receipt token for the cross-vault instant-swap feature, or updates its
    /// fee / capacity / holdback / utilization / dust-floor / absolute-cap
    /// parameters.
    public struct EmberShareWhitelistUpdatedEvent has copy, drop, store {
        vault_id: ID,
        share_vault_id: ID,
        whitelisted: bool,
        fee_percentage: u64,
        max_capacity_percentage: u64,
        holdback_percentage: u64,
        max_utilization_percentage: u64,
        /// Dust floor: minimum gross-collateral value for a single swap.
        /// `0` disables the floor.
        min_swap_gross: u64,
        /// TVL-independent absolute ceiling on the post-swap held-value of
        /// this source share. `0` disables the absolute cap.
        max_held_value_absolute: u64,
        sequence_number: u128,
    }

    /// Event emitted when admin updates an EmberShare's concentration cap
    /// (`max_utilization_percentage`).
    public struct EmberShareUtilizationUpdatedEvent has copy, drop, store {
        vault_id: ID,
        share_vault_id: ID,
        previous_max_utilization: u64,
        new_max_utilization: u64,
        sequence_number: u128,
    }

    /// Event emitted when admin inserts or updates a tier on the per-share
    /// fee-multiplier curve.
    public struct EmberShareFeeMultiplierTierSetEvent has copy, drop, store {
        vault_id: ID,
        share_vault_id: ID,
        threshold: u64,
        multiplier: u64,
        sequence_number: u128,
    }

    /// Event emitted when admin removes a tier from the per-share
    /// fee-multiplier curve.
    public struct EmberShareFeeMultiplierTierRemovedEvent has copy, drop, store {
        vault_id: ID,
        share_vault_id: ID,
        threshold: u64,
        sequence_number: u128,
    }

    /// Event emitted when admin sets fee / holdback waiver flags for an account
    /// on the atomic vault. The two waivers are independent — an account can be
    /// on neither, one, or both lists.
    public struct SwapWaiverUpdatedEvent has copy, drop, store {
        vault_id: ID,
        account: address,
        fee_waived: bool,
        holdback_waived: bool,
        sequence_number: u128,
    }

    /// Event emitted when a user atomically swaps an Ember vault's receipt
    /// token for the atomic vault's underlying collateral.
    public struct EmberShareSwappedEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        share_vault_id: ID,
        owner: address,
        receiver: address,
        share_amount: u64,
        gross_amount: u64,
        fee_amount: u64,
        /// Holdback actually withheld and queued as a `HoldbackEntry`. Zero
        /// when the waiver applies — see `waived_holdback`.
        holdback_amount: u64,
        /// Holdback the curve computed before any waiver, i.e. what a
        /// non-waived swapper would have had withheld. `holdback_amount +
        /// waived_holdback == computed_holdback` always.
        computed_holdback: u64,
        /// The computed holdback that was NOT withheld and was therefore paid
        /// immediately. The waiver is keyed on `owner` (the swap's
        /// `ctx.sender()`), NOT on `receiver` — see the
        /// `holdback_waived_addresses` lookup in both the swap core and
        /// `preview_swap_ember_shares`.
        waived_holdback: u64,
        /// Collateral actually transferred to `receiver` by this swap. This is
        /// the figure to sum for outflow. Replaces the old `net_amount`, which
        /// was `gross - fee - computed_holdback` and so under-reported the
        /// transfer for a holdback-waived receiver (I-06), and could also
        /// overstate it by the tolerated dust shortfall (L-06).
        actual_paid: u64,
        epoch_used_amount: u64,
        /// Post-swap utilization for this share, in 1e9 fixed-point.
        /// Computed as
        /// `floor((custodied_shares + pending_shares + incoming_shares) / source_rate)
        ///  / atomic_vault_tvl`.
        /// NOTE the single conversion: since L-04 the combined share position is
        /// converted to collateral once, rather than converting the existing
        /// position and `gross_amount` separately and summing. An indexer
        /// reimplementing the old formula disagrees with this field by one
        /// collateral base unit at exactly the tier boundary the fix exists to
        /// catch.
        utilization_at_swap: u64,
        /// Multiplier selected from `EmberShareConfig.fee_multiplier_curve`
        /// at `utilization_at_swap`. 1e9 = 1x (no scaling). The
        /// `fee_amount` field above is already `gross_amount * base_fee_pct
        /// * fee_multiplier_applied / 1e18` — indexers can verify.
        fee_multiplier_applied: u64,
        sequence_number: u128,
    }

    /// Event emitted when the operator settles a FIFO batch of holdback
    /// entries. `unwinding_percentage` is in 1e9 fixed-point: 1e9 = full
    /// holdback paid; below 1e9 socializes losses.
    public struct HoldbackReleasedEvent has copy, drop, store {
        vault_id: ID,
        share_vault_id: ID,
        unwinding_percentage: u64,
        entries_processed: u64,
        /// Subset of `entries_processed` skipped because the recipient was on
        /// the vault's blacklist at settle time. Skipped entries forfeit their
        /// holdback (collateral stays in the vault) and the head advances past
        /// them — this is the resolution path when a recipient can no longer
        /// receive collateral (e.g. off-chain compliance). Without the skip,
        /// a single stuck recipient at the head would freeze every later
        /// release for this share.
        entries_skipped: u64,
        total_released: u64,
        new_queue_start_index: u64,
        /// Sequence numbers of the oldest and newest holdback entries settled by
        /// this release (the contiguous FIFO block consumed). Lets consumers mark
        /// exactly these entries without relying on the queue index. Both 0 when
        /// entries_processed is 0.
        released_from_sequence_number: u128,
        released_to_sequence_number: u128,
        sequence_number: u128,
    }

    /// Event emitted when the operator forwards collected Ember shares (held
    /// by the atomic vault from prior `swap_ember_shares` calls) into the
    /// originating Ember vault's redemption queue.
    public struct EmberSharesRedemptionInitiatedEvent has copy, drop, store {
        vault_id: ID,
        share_vault_id: ID,
        amount: u64,
        remaining_share_balance: u64,
        sequence_number: u128,
    }

    /// Event emitted when an atomic vault operator collects accrued platform
    /// fees. `loss` is subtracted from `vault.fee.accrued` BEFORE the transfer
    /// to absorb off-vault losses (e.g. strategy shortfalls). Only
    /// `collected_fee` collateral is transferred to `recipient`; the total
    /// settled out of `fee.accrued` is `collected_fee + loss`. Atomic-vault
    /// only — `vault.move` continues to emit `ProtocolFeeCollectedEvent<T>`.
    public struct AtomicProtocolFeeCollectedEvent<phantom T> has copy, drop, store {
        vault_id: ID,
        collected_fee: u64,
        loss: u64,
        current_vault_balance: u64,
        recipient: address,
        sequence_number: u128,
    }

    /// Event emitted when an atomic vault re-ingests source-vault receipt
    /// shares that the source returned via TTO on a skipped request (e.g.
    /// cancelled, blacklisted-recipient, or zero-amount processing). The
    /// shares are joined back into the per-source `CollectedEmberSharesKey`
    /// dynamic field so they're available for a subsequent
    /// `redeem_collected_ember_shares` retry.
    public struct EmberSharesReturnedEvent<phantom R> has copy, drop, store {
        vault_id: ID,
        share_vault_id: ID,
        amount: u64,
        new_held_share_balance: u64,
        sequence_number: u128,
    }

    // === Atomic Liquidity Vault emit functions ===

    public(package) fun emit_atomic_vault_created_event<T>(
        vault_id: ID,
        name: String,
        admin: address,
        operator: address,
        rate_manager: address,
        sub_accounts: vector<address>,
        min_withdrawal_shares: u64,
        fee_percentage: u64,
        max_rate_change_per_update: u64,
        rate_update_interval: u64,
        rate: u64,
        max_tvl: u64,
    ) {
        emit(AtomicVaultCreatedEvent<T> {
            vault_id, name, admin, operator, rate_manager, sub_accounts,
            min_withdrawal_shares, fee_percentage, max_rate_change_per_update,
            rate_update_interval, rate, max_tvl,
        });
    }

    public(package) fun emit_atomic_vault_pause_status_updated_event(
        vault_id: ID, operation: String, paused: bool, sequence_number: u128,
    ) {
        emit(AtomicVaultPauseStatusUpdatedEvent { vault_id, operation, paused, sequence_number });
    }

    public(package) fun emit_strategy_updated_event(
        vault_id: ID, previous_strategy: u8, new_strategy: u8, sequence_number: u128,
    ) {
        emit(StrategyUpdatedEvent { vault_id, previous_strategy, new_strategy, sequence_number });
    }

    public(package) fun emit_strategy_supplied_event<T>(
        vault_id: ID, strategy: u8, assets_supplied: u64, sequence_number: u128,
    ) {
        emit(StrategySuppliedEvent<T> { vault_id, strategy, assets_supplied, sequence_number });
    }

    public(package) fun emit_strategy_withdrawn_event<T>(
        vault_id: ID, strategy: u8, assets_withdrawn: u64, sequence_number: u128,
    ) {
        emit(StrategyWithdrawnEvent<T> { vault_id, strategy, assets_withdrawn, sequence_number });
    }

    public(package) fun emit_strategy_reward_collected_event<C>(
        vault_id: ID, strategy: u8, amount: u64, recipient: address, sequence_number: u128,
    ) {
        emit(StrategyRewardCollectedEvent<C> { vault_id, strategy, amount, recipient, sequence_number });
    }

    public(package) fun emit_suilend_obligation_opened_event(
        vault_id: ID,
        market_id: ID,
        obligation_id: ID,
        reserve_array_index: u64,
        sequence_number: u128,
    ) {
        emit(SuilendObligationOpenedEvent {
            vault_id, market_id, obligation_id, reserve_array_index, sequence_number,
        });
    }

    public(package) fun emit_instant_withdrawn_event<T>(
        vault_id: ID,
        owner: address,
        receiver: address,
        shares_burnt: u64,
        gross_amount: u64,
        fee_amount: u64,
        net_amount: u64,
        cumulative_instant_withdraw_shares: u64,
        total_shares: u64,
        sequence_number: u128,
    ) {
        emit(InstantWithdrawnEvent<T> {
            vault_id, owner, receiver, shares_burnt, gross_amount, fee_amount,
            net_amount, cumulative_instant_withdraw_shares, total_shares, sequence_number,
        });
    }

    public(package) fun emit_instant_withdraw_limit_updated_event(
        vault_id: ID, previous_max: u64, new_max: u64,
        cumulative_instant_withdraw_shares: u64, sequence_number: u128,
    ) {
        emit(InstantWithdrawLimitUpdatedEvent {
            vault_id, previous_max, new_max, cumulative_instant_withdraw_shares, sequence_number,
        });
    }

    public(package) fun emit_instant_withdraw_fee_updated_event(
        vault_id: ID, previous_fee_percentage: u64, new_fee_percentage: u64, sequence_number: u128,
    ) {
        emit(InstantWithdrawFeeUpdatedEvent {
            vault_id, previous_fee_percentage, new_fee_percentage, sequence_number,
        });
    }

    public(package) fun emit_ember_share_whitelist_updated_event(
        vault_id: ID,
        share_vault_id: ID,
        whitelisted: bool,
        fee_percentage: u64,
        max_capacity_percentage: u64,
        holdback_percentage: u64,
        max_utilization_percentage: u64,
        min_swap_gross: u64,
        max_held_value_absolute: u64,
        sequence_number: u128,
    ) {
        emit(EmberShareWhitelistUpdatedEvent {
            vault_id, share_vault_id, whitelisted, fee_percentage,
            max_capacity_percentage, holdback_percentage,
            max_utilization_percentage, min_swap_gross, max_held_value_absolute,
            sequence_number,
        });
    }

    public(package) fun emit_ember_share_utilization_updated_event(
        vault_id: ID,
        share_vault_id: ID,
        previous_max_utilization: u64,
        new_max_utilization: u64,
        sequence_number: u128,
    ) {
        emit(EmberShareUtilizationUpdatedEvent {
            vault_id, share_vault_id, previous_max_utilization,
            new_max_utilization, sequence_number,
        });
    }

    public(package) fun emit_ember_share_fee_multiplier_tier_set_event(
        vault_id: ID,
        share_vault_id: ID,
        threshold: u64,
        multiplier: u64,
        sequence_number: u128,
    ) {
        emit(EmberShareFeeMultiplierTierSetEvent {
            vault_id, share_vault_id, threshold, multiplier, sequence_number,
        });
    }

    public(package) fun emit_ember_share_fee_multiplier_tier_removed_event(
        vault_id: ID,
        share_vault_id: ID,
        threshold: u64,
        sequence_number: u128,
    ) {
        emit(EmberShareFeeMultiplierTierRemovedEvent {
            vault_id, share_vault_id, threshold, sequence_number,
        });
    }

    public(package) fun emit_swap_waiver_updated_event(
        vault_id: ID, account: address, fee_waived: bool, holdback_waived: bool, sequence_number: u128,
    ) {
        emit(SwapWaiverUpdatedEvent { vault_id, account, fee_waived, holdback_waived, sequence_number });
    }

    public(package) fun emit_ember_share_swapped_event<T>(
        vault_id: ID,
        share_vault_id: ID,
        owner: address,
        receiver: address,
        share_amount: u64,
        gross_amount: u64,
        fee_amount: u64,
        holdback_amount: u64,
        computed_holdback: u64,
        waived_holdback: u64,
        actual_paid: u64,
        epoch_used_amount: u64,
        utilization_at_swap: u64,
        fee_multiplier_applied: u64,
        sequence_number: u128,
    ) {
        emit(EmberShareSwappedEvent<T> {
            vault_id, share_vault_id, owner, receiver, share_amount, gross_amount,
            fee_amount, holdback_amount, computed_holdback, waived_holdback,
            actual_paid, epoch_used_amount,
            utilization_at_swap, fee_multiplier_applied, sequence_number,
        });
    }

    public(package) fun emit_holdback_released_event(
        vault_id: ID,
        share_vault_id: ID,
        unwinding_percentage: u64,
        entries_processed: u64,
        entries_skipped: u64,
        total_released: u64,
        new_queue_start_index: u64,
        released_from_sequence_number: u128,
        released_to_sequence_number: u128,
        sequence_number: u128,
    ) {
        emit(HoldbackReleasedEvent {
            vault_id, share_vault_id, unwinding_percentage, entries_processed,
            entries_skipped, total_released, new_queue_start_index,
            released_from_sequence_number, released_to_sequence_number,
            sequence_number,
        });
    }

    public(package) fun emit_ember_shares_redemption_initiated_event(
        vault_id: ID, share_vault_id: ID, amount: u64,
        remaining_share_balance: u64, sequence_number: u128,
    ) {
        emit(EmberSharesRedemptionInitiatedEvent {
            vault_id, share_vault_id, amount, remaining_share_balance, sequence_number,
        });
    }

    public(package) fun emit_atomic_protocol_fee_collected_event<T>(
        vault_id: ID,
        collected_fee: u64,
        loss: u64,
        current_vault_balance: u64,
        recipient: address,
        sequence_number: u128,
    ) {
        emit(AtomicProtocolFeeCollectedEvent<T> {
            vault_id, collected_fee, loss, current_vault_balance, recipient, sequence_number,
        });
    }

    public(package) fun emit_ember_shares_returned_event<R>(
        vault_id: ID,
        share_vault_id: ID,
        amount: u64,
        new_held_share_balance: u64,
        sequence_number: u128,
    ) {
        emit(EmberSharesReturnedEvent<R> {
            vault_id, share_vault_id, amount, new_held_share_balance, sequence_number,
        });
    }

}