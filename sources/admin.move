/*
  Copyright (c) 2025 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code 
  requires prior written permission from the Ember Protocol Inc.
*/

module ember_vaults::admin {

    // === Imports ===

    use ember_vaults::events;
    use sui::dynamic_field;

    // === Errors ===

    // Error codes for admin module
    const EUnsupportedPackage: u64 = 1000;
    const EPackageAlreadySupported: u64 = 1001;
    const EInvalidRecipient: u64 = 1002;
    const EInvalidRate: u64 = 1003;
    const EInvalidFeePercentage: u64 = 1004;
    const EProtocolPaused: u64 = 1005;
    const EInvalidRateInterval: u64 = 1006;
    const ESameValue: u64 = 1007;
    /// Guardian-gated function invoked by an account that is not the current guardian
    /// (or guardian is unset). Mirrors the EVM `onlyGuardian` modifier semantics.
    const EUnauthorized: u64 = 1008;

    // === Dynamic-field keys ===

    /// Key under which the (optional) guardian address is stored on the ProtocolConfig
    /// object. Kept in a dynamic field rather than as a struct field so we can add the
    /// role in an upgrade without changing ProtocolConfig's on-chain layout.
    const KEY_GUARDIAN: vector<u8> = b"guardian";

    // === Constants ===

    /// Tracks the current version of the package. Every time a breaking change is pushed,
    /// increment the version on the new package, making any old version of the package
    /// unable to be used
    ///
    /// v6 (2026-05) — adds atomic_liquidity_vault, strategy.move (Suilend
    ///                supply-only),
    ///                common.move shared helpers, and new events. After
    ///                publishing this upgrade, run
    ///                `gateway::increase_supported_package_version` so the
    ///                ProtocolConfig.version advances from 5 → 6.
    const VERSION: u64 = 6;


    const MIN_RATE: u64 = 250000000; // 25%
    const MAX_RATE: u64 = 5000000000; // 500%
    const DEFAULT_RATE: u64 = 1000000000; // 100%
    const MIN_RATE_INTERVAL: u64 = 60 * 60 * 1000; // 1 hour
    const MAX_RATE_INTERVAL: u64 = 24 * 60 * 60 * 1000; // 1 day
    const MAX_FEE_PERCENTAGE: u64 = 100000000; // 10%

 

    // === Structs ===

    /// Represents an administrative capability for high-level management and control functions.
    public struct AdminCap has key, store {
        /// Unique identifier for the AdminCap.
        id: UID
    }

    /// The protocol's config object. This is passed as input to each contract call
    /// and is used to validate if the protocol version is supported or not
    public struct ProtocolConfig has key, store {
        // Sui object id
        id: UID,
        // current supported protocol version
        version: u64,
        // if set to true, ALL non-admin operations are paused
        pause_non_admin_operations: bool,
        // the account that will receive all platform fees accrued on the vaults
        platform_fee_recipient: address,
        // the min/max limits for the rate. The rate percentage must always be >= min_rate and <= max_rate
        min_rate: u64,
        max_rate: u64,
        //  the default rate set on a vault upon genesis
        default_rate: u64,

        // the minimum/maximum rate interval allowed to be set on a vault
        min_rate_interval: u64,
        max_rate_interval: u64,

        // the max fee percentage that can be charged on a vault (annually)
        max_fee_percentage: u64,
    }   

    // === Initialization ===

    /// Initializes the module by assigning the admin capability and protocol config.
    /// This function is only called during the module's setup phase, 
    /// ensuring that administrative privileges are correctly established. 
    ///
    /// Parameters:
    /// - ctx: Mutable reference to `TxContext`, the transaction context.
    fun init(ctx: &mut TxContext) {
        
        // Generate a new AdminCap object with a unique identifier.
        let admin_cap = AdminCap { id: object::new(ctx) };
        let admin_address =  ctx.sender();

        let protocol_config = ProtocolConfig { 
            id: object::new(ctx), 
            version: VERSION, 
            pause_non_admin_operations: false,
            platform_fee_recipient: admin_address,
            min_rate: MIN_RATE,
            max_rate: MAX_RATE,
            default_rate: DEFAULT_RATE,
            min_rate_interval: MIN_RATE_INTERVAL,
            max_rate_interval: MAX_RATE_INTERVAL,
            max_fee_percentage: MAX_FEE_PERCENTAGE,
        };

        // Transfer the AdminCap to the sender of the transaction.
        transfer::public_transfer(admin_cap, admin_address);
        transfer::public_share_object(protocol_config);
    }
   
    // === Public Functions ===

    /// Pauses or unpauses the non-admin operations
    ///
    /// Parameters:
    /// - config: The protocol config
    /// - _: The admin capability
    /// - pause: The status of the non-admin operations
    /// 
    /// Aborts with:
    /// - ESameValue: If the pause status is the same as the current pause status.
    public fun pause_non_admin_operations(config: &mut ProtocolConfig, _: &AdminCap, pause: bool) {
        verify_supported_package(config);
        assert!(pause != config.pause_non_admin_operations, ESameValue);
        config.pause_non_admin_operations = pause;
        events::emit_pause_non_admin_operations_event(pause);
    }

    // === Guardian ===

    /// Sets or clears the guardian address. AdminCap-gated (mirrors `setGuardian`
    /// on EVM's `EmberProtocolConfig`, which is `onlyOwner`). The guardian is an
    /// emergency-response role with a narrow surface — it can pause the protocol
    /// and pause / blacklist on individual vaults, but cannot rotate the guardian
    /// itself or upgrade the package.
    ///
    /// `@0x0` is the sentinel for "no guardian" and is a supported input value
    /// — passing it clears any current guardian. Once cleared, all
    /// guardian-gated functions abort with {EUnauthorized} until a non-zero
    /// guardian is set again. This gives the admin an explicit escape hatch:
    /// if the guardian key is compromised or a change of policy is needed,
    /// the admin can remove the role without needing a new one lined up.
    ///
    /// Storage lives in a dynamic field on the ProtocolConfig object so the
    /// role can be added without altering the struct layout of existing
    /// on-chain instances. `guardian_or_zero` treats an absent DF as `@0x0`.
    ///
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap (auth)
    /// - new_guardian: The new guardian address, or `@0x0` to unset
    ///
    /// Aborts with:
    /// - ESameValue: If `new_guardian` equals the current guardian (including
    ///   the "unset → unset" case where both are `@0x0`).
    public fun set_guardian(config: &mut ProtocolConfig, _: &AdminCap, new_guardian: address) {
        verify_supported_package(config);
        let previous = guardian_or_zero(config);
        assert!(previous != new_guardian, ESameValue);

        if (new_guardian == @0x0) {
            // Explicit unset: drop the dynamic field if present so subsequent
            // reads see the "no guardian" sentinel (`@0x0`).
            let _: address = dynamic_field::remove(&mut config.id, KEY_GUARDIAN);
        } else if (previous == @0x0) {
            // First set: no existing entry to remove.
            dynamic_field::add(&mut config.id, KEY_GUARDIAN, new_guardian);
        } else {
            // Rotate: drop the previous value and store the new one.
            let _: address = dynamic_field::remove(&mut config.id, KEY_GUARDIAN);
            dynamic_field::add(&mut config.id, KEY_GUARDIAN, new_guardian);
        };

        events::emit_guardian_updated_event(previous, new_guardian);
    }

    /// Guardian fast-path for `pause_non_admin_operations`. Semantically identical
    /// to the AdminCap-gated variant but callable directly by the guardian address
    /// (no capability needed). Mirrors `EmberProtocolConfig.guardianPauseNonAdminOperations`.
    ///
    /// Aborts with:
    /// - EUnauthorized: If the caller is not the currently-configured guardian
    ///   (also aborts if the guardian is unset).
    /// - ESameValue: If `pause` equals the current pause status.
    /// UPGRADE-WINDOW CAVEAT (L-07 follow-up): `verify_supported_package`
    /// couples this incident-response path to the upgrade state. While an
    /// upgrade is half-applied — new package published, `ProtocolConfig.version`
    /// not yet advanced — guardian tooling pinned to the NEW package id aborts
    /// with `EUnsupportedPackage` and must call through the retired package id
    /// until an admin runs `increase_supported_package_version`. Capture this
    /// in the upgrade runbook: the guardian pause is not reachable from the new
    /// package until the version bump lands.
    public fun guardian_pause_non_admin_operations(
        config: &mut ProtocolConfig,
        pause: bool,
        ctx: &TxContext,
    ) {
        verify_supported_package(config);
        verify_guardian(config, ctx);
        assert!(pause != config.pause_non_admin_operations, ESameValue);
        config.pause_non_admin_operations = pause;
        events::emit_pause_non_admin_operations_event(pause);
    }

    /// Returns the currently-configured guardian address, or `@0x0` if unset.
    /// (Not exposing `Option<address>` here keeps the ABI simple and matches
    /// the "guardian == address(0) means unset" convention used on EVM.)
    public fun get_guardian(config: &ProtocolConfig): address {
        guardian_or_zero(config)
    }

    /// Asserts that the transaction sender is the currently-configured guardian.
    /// Reverts with EUnauthorized if the guardian is unset OR the caller does
    /// not match. Public so that other modules (vault, atomic_liquidity_vault)
    /// can gate their own guardian fast-path functions.
    public fun verify_guardian(config: &ProtocolConfig, ctx: &TxContext) {
        let g = guardian_or_zero(config);
        assert!(g != @0x0 && ctx.sender() == g, EUnauthorized);
    }

    /// Internal helper: read guardian from the dynamic field, defaulting to
    /// `@0x0` if unset.
    fun guardian_or_zero(config: &ProtocolConfig): address {
        if (dynamic_field::exists_with_type<vector<u8>, address>(&config.id, KEY_GUARDIAN)) {
            *dynamic_field::borrow<vector<u8>, address>(&config.id, KEY_GUARDIAN)
        } else {
            @0x0
        }
    }

    /// Increases the version of the protocol supported. Only admin can invoke this.
    /// This method must be invoked from the new deployed package with increased version number
    /// 
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap to ensure the caller is the Admin of the protocol
    /// 
    /// Aborts with:
    /// - EPackageAlreadySupported: If the version is greater than the current version.
    public fun increase_supported_package_version(config: &mut ProtocolConfig, _: &AdminCap) {

        // ensures that config version is never increased beyond VERSION or
        // the method is not being invoked from an older package VERSION
        assert!(config.version < VERSION, EPackageAlreadySupported);

        increase_version(config);
    }

    /// Updates the platform fee recipient
    ///
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap to ensure the caller is the Admin of the protocol
    /// - recipient: The new platform fee recipient
    ///
    /// Aborts with:
    /// - EInvalidRecipient: If the recipient is the zero address
    public fun update_platform_fee_recipient(config: &mut ProtocolConfig, _: &AdminCap, recipient: address) {
        verify_supported_package(config);
        assert!(recipient != @0x0 && recipient != config.platform_fee_recipient, EInvalidRecipient);
        let previous_recipient = config.platform_fee_recipient;
        config.platform_fee_recipient = recipient;

        events::emit_platform_fee_recipient_update_event(previous_recipient, recipient);
    }


    /// Updates the min rate
    ///
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap to ensure the caller is the Admin of the protocol
    /// - min_rate: The new min rate
    ///
    /// Aborts with:
    /// - EInvalidRate: If the min rate is greater than the max rate
    public fun update_min_rate(config: &mut ProtocolConfig, _: &AdminCap, min_rate: u64) {
        verify_supported_package(config);
        assert!(min_rate > 0 && min_rate <= config.max_rate && min_rate <= config.default_rate && min_rate != config.min_rate, EInvalidRate);
        let previous_min_rate = config.min_rate;
        config.min_rate = min_rate;

        events::emit_min_rate_update_event(previous_min_rate, min_rate);
    }

    /// Updates the max rate
    ///
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap to ensure the caller is the Admin of the protocol
    /// - max_rate: The new max rate
    ///
    /// Aborts with:
    /// - EInvalidRate: If the max rate is less than the min rate
    public fun update_max_rate(config: &mut ProtocolConfig, _: &AdminCap, max_rate: u64) {
        verify_supported_package(config);
        assert!(max_rate >= config.min_rate && max_rate >= config.default_rate && max_rate != config.max_rate, EInvalidRate);
        let previous_max_rate = config.max_rate;
        config.max_rate = max_rate;

        events::emit_max_rate_update_event(previous_max_rate, max_rate);
    }


    /// Updates the default rate
    ///
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap to ensure the caller is the Admin of the protocol
    /// - default_rate: The new default rate
    ///
    /// Aborts with:
    /// - EInvalidRate: If the default rate is less than the min rate
    public fun update_default_rate(config: &mut ProtocolConfig, _: &AdminCap, default_rate: u64) {
        verify_supported_package(config);
        assert!(default_rate >= config.min_rate && default_rate <= config.max_rate && default_rate != config.default_rate, EInvalidRate);
        let previous_default_rate = config.default_rate;
        config.default_rate = default_rate;

        events::emit_default_rate_update_event(previous_default_rate, default_rate);
    }

    /// Updates the max fee percentage that can be charged on a vault
    ///
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap to ensure the caller is the Admin of the protocol
    /// - max_fee_percentage: The new max fee percentage
    ///
    /// Aborts with:
    /// - EInvalidFeePercentage: If the max fee percentage is greater than 100%
    public fun update_max_fee_percentage(config: &mut ProtocolConfig, _: &AdminCap, max_fee_percentage: u64) {
        verify_supported_package(config);
        assert!(max_fee_percentage <  1000000000 && max_fee_percentage != config.max_fee_percentage, EInvalidFeePercentage);
        let previous_max_fee_percentage = config.max_fee_percentage;
        config.max_fee_percentage = max_fee_percentage;
        events::emit_max_allowed_fee_percentage_updated_event(previous_max_fee_percentage, max_fee_percentage);
    }


    /// Updates the min rate interval
    ///
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap to ensure the caller is the Admin of the protocol
    /// - min_rate_interval: The new min rate interval
    ///
    /// Aborts with:
    /// - EInvalidRateInterval: If the min rate interval is greater than the min rate interval or less than 1 minute
    public fun update_min_rate_interval(config: &mut ProtocolConfig, _: &AdminCap, min_rate_interval: u64) {
        verify_supported_package(config);
        assert!(min_rate_interval >= 60 * 1000 && min_rate_interval <= config.max_rate_interval && min_rate_interval != config.min_rate_interval, EInvalidRateInterval);
        let previous_min_rate_interval = config.min_rate_interval;
        config.min_rate_interval = min_rate_interval;
        events::emit_min_rate_interval_update_event(previous_min_rate_interval, min_rate_interval);
    }


    /// Updates the max rate interval
    ///
    /// Parameters:
    /// - config: Mutable reference to protocol config
    /// - _: Immutable reference to admin cap to ensure the caller is the Admin of the protocol
    /// - max_rate_interval: The new max rate interval
    ///
    /// Aborts with:
    /// - EInvalidRateInterval: If the max rate interval is less than the min rate interval
    public fun update_max_rate_interval(config: &mut ProtocolConfig, _: &AdminCap, max_rate_interval: u64) {
        verify_supported_package(config);
        assert!(max_rate_interval >= config.min_rate_interval && max_rate_interval <= MAX_RATE_INTERVAL && max_rate_interval != config.max_rate_interval, EInvalidRateInterval);
        let previous_max_rate_interval = config.max_rate_interval;
        config.max_rate_interval = max_rate_interval;
        events::emit_max_rate_interval_update_event(previous_max_rate_interval, max_rate_interval);
    }

    // === View Functions ===

    /// Returns the current pause status of the protocol
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Returns:
    /// - The current pause status of the protocol
    public fun get_protocol_pause_status(config: &ProtocolConfig): bool {
        config.pause_non_admin_operations
    }

    /// Asserts if the config version matches the protocol version
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Aborts with:
    /// - EUnsupportedPackage: If the version does not match
    public fun verify_supported_package(config: &ProtocolConfig) {
        assert!(config.version == VERSION, EUnsupportedPackage)
    }

    /// Returns the platform fee recipient
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Returns:
    /// - The platform fee recipient
    public fun get_platform_fee_recipient(config: &ProtocolConfig): address {
        config.platform_fee_recipient
    }

    /// Returns the min rate
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Returns:
    /// - The min rate
    public fun get_min_rate(config: &ProtocolConfig): u64 {
        config.min_rate
    }

    /// Returns the max rate
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Returns:
    /// - The max rate
    public fun get_max_rate(config: &ProtocolConfig): u64 {
        config.max_rate
    }

    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Returns:
    /// - The default rate  
    public fun get_default_rate(config: &ProtocolConfig): u64 {
        config.default_rate
    }

    /// Returns the min rate interval
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Returns:
    /// - The min rate interval
    public fun get_min_rate_interval(config: &ProtocolConfig): u64 {
        config.min_rate_interval
    }

    /// Returns the max rate interval
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Returns:
    /// - The max rate interval
    public fun get_max_rate_interval(config: &ProtocolConfig): u64 {
        config.max_rate_interval
    }

    /// Returns the max allowed fee percentage that can be charged on a vault
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Returns:
    /// - The max allowed fee percentage
    public fun get_max_allowed_fee_percentage(config: &ProtocolConfig): u64 {
        config.max_fee_percentage
    }


    /// Asserts if the protocol is not paused
    ///
    /// Parameters:
    /// - config: The protocol config
    ///
    /// Aborts with:
    /// - EProtocolPaused: If the protocol is paused
    public fun verify_protocol_not_paused(config: &ProtocolConfig) {
        assert!(!config.pause_non_admin_operations, EProtocolPaused);
    }

    // === Internal Functions ===

    /// Increases the version of the protocol supported. Only admin can invoke this.
    /// This method must be invoked from the new deployed package with increased version number
    /// 
    /// Parameters:
    /// - config: Mutable reference to protocol config
    fun increase_version(config: &mut ProtocolConfig) {
        let old_version = config.version;        
        config.version = config.version + 1;
        events::emit_supported_version_update_event(old_version, config.version);
    }



    // === Test Only Functions ===

    #[test_only]
    public fun initialize_module(ctx: &mut TxContext) {
       init(ctx);
    }

    #[test_only]
    public fun increase_supported_package_version_for_testing(config: &mut ProtocolConfig) {
        increase_version(config);
    }
}