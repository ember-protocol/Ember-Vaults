#[test_only]
module ember_vaults::test_deposit {

    use sui::test_scenario;
    use ember_vaults::admin::ProtocolConfig;
    use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
    use ember_vaults::vault::{Self, Vault};
    use sui::coin::{Self};


    #[test]
    #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
    fun should_fail_to_deposit_when_protocol_is_paused() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let deposit_amount = 20000000; // 20 USDC

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        test_utils::pause_non_admin_operations(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario,  user, deposit_amount);

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EVaultPaused)]
    fun should_fail_to_deposit_when_vault_is_paused() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let deposit_amount = 20000000; // 20 USDC

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        test_utils::pause_vault_operations(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario,  user, deposit_amount);

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    fun should_deposit_assets_and_get_receipt_correctly_when_rate_is_greater_than_100() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let rate = 1030000000; //103% - within 5% change limit
        let deposit_amount = 20000000; // 20 USDC
        let expected_shares = 20600000; // 20 * 1.03 = 20.6 = 20.6

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);


        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, rate);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario,  user, deposit_amount);

        assert!(coin::value(&receipt) == expected_shares, 0);

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    fun should_deposit_assets_and_get_receipt_correctly_when_rate_is_less_than_100() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let rate = 970000000; //97% - within 5% change limit
        let deposit_amount = 20000000; // 20 USDC
        let expected_shares = 19400000; // 20 * 0.97 = 19.4 = 19.4

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, rate);


        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        assert!(coin::value(&receipt) == expected_shares, 0);

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    fun should_show_correct_total_supply_of_shares_after_multiple_deposits() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let rate = 1050000000; //105% - within 5% change limit
        let deposit_amount_a = 20000000; // 20 USDC
        let deposit_amount_b = 10000000; // 10 USDC
        let expected_total_supply = 31500000; // 20 + 10 = 30 = 30

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, rate);


        let receipt_a = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount_a);
        let receipt_b = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount_b);

        // Take the vault again to check total supply
        test_scenario::next_tx(&mut scenario, user);
        let vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        
        let actual_total_supply = vault::get_vault_total_shares_in_circulation<USDC, UltraUSDC>(&vault);

        assert!(actual_total_supply == expected_total_supply, 0);

        test_scenario::return_shared(vault);

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt_a);
        coin::burn_for_testing(receipt_b);
        test_scenario::end(scenario);           
        
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EBlacklistedAccount)]
    fun should_fail_when_blacklisted_user_tries_to_deposit() {

        let operator = test_utils::bob();
        let blacklisted_user = test_utils::alice();
        let deposit_amount = 20000000; // 20 USDC

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Blacklist the user
        test_scenario::next_tx(&mut scenario, operator);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        vault::set_blacklisted_account(&mut vault, &config, blacklisted_user, true, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // Try to deposit as blacklisted user - should fail
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, blacklisted_user, deposit_amount);

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
    }

    #[test]
    fun should_allow_deposit_after_user_is_removed_from_blacklist() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let deposit_amount = 20000000; // 20 USDC

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Blacklist the user
        test_scenario::next_tx(&mut scenario, operator);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
        vault::set_blacklisted_account(&mut vault, &config, user, true, test_scenario::ctx(&mut scenario));
        
        // Remove user from blacklist
        vault::set_blacklisted_account(&mut vault, &config, user, false, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

        // Now deposit should work
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        assert!(coin::value(&receipt) > 0, 0);
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EMaxTVLReached)]
    fun should_fail_to_deposit_asset_when_max_tvl_is_reached() {
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let deposit_amount = 20000000; // 20 USDC

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // First, let's create a scenario where we have existing shares that would make TVL calculation work
        // We need to first deposit some assets to create shares, then try to exceed max TVL
        test_scenario::next_tx(&mut scenario, user);
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, 999990000000); // 999.99 USDC
        
        // Now the vault has 999.99 shares (since rate = 1.0)
        // The current TVL = 999.99 shares / 1.0 = 999.99 USDC
        // The max_tvl is 1000 USDC, so we're at 99.999% capacity
        
        // Now try to deposit additional assets - this should fail because it would exceed max TVL
        let deposit_receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        coin::burn_for_testing(receipt);
        coin::burn_for_testing(deposit_receipt);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::ESubAccount)]
    fun should_fail_when_sub_account_tries_to_deposit_assets() {
        let operator = test_utils::bob();
        let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
        let deposit_amount = 20000000; // 20 USDC

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Add the user as a sub account
        test_utils::set_sub_account(&mut scenario, sub_account);

        // Try to deposit as sub account - should fail
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, sub_account, deposit_amount);

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::ESlippageToleranceExceeded)]
    fun should_fail_when_deposit_slippage_exceeds_min_shares() {
        // Test that deposit fails when the actual shares minted is less than min_shares
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let deposit_amount = 100000000; // 100 USDC

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // With default rate of 1.0 (1e9), depositing 100 USDC should mint 100 shares
        // Setting min_shares to 101 should cause slippage failure
        let receipt = test_utils::deposit_assets_with_slippage<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, 101000000); // min_shares = 101 (higher than expected)

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);
    }

    #[test]
    fun should_succeed_when_deposit_slippage_within_tolerance() {
        // Test that deposit succeeds when min_shares is less than or equal to actual shares minted
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let deposit_amount = 100000000; // 100 USDC

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // With default rate of 1.0 (1e9), depositing 100 USDC should mint 100 shares
        // Setting min_shares to 99 should succeed (within tolerance)
        let receipt = test_utils::deposit_assets_with_slippage<USDC, UltraUSDC>(&mut scenario, user, deposit_amount, 99000000); // min_shares = 99

        assert!(coin::value(&receipt) == 100000000, 0); // Should receive 100 shares
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);
    }
}