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

    // === Constants ===

    /// Tracks the current version of the package. Every time a breaking change is pushed, 
    /// increment the version on the new package, making any old version of the package 
    /// unable to be used
    const VERSION: u64 = 3;


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
        assert!(pause != config.pause_non_admin_operations, ESameValue);
        config.pause_non_admin_operations = pause;
        events::emit_pause_non_admin_operations_event(pause);
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