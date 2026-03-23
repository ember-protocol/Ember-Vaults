#[test_only]
module ember_vaults::test_charge_accrued_platform_fees {

    // === Imports ===
    use sui::test_scenario::{Self};
    use sui::clock::{Self};

    use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
    use ember_vaults::vault::{Self, Vault};
    use ember_vaults::admin::{ProtocolConfig};

    // === Test Constants ===
    const FEE_DENOMINATOR: u128 = 31_536_000_000_000_000_000; // 1e9 * 365 days * 24 hours * 60 minutes * 60 seconds * 1000 milliseconds (must match vault.move)
    const ONE_DAY_MS: u64 = 86_400_000; // 24 hours in milliseconds
    const ONE_HOUR_MS: u64 = 3_600_000; // 1 hour in milliseconds
    const TEN_MINUTES_MS: u64 = 600_000; // 10 minutes in milliseconds
    const INITIAL_TIMESTAMP: u64 = 10000000000; // Starting timestamp (must be >= deposit timestamp in test_utils)

    // === Helper Functions ===

    /// Calculate expected fee for given parameters
    /// Uses u128 for intermediate calculations to prevent overflow (matches vault implementation)
    fun calculate_expected_fee(tvl: u64, fee_percentage: u64, elapsed_time_ms: u64): u64 {
        let numerator = (tvl as u128) * (fee_percentage as u128) * (elapsed_time_ms as u128);
        ((numerator / FEE_DENOMINATOR) as u64)
    }

    /// Initialize fee charging timestamp to avoid overflow
    fun initialize_fee_timestamp(scenario: &mut test_scenario::Scenario, timestamp: u64) {
        let protocol_admin = test_utils::protocol_admin();
        test_scenario::next_tx(scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(scenario));
            
            clock::set_for_testing(&mut clock, timestamp);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };
    }

    // === Success Test Cases ===

    #[test]
    fun test_charge_fee_after_one_day() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets to create TVL
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        // Charge fee after one day
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_accrued = vault::get_accrued_platform_fee(&vault);
            let initial_seq = vault::get_vault_sequence_number(&vault);
            let tvl = vault::get_vault_tvl(&vault);
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            
            // Move time forward by one day from INITIAL_TIMESTAMP
            let new_timestamp = INITIAL_TIMESTAMP + ONE_DAY_MS;
            clock::set_for_testing(&mut clock, new_timestamp);
            
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let expected_fee = calculate_expected_fee(tvl, fee_percentage, ONE_DAY_MS);
            let new_accrued = vault::get_accrued_platform_fee(&vault);
            let new_last_charged = vault::get_last_charged_at_platform_fee(&vault);
            let new_seq = vault::get_vault_sequence_number(&vault);
            
            assert!(new_accrued == initial_accrued + expected_fee, 0);
            assert!(new_last_charged == new_timestamp, 1);
            assert!(new_seq == initial_seq, 2);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_after_multiple_hours() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_accrued = vault::get_accrued_platform_fee(&vault);
            let tvl = vault::get_vault_tvl(&vault);
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            
            // Move time forward by 12 hours
            let time_period = 12 * ONE_HOUR_MS;
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + time_period);
            
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let expected_fee = calculate_expected_fee(tvl, fee_percentage, time_period);
            let new_accrued = vault::get_accrued_platform_fee(&vault);
            
            assert!(new_accrued == initial_accrued + expected_fee, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_multiple_times() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let mut current_time = INITIAL_TIMESTAMP;
            clock::set_for_testing(&mut clock, current_time);
            
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            let tvl = vault::get_vault_tvl(&vault);
            
            let mut total_expected_fee = 0;
            
            // Charge fee 5 times, each after 10 minutes
            let mut i = 0;
            while (i < 5) {
                current_time = current_time + TEN_MINUTES_MS;
                clock::set_for_testing(&mut clock, current_time);
                
                let expected_fee = calculate_expected_fee(tvl, fee_percentage, TEN_MINUTES_MS);
                total_expected_fee = total_expected_fee + expected_fee;
                
                vault::test_charge_accrued_platform_fees(&mut vault, &clock);
                
                i = i + 1;
            };
            
            let final_accrued = vault::get_accrued_platform_fee(&vault);
            assert!(final_accrued == total_expected_fee, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_with_zero_elapsed_time() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP);
            
            let initial_accrued = vault::get_accrued_platform_fee(&vault);
            let initial_seq = vault::get_vault_sequence_number(&vault);
            
            // Charge fee at same time (no time elapsed)
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let new_accrued = vault::get_accrued_platform_fee(&vault);
            let new_seq = vault::get_vault_sequence_number(&vault);
            
            // Fee should not change
            assert!(new_accrued == initial_accrued, 0);
            // Sequence number should not increment
            assert!(new_seq == initial_seq, 1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_with_zero_tvl() {
        let protocol_admin = test_utils::protocol_admin();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Don't deposit anything - TVL is zero
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP);
            
            let initial_accrued = vault::get_accrued_platform_fee(&vault);
            let tvl = vault::get_vault_tvl(&vault);
            
            assert!(tvl == 0, 100); // Verify TVL is zero
            
            // Move time forward
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + ONE_DAY_MS);
            
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let new_accrued = vault::get_accrued_platform_fee(&vault);
            
            // Fee should be zero since TVL is zero
            assert!(new_accrued == initial_accrued, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_with_zero_fee_percentage_updates_timestamp_only() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets to create TVL.
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp.
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        // Update the vault fee to 0.
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + ONE_HOUR_MS);
            vault::update_vault_fee_percentage_v2<USDC, UltraUSDC>(
                &mut vault,
                &config,
                0,
                &clock,
                test_scenario::ctx(&mut scenario)
            );

            assert!(vault::get_vault_fee_percentage(&vault) == 0, 0);

            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Charging with zero fee should only update last_charged_at.
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

            let initial_accrued = vault::get_accrued_platform_fee(&vault);
            let initial_seq = vault::get_vault_sequence_number(&vault);
            let new_timestamp = INITIAL_TIMESTAMP + ONE_DAY_MS;

            clock::set_for_testing(&mut clock, new_timestamp);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);

            assert!(vault::get_accrued_platform_fee(&vault) == initial_accrued, 1);
            assert!(vault::get_last_charged_at_platform_fee(&vault) == new_timestamp, 2);
            assert!(vault::get_vault_sequence_number(&vault) == initial_seq, 3);

            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_accumulation() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            let tvl = vault::get_vault_tvl(&vault);
            
            // First charge after 10 minutes
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + TEN_MINUTES_MS);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let first_accrued = vault::get_accrued_platform_fee(&vault);
            let expected_first = calculate_expected_fee(tvl, fee_percentage, TEN_MINUTES_MS);
            assert!(first_accrued == expected_first, 0);
            
            // Second charge after another 20 minutes
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + 30 * 60_000);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let second_accrued = vault::get_accrued_platform_fee(&vault);
            let expected_second = calculate_expected_fee(tvl, fee_percentage, 20 * 60_000);
            assert!(second_accrued == first_accrued + expected_second, 1);
            
            // Third charge after another 30 minutes
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + 60 * 60_000);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let third_accrued = vault::get_accrued_platform_fee(&vault);
            let expected_third = calculate_expected_fee(tvl, fee_percentage, 30 * 60_000);
            assert!(third_accrued == second_accrued + expected_third, 2);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_sequence_number_unchanged() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let mut current_time = INITIAL_TIMESTAMP;
            clock::set_for_testing(&mut clock, current_time);
            
            let initial_seq = vault::get_vault_sequence_number(&vault);
            
            // Charge fee 3 times (using short intervals)
            current_time = current_time + TEN_MINUTES_MS;
            clock::set_for_testing(&mut clock, current_time);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            assert!(vault::get_vault_sequence_number(&vault) == initial_seq, 0);
            
            current_time = current_time + TEN_MINUTES_MS;
            clock::set_for_testing(&mut clock, current_time);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            assert!(vault::get_vault_sequence_number(&vault) == initial_seq, 1);
            
            current_time = current_time + TEN_MINUTES_MS;
            clock::set_for_testing(&mut clock, current_time);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            assert!(vault::get_vault_sequence_number(&vault) == initial_seq, 2);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_last_charged_at_updates() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        let time1 = INITIAL_TIMESTAMP;
        initialize_fee_timestamp(&mut scenario, time1);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            // First charge - verify initialization worked
            clock::set_for_testing(&mut clock, time1);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            assert!(vault::get_last_charged_at_platform_fee(&vault) == time1, 0);
            
            // Second charge
            let time2 = time1 + ONE_HOUR_MS;
            clock::set_for_testing(&mut clock, time2);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            assert!(vault::get_last_charged_at_platform_fee(&vault) == time2, 1);
            
            // Third charge
            let time3 = time2 + (3 * ONE_HOUR_MS);
            clock::set_for_testing(&mut clock, time3);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            assert!(vault::get_last_charged_at_platform_fee(&vault) == time3, 2);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_with_different_time_intervals() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let mut current_time = INITIAL_TIMESTAMP;
            clock::set_for_testing(&mut clock, current_time);
            
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            let tvl = vault::get_vault_tvl(&vault);
            
            // Charge after 10 minutes
            current_time = current_time + TEN_MINUTES_MS;
            clock::set_for_testing(&mut clock, current_time);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let accrued1 = vault::get_accrued_platform_fee(&vault);
            let expected1 = calculate_expected_fee(tvl, fee_percentage, TEN_MINUTES_MS);
            assert!(accrued1 == expected1, 0);
            
            // Charge after 1 hour
            current_time = current_time + ONE_HOUR_MS;
            clock::set_for_testing(&mut clock, current_time);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let accrued2 = vault::get_accrued_platform_fee(&vault);
            let expected2 = calculate_expected_fee(tvl, fee_percentage, ONE_HOUR_MS);
            assert!(accrued2 == accrued1 + expected2, 1);
            
            // Charge after 6 hours
            current_time = current_time + (6 * ONE_HOUR_MS);
            clock::set_for_testing(&mut clock, current_time);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let accrued3 = vault::get_accrued_platform_fee(&vault);
            let expected3 = calculate_expected_fee(tvl, fee_percentage, 6 * ONE_HOUR_MS);
            assert!(accrued3 == accrued2 + expected3, 2);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_with_large_tvl() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // First update max TVL to allow large deposit
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::update_vault_max_tvl(&mut vault, &config, 1_000_000_000_000_000, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit larger amount to test with significant TVL
        let deposit_amount = 10_000_000_000; // 10,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let tvl = vault::get_vault_tvl(&vault);
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            
            // Charge fee after 1 day
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + ONE_DAY_MS);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let accrued = vault::get_accrued_platform_fee(&vault);
            let expected = calculate_expected_fee(tvl, fee_percentage, ONE_DAY_MS);
            
            assert!(accrued == expected, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_precision_with_small_amounts() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Small deposit
        let deposit_amount = 1_000; // 0.001 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let tvl = vault::get_vault_tvl(&vault);
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            
            // Charge fee after 10 minutes
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + TEN_MINUTES_MS);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let accrued = vault::get_accrued_platform_fee(&vault);
            let expected = calculate_expected_fee(tvl, fee_percentage, TEN_MINUTES_MS);
            
            // Should handle precision correctly even with small amounts
            assert!(accrued == expected, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_after_vault_operations() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Initial deposit
        let deposit_amount = 10_000_000; // Increased amount to ensure non-zero fee with corrected FEE_DENOMINATOR
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            // Charge fee
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + ONE_HOUR_MS);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let accrued_after_first = vault::get_accrued_platform_fee(&vault);
            assert!(accrued_after_first > 0, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // User redeems some shares
        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, 5_000_000, user, user);
        sui::coin::burn_for_testing(remaining_receipt);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let accrued_before = vault::get_accrued_platform_fee(&vault);
            let tvl = vault::get_vault_tvl(&vault);
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            
            // Charge fee after redemption (TVL is now lower)
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + 2 * ONE_HOUR_MS);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let accrued_after = vault::get_accrued_platform_fee(&vault);
            let expected_additional = calculate_expected_fee(tvl, fee_percentage, ONE_HOUR_MS);
            
            assert!(accrued_after == accrued_before + expected_additional, 1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_very_short_time_period() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let tvl = vault::get_vault_tvl(&vault);
            let fee_percentage = vault::get_vault_fee_percentage(&vault);
            
            // Charge fee after just 1 second (1000 ms)
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + 1000);
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            let accrued = vault::get_accrued_platform_fee(&vault);
            let expected = calculate_expected_fee(tvl, fee_percentage, 1000);
            
            assert!(accrued == expected, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_charge_fee_idempotency_at_same_timestamp() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Deposit assets
        let deposit_amount = 1_000_000_000; // 1,000 USDC
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, option::some(deposit_amount));
        sui::coin::burn_for_testing(receipt);

        // Initialize fee charging timestamp first
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let timestamp = INITIAL_TIMESTAMP + ONE_HOUR_MS;
            clock::set_for_testing(&mut clock, timestamp);
            
            // First charge
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            let accrued_after_first = vault::get_accrued_platform_fee(&vault);
            let seq_after_first = vault::get_vault_sequence_number(&vault);
            
            // Try charging again at same timestamp
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            let accrued_after_second = vault::get_accrued_platform_fee(&vault);
            let seq_after_second = vault::get_vault_sequence_number(&vault);
            
            // Should be idempotent - no change
            assert!(accrued_after_second == accrued_after_first, 0);
            assert!(seq_after_second == seq_after_first, 1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_economic_validation_fee_formula() {
        // Test: 1000 USDC TVL with 1% annual fee over 365 days should accrue exactly 10 USDC in fees        
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Set up: Deposit 1000 USDC to create TVL
        let tvl_amount = 1_000_000_000; // 1000 USDC with 6 decimals
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, tvl_amount, option::some(tvl_amount));
        sui::coin::burn_for_testing(receipt);

        // Set fee percentage to 1% annual (0.01 * 1e9 = 10,000,000)
        let fee_percentage_1pct = 10_000_000; // 1% annual in 1e9 format
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP);
            vault::update_vault_fee_percentage_v2<USDC, UltraUSDC>(&mut vault, &config, fee_percentage_1pct, &clock, test_scenario::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Initialize fee charging timestamp
        initialize_fee_timestamp(&mut scenario, INITIAL_TIMESTAMP);

        // Charge fee after exactly 365 days
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            // Set clock to exactly 365 days after initialization
            let one_year_ms = 365 * ONE_DAY_MS;
            clock::set_for_testing(&mut clock, INITIAL_TIMESTAMP + one_year_ms);
            
            // Charge the fee
            vault::test_charge_accrued_platform_fees(&mut vault, &clock);
            
            // Validate: 1000 USDC * 1% annual fee * 365 days = 10 USDC
            let accrued_fee = vault::get_accrued_platform_fee(&vault);
            let expected_fee = 10_000_000; // 10 USDC with 6 decimals
            
            assert!(accrued_fee == expected_fee, 0);
            
            // Verify the calculation manually
            let tvl = vault::get_vault_tvl(&vault);
            let fee_pct = vault::get_vault_fee_percentage(&vault);
            let calculated_fee = calculate_expected_fee(tvl, fee_pct, one_year_ms);
            assert!(calculated_fee == expected_fee, 1);
            assert!(accrued_fee == calculated_fee, 2);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }
}

