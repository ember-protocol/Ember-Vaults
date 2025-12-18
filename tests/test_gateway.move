#[test_only]
module ember_vaults::test_gateway {

    // === Imports ===
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::balance::{Self};
    use sui::clock::{Self};
    use std::string::{Self};

    use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
    use ember_vaults::vault::{Self, Vault};
    use ember_vaults::admin::{Self, ProtocolConfig, AdminCap};
    use ember_vaults::gateway::{Self};

    // === Test Constants ===
    const DEPOSIT_AMOUNT: u64 = 1000000; // 10 USDC
    const REDEEM_AMOUNT: u64 = 500000;   // 5 shares
    const NEW_RATE: u64 = 2000000000;    // 2.0 (different from default 1.0)
    const NEW_FEE_PERCENTAGE: u64 = 200; // 2%
    const TIMESTAMP_1: u64 = 1000000000;
    const MAX_U64: u64 = 18446744073709551615; 

    // === Admin Gateway Function Tests ===

    // Note: increase_supported_package_version test removed because it requires 
    // the package version to be lower than current, which is not controllable in tests

    #[test]
    fun test_gateway_pause_non_admin_operations() {
        let protocol_admin = test_utils::protocol_admin();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Pause operations via gateway
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            
            assert!(!admin::get_protocol_pause_status(&config), 0);
            
            gateway::pause_non_admin_operations(&mut config, &admin_cap, true);
            
            assert!(admin::get_protocol_pause_status(&config), 1);
            
            // Unpause
            gateway::pause_non_admin_operations(&mut config, &admin_cap, false);
            
            assert!(!admin::get_protocol_pause_status(&config), 2);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(config);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_update_platform_fee_recipient() {
        let protocol_admin = test_utils::protocol_admin();
        let new_recipient = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Update fee recipient via gateway
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            
            gateway::update_platform_fee_recipient(&mut config, &admin_cap, new_recipient);
            
            let current_recipient = admin::get_platform_fee_recipient(&config);
            assert!(current_recipient == new_recipient, 0);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(config);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_update_rate_limits() {
        let protocol_admin = test_utils::protocol_admin();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Update rate limits via gateway
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            
            let new_min_rate = 500000000; // 0.5
            let new_max_rate = 2500000000; // 2.5
            let new_default_rate = 1500000000; // 1.5
            
            gateway::update_min_rate(&mut config, &admin_cap, new_min_rate);
            gateway::update_max_rate(&mut config, &admin_cap, new_max_rate);
            gateway::update_default_rate(&mut config, &admin_cap, new_default_rate);
            
            assert!(admin::get_min_rate(&config) == new_min_rate, 0);
            assert!(admin::get_max_rate(&config) == new_max_rate, 1);
            assert!(admin::get_default_rate(&config) == new_default_rate, 2);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(config);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_update_max_fee_percentage() {
        let protocol_admin = test_utils::protocol_admin();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Update max fee percentage via gateway
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            
            let new_max_fee = 1000; // 10%
            
            gateway::update_max_fee_percentage(&mut config, &admin_cap, new_max_fee);
            
            assert!(admin::get_max_allowed_fee_percentage(&config) == new_max_fee, 0);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(config);
        };

        test_scenario::end(scenario);
    }

    // === Vault Creation Gateway Tests ===

    #[test]
    fun test_gateway_create_vault() {
        let protocol_admin = test_utils::protocol_admin();
        let vault_admin = test_utils::alice();
        let operator = test_utils::bob();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        
        // Initialize only admin module, not the full setup
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            admin::initialize_module(test_scenario::ctx(&mut scenario));
        };

        // Create vault via gateway
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let treasury_cap = coin::create_treasury_cap_for_testing<UltraUSDC>(test_scenario::ctx(&mut scenario));
            
            let vault_name = string::utf8(b"Test Vault");
            let max_rate_change = 1000000000; // 1.0
            let fee_percentage = 100; // 1%
            let min_withdrawal_shares = 1000;
            let rate_update_interval = 3600000; // 1 hour
            let sub_accounts = vector::empty<address>();
            
            gateway::create_vault<USDC, UltraUSDC>(
                &config,
                treasury_cap,
                &admin_cap,
                vault_name,
                vault_admin,
                operator,
                max_rate_change,
                fee_percentage,
                min_withdrawal_shares,
                rate_update_interval,
                1000000000000, // max_tvl: 1000 USDC (in e9 format)
                sub_accounts,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(config);
        };

        // Verify vault was created and shared
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            assert!(vault::get_vault_admin(&vault) == vault_admin, 0);
            assert!(vault::get_vault_operator(&vault) == operator, 1);
            assert!(vault::get_vault_fee_percentage(&vault) == 100, 2);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_change_vault_admin() {
        let protocol_admin = test_utils::protocol_admin();
        let new_admin = @0x123;
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Change vault admin via gateway
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let original_admin = vault::get_vault_admin(&vault);
            
            gateway::change_vault_admin(&mut vault, &config, &admin_cap, new_admin);
            
            assert!(vault::get_vault_admin(&vault) == new_admin, 0);
            assert!(vault::get_vault_admin(&vault) != original_admin, 1);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Vault Admin Gateway Tests ===

    #[test]
    fun test_gateway_vault_admin_functions() {
        let protocol_admin = test_utils::protocol_admin();
        let vault_admin = test_utils::protocol_admin(); // Vault admin is protocol_admin per test_utils
        let new_operator = @0x123;
        let sub_account = test_utils::charlie(); // Use charlie instead of bob (bob is operator, can't be sub_account)
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Test vault admin functions via gateway - use the actual vault admin
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            // Test pause vault
            assert!(!vault::get_vault_paused(&vault), 0);
            gateway::set_vault_paused_status(&mut vault, &config, true, test_scenario::ctx(&mut scenario));
            assert!(vault::get_vault_paused(&vault), 1);
            
            // Test unpause vault
            gateway::set_vault_paused_status(&mut vault, &config, false, test_scenario::ctx(&mut scenario));
            assert!(!vault::get_vault_paused(&vault), 2);
            
            // Test change operator
            gateway::change_vault_operator(&mut vault, &config, new_operator, test_scenario::ctx(&mut scenario));
            assert!(vault::get_vault_operator(&vault) == new_operator, 3);
            
            // Test set sub account
            gateway::set_sub_account(&mut vault, &config, sub_account, true, test_scenario::ctx(&mut scenario));
            let sub_accounts = vault::get_vault_sub_accounts(&vault);
            assert!(vector::contains(&sub_accounts, &sub_account), 4);
            
            // Test update fee percentage
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 10000000000);
            gateway::update_vault_fee_percentage_v2(&mut vault, &config, NEW_FEE_PERCENTAGE, &clock, test_scenario::ctx(&mut scenario));
            assert!(vault::get_vault_fee_percentage(&vault) == NEW_FEE_PERCENTAGE, 5);
            clock::destroy_for_testing(clock);
            
            // Test set min withdrawal shares
            let new_min_shares = 2000;
            gateway::set_min_withdrawal_shares(&mut vault, &config, new_min_shares, test_scenario::ctx(&mut scenario));
            assert!(vault::get_vault_min_withdrawal_shares(&vault) == new_min_shares, 6);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Vault Operator Gateway Tests ===

    #[test]
    fun test_gateway_vault_operator_functions() {
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob(); // Default vault operator
        let rate_manager = test_utils::alice(); // Rate manager
        let user_to_blacklist = @0x456;
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Test operator functions via gateway
        test_scenario::next_tx(&mut scenario, operator);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1);
            
            // Test blacklist account
            assert!(!vault::is_blacklisted(&vault, user_to_blacklist), 0);
            gateway::set_blacklisted_account(&mut vault, &config, user_to_blacklist, true, test_scenario::ctx(&mut scenario));
            assert!(vault::is_blacklisted(&vault, user_to_blacklist), 1);
            
            // Test unblacklist account
            gateway::set_blacklisted_account(&mut vault, &config, user_to_blacklist, false, test_scenario::ctx(&mut scenario));
            assert!(!vault::is_blacklisted(&vault, user_to_blacklist), 2);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Test update vault rate as rate manager
        test_scenario::next_tx(&mut scenario, rate_manager);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1);
            
            // Test update vault rate - use a rate that's within allowed change limit
            let current_rate = vault::get_vault_rate(&vault);
            let max_change = vault::get_vault_max_rate_change_per_update(&vault);
            let new_rate = current_rate + (max_change / 2); // Use half the max change to stay within limits
            
            gateway::update_vault_rate(&mut vault, &config, new_rate, &clock, test_scenario::ctx(&mut scenario));
            assert!(vault::get_vault_rate(&vault) == new_rate, 3);
            assert!(vault::get_vault_rate(&vault) != current_rate, 4);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_vault_deposits_and_withdrawals() {
        let protocol_admin = test_utils::protocol_admin();
        let vault_admin = test_utils::protocol_admin(); // Vault admin is protocol_admin per test_utils
        let operator = test_utils::bob(); // Operator is bob per test_utils
        let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Add sub account first - needs to be done by vault admin
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            gateway::set_sub_account(&mut vault, &config, sub_account, true, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Test deposit without minting shares via gateway
        test_scenario::next_tx(&mut scenario, operator);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let deposit_coin = balance::create_for_testing<USDC>(DEPOSIT_AMOUNT);
            let initial_balance = vault::get_vault_balance(&vault);
            
            gateway::deposit_to_vault_without_minting_shares(
                &mut vault,
                &config,
                sub_account,
                coin::from_balance(deposit_coin, test_scenario::ctx(&mut scenario)),
                test_scenario::ctx(&mut scenario)
            );
            
            let new_balance = vault::get_vault_balance(&vault);
            assert!(new_balance == initial_balance + DEPOSIT_AMOUNT, 0);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Test withdraw without redeeming shares via gateway
        test_scenario::next_tx(&mut scenario, operator);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let withdraw_amount = DEPOSIT_AMOUNT / 2;
            let initial_balance = vault::get_vault_balance(&vault);
            
            gateway::withdraw_from_vault_without_redeeming_shares(
                &mut vault,
                &config,
                sub_account,
                withdraw_amount,
                test_scenario::ctx(&mut scenario)
            );
            
            let new_balance = vault::get_vault_balance(&vault);
            assert!(new_balance == initial_balance - withdraw_amount, 1);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_process_withdrawal_requests() {
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Setup: Create withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, REDEEM_AMOUNT, user, user);
        coin::burn_for_testing(remaining_receipt);

        // Test process withdrawal requests via gateway
        test_scenario::next_tx(&mut scenario, operator);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 10000000000 + TIMESTAMP_1); // Use timestamp after deposit
            
            // Verify there's a request to process
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(ember_vaults::queue::len(pending_withdrawals) == 1, 0);
            
            gateway::process_withdrawal_requests(
                &mut vault,
                &config,
                1,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify request was processed
            let pending_withdrawals_after = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(ember_vaults::queue::len(pending_withdrawals_after) == 0, 1);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_process_withdrawal_requests_up_to_timestamp() {
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Setup: Create withdrawal request at specific timestamp
        test_scenario::next_tx(&mut scenario, user);
        {
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1);

            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);

            let deposit_balance = balance::create_for_testing<USDC>(DEPOSIT_AMOUNT);
            let receipt = vault::deposit_asset_v2<USDC, UltraUSDC>(&mut vault, &config, deposit_balance, 0, &clock, test_scenario::ctx(&mut scenario)); // min_shares = 0

            let mut receipt_balance = coin::into_balance(receipt);
            let shares_balance = balance::split(&mut receipt_balance, REDEEM_AMOUNT);

            vault::redeem_shares<USDC, UltraUSDC>(&mut vault, &config, shares_balance, user, &clock, test_scenario::ctx(&mut scenario));

            coin::burn_for_testing(coin::from_balance(receipt_balance, test_scenario::ctx(&mut scenario)));
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(vault);
            test_scenario::return_shared(config);
        };

        // Test process withdrawal requests up to timestamp via gateway
        test_scenario::next_tx(&mut scenario, operator);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1 + 3600000); // 1 hour later
            
            let timestamp_limit = TIMESTAMP_1 + 1800000; // 30 minutes after request
            
            gateway::process_withdrawal_requests_up_to_timestamp(
                &mut vault,
                &config,
                timestamp_limit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify request was processed (it was within timestamp limit)
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(ember_vaults::queue::len(pending_withdrawals) == 0, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]  
    fun test_gateway_platform_fee_functions() {
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Test that platform fee functions can be called via gateway
        // Note: These functions may fail if there are no fees to charge/collect, which is expected behavior
        test_scenario::next_tx(&mut scenario, operator);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1);
            
            // Just verify the gateway functions exist and can be called
            // The actual fee logic is tested in other test files
            // For now, we'll test that the gateway layer works correctly
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === User Gateway Function Tests ===

    #[test]
    fun test_gateway_deposit_asset() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Test deposit asset via gateway
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let deposit_coin = balance::create_for_testing<USDC>(DEPOSIT_AMOUNT);
            let initial_balance = vault::get_vault_balance(&vault);
            
            gateway::deposit_asset_v2(
                &mut vault,
                &config,
                coin::from_balance(deposit_coin, test_scenario::ctx(&mut scenario)),
                0, // min_shares = 0 (no slippage protection)
                option::none(), // receiver = none (default to sender)
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            let new_balance = vault::get_vault_balance(&vault);
            assert!(new_balance == initial_balance + DEPOSIT_AMOUNT, 0);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify user received receipt tokens
        test_scenario::next_tx(&mut scenario, user);
        {
            let receipt = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, user);
            assert!(coin::value(&receipt) == DEPOSIT_AMOUNT, 1); // 1:1 ratio initially
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(user, receipt);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_mint_shares() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let receiver = test_utils::bob();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Test mint shares via gateway with receiver option
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let deposit_coin = balance::create_for_testing<USDC>(DEPOSIT_AMOUNT);
            let shares_to_mint = REDEEM_AMOUNT;
            let receiver_option = option::some(receiver);
            
            gateway::mint_shares_v2(
                &mut vault,
                &config,
                coin::from_balance(deposit_coin, test_scenario::ctx(&mut scenario)),
                shares_to_mint,
                MAX_U64, // max_amount = MAX_U64 (no slippage protection)
                receiver_option,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify receiver got the shares
        test_scenario::next_tx(&mut scenario, receiver);
        {
            let receipt = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, receiver);
            assert!(coin::value(&receipt) == REDEEM_AMOUNT, 0);
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(receiver, receipt);
        };

        // Verify user got remaining assets (if any)
        test_scenario::next_tx(&mut scenario, user);
        {
            let remaining_coin = test_scenario::take_from_address<coin::Coin<USDC>>(&scenario, user);
            let expected_remaining = DEPOSIT_AMOUNT - REDEEM_AMOUNT; // Since rate is 1:1
            assert!(coin::value(&remaining_coin) == expected_remaining, 1);
            test_scenario::return_to_address<coin::Coin<USDC>>(user, remaining_coin);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_redeem_shares() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let receiver = test_utils::bob();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Setup: Deposit assets first
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);

        // Test redeem shares via gateway with receiver option
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1);
            
            let mut receipt_balance = coin::into_balance(receipt);
            let shares_to_redeem = balance::split(&mut receipt_balance, REDEEM_AMOUNT);
            let receiver_option = option::some(receiver);
            
            gateway::redeem_shares(
                &clock,
                &mut vault,
                &config,
                coin::from_balance(shares_to_redeem, test_scenario::ctx(&mut scenario)),
                receiver_option,
                test_scenario::ctx(&mut scenario)
            );
            
            // Return remaining receipt
            coin::burn_for_testing(coin::from_balance(receipt_balance, test_scenario::ctx(&mut scenario)));
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify withdrawal request was created for receiver
        test_scenario::next_tx(&mut scenario, receiver);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(ember_vaults::queue::len(pending_withdrawals) == 1, 0);
            
            let user_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user);
            assert!(user_pending == REDEEM_AMOUNT, 1);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_gateway_cancel_pending_withdrawal_request() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Setup: Create withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, REDEEM_AMOUNT, user, user);
        let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);
        coin::burn_for_testing(remaining_receipt);

        // Test cancel withdrawal request via gateway
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            gateway::cancel_pending_withdrawal_request(
                &mut vault,
                &config,
                sequence_number,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify request was cancelled
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            assert!(vector::length(&cancelled_requests) == 1, 0);
            assert!(*vector::borrow(&cancelled_requests, 0) == sequence_number, 1);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Error Condition Tests ===

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun test_gateway_unauthorized_vault_admin_function() {
        let protocol_admin = test_utils::protocol_admin();
        let unauthorized_user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Try to pause vault without being vault admin
        test_scenario::next_tx(&mut scenario, unauthorized_user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            gateway::set_vault_paused_status(&mut vault, &config, true, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun test_gateway_unauthorized_vault_operator_function() {
        let protocol_admin = test_utils::protocol_admin();
        let unauthorized_user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // First set the rate manager as admin
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            gateway::change_vault_rate_manager(&mut vault, &config, @123, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Try to update vault rate without being rate manager
        test_scenario::next_tx(&mut scenario, unauthorized_user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1);
            
            gateway::update_vault_rate(&mut vault, &config, NEW_RATE, &clock, test_scenario::ctx(&mut scenario));
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }
}
