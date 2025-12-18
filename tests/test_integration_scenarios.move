#[test_only]
module ember_vaults::test_integration_scenarios {

    use sui::test_scenario;
    use sui::coin;
    use sui::clock;

    use ember_vaults::admin::{ProtocolConfig, AdminCap};
    use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
    use ember_vaults::vault::{Self, Vault};


    #[test]
    fun test_tvl(){
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);


        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, 1050000000);

        let deposit_amount = 100000000; // 100 USDC
        let deposit_receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, operator, deposit_amount);

        assert!(coin::value(&deposit_receipt) == 105000000, 0);

        coin::burn_for_testing(deposit_receipt);


        test_scenario::next_tx(&mut scenario, operator);
            let vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );
            let tvl = vault::get_vault_tvl<USDC,UltraUSDC>(&vault);
            assert!(tvl == 100000000, 2);

            test_scenario::return_shared(vault);

        test_scenario::end(scenario);   
    }

     #[test]
    fun test_admin_operations_sequence() {
        // Test comprehensive admin operations in sequence
        
        let protocol_admin = test_utils::protocol_admin();
        let new_admin = @0x123;
        let new_operator = @0x91;
        let new_rate_manager = @0x92;
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);
        test_utils::set_vault_rate_manager<USDC,UltraUSDC>(&mut scenario, new_rate_manager);

        // === Change vault admin ===
        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);
        
        vault::change_vault_admin<USDC,UltraUSDC>(&mut vault, &config, &cap, new_admin);
        assert!(vault::get_vault_admin<USDC,UltraUSDC>(&vault) == new_admin, 0);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

        // === New admin changes operator ===
        test_scenario::next_tx(&mut scenario, new_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        vault::change_vault_operator<USDC,UltraUSDC>(&mut vault, &config, new_operator, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_operator<USDC,UltraUSDC>(&vault) == new_operator, 1);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // === New admin updates fee percentage ===
        test_scenario::next_tx(&mut scenario, new_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000000000);
        
        let new_fee = 2000000; // 0.2%
        vault::update_vault_fee_percentage_v2(&mut vault, &config, new_fee, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_fee_percentage<USDC,UltraUSDC>(&vault) == new_fee, 2);
        
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // === The current rate manager can change the vault rate === 
        test_scenario::next_tx(&mut scenario, new_rate_manager);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000000000);

        vault::update_vault_rate(&mut vault, &config, 1020000000, &clock, test_scenario::ctx(&mut scenario));

        assert!(vault::get_vault_rate<USDC,UltraUSDC>(&vault) == 1020000000, 3);

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        clock::destroy_for_testing(clock);


 
        test_scenario::end(scenario);
    }

    #[test]
    fun test_blacklist_during_operations() {
        // Test blacklisting users during active operations
        
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob();
        let alice = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // === Alice makes initial deposit ===
        let deposit_amount = 25000000; // 25 USDC
        let alice_receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, alice, deposit_amount);

        // === Operator blacklists Alice ===
        test_scenario::next_tx(&mut scenario, operator);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        vault::set_blacklisted_account(&mut vault, &config, alice, true, test_scenario::ctx(&mut scenario));
        let blacklisted = vault::get_vault_blacklisted_accounts<USDC,UltraUSDC>(&vault);
        assert!(vector::length(&blacklisted) == 1, 0);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // === Verify Alice can't make new deposits ===
        // This should fail due to blacklist
        // (We can't test this directly without expected_failure, but we've tested it in blacklist tests)

        // === Operator removes Alice from blacklist ===
        test_scenario::next_tx(&mut scenario, operator);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        vault::set_blacklisted_account(&mut vault, &config, alice, false, test_scenario::ctx(&mut scenario));
        let blacklisted = vault::get_vault_blacklisted_accounts<USDC,UltraUSDC>(&vault);
        assert!(vector::length(&blacklisted) == 0, 1);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // === Alice can deposit again ===
        let alice_receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, alice, deposit_amount);
        assert!(coin::value(&alice_receipt2) > 0, 2);

        coin::burn_for_testing(alice_receipt);
        coin::burn_for_testing(alice_receipt2);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_vault_pause_operations() {
        // Test vault pause/unpause functionality
        
        let protocol_admin = test_utils::protocol_admin();
        let alice = test_utils::alice();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // === Initial deposit works ===
        let deposit_amount = 10000000; // 10 USDC  
        let alice_receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, alice, deposit_amount);

        // === Admin pauses vault ===
        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        vault::set_vault_paused_status(&mut vault, &config, true, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_paused<USDC,UltraUSDC>(&vault) == true, 0);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // === Deposits should fail when paused (tested in deposit tests) ===

        // === Admin unpauses vault ===
        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        vault::set_vault_paused_status(&mut vault, &config, false, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_paused<USDC,UltraUSDC>(&vault) == false, 1);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // === Deposits work again ===
        let alice_receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, alice, deposit_amount);
        assert!(coin::value(&alice_receipt2) > 0, 2);

        coin::burn_for_testing(alice_receipt);
        coin::burn_for_testing(alice_receipt2);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_rate_change_limits_integration() {
        // Test rate change limits in realistic scenarios
        
        let protocol_admin = test_utils::protocol_admin();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // === Test maximum allowed rate change (5%) ===
        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, 1050000000);
        
        // === Test another 5% change from new base ===        
        let next_increase = 1102500000; // 110.25% (5% increase from 105%)
        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 2000000000, next_increase);


        // === Test decreasing rate ===        
        let decrease_rate = 1047375000; // ~95% of current rate (5% decrease)
        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 3000000000, decrease_rate);

        test_scenario::end(scenario);
    }

    #[test]
    fun test_fee_accumulation_and_collection() {
        // Test fee accumulation over multiple operations
        
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob();
        
        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // === Add platform fees ===
        test_scenario::next_tx(&mut scenario, operator);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        vault::increase_platform_fee_accrued<USDC,UltraUSDC>(&mut vault, 5000000, 1000000000); // 5 USDC
        assert!(vault::get_accrued_platform_fee<USDC,UltraUSDC>(&vault) == 5000000, 0);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // === Add more fees ===
        test_scenario::next_tx(&mut scenario, operator);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        vault::increase_platform_fee_accrued<USDC,UltraUSDC>(&mut vault, 3000000, 1000000000); // 3 USDC
        assert!(vault::get_accrued_platform_fee<USDC,UltraUSDC>(&vault) == 8000000, 1);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // === Collect all fees ===
        test_scenario::next_tx(&mut scenario, operator);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        vault::collect_platform_fee(&mut vault, &config, test_scenario::ctx(&mut scenario));
        assert!(vault::get_accrued_platform_fee<USDC,UltraUSDC>(&vault) == 0, 2);
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        test_scenario::end(scenario);
    }
}