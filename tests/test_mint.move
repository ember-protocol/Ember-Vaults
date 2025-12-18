#[test_only]
module ember_vaults::test_mint {

    use sui::test_scenario;
    use ember_vaults::admin::ProtocolConfig;
    use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
    use ember_vaults::vault::{Self, Vault};
    use sui::coin::{Self};


    #[test]
    #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
    fun should_fail_to_mint_shares_when_protocol_is_paused() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let shares_to_mint = 20000000; // 20 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        test_utils::pause_non_admin_operations(&mut scenario);

        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario,  user,  shares_to_mint, option::none());

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EVaultPaused)]
    fun should_fail_to_mint_shares_when_vault_is_paused() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let shares_to_mint = 20000000; // 20 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        test_utils::pause_vault_operations(&mut scenario);

        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario,  user,  shares_to_mint, option::none());

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    fun should_mint_shares_and_get_receipt_correctly_when_rate_is_greater_than_100() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let rate = 1030000000; //103% - within 5% change limit
        let shares_to_mint = 20000000; // 20 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, rate);

        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario,  user,  shares_to_mint, option::none());

        assert!(coin::value(&receipt) == shares_to_mint, 0);

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    fun should_mint_shares_and_get_receipt_correctly_when_rate_is_less_than_100() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let rate = 970000000; //97% - within 5% change limit
        let shares_to_mint = 20000000; // 20 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, rate);

        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, shares_to_mint, option::none());

        assert!(coin::value(&receipt) == shares_to_mint, 0);

        // Receipt token is newly minted, so we just drop it
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    fun should_show_correct_total_supply_of_shares_after_multiple_mint_shares() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let rate = 1050000000; //105% - within 5% change limit
        let shares_to_mint_a = 20000000; // 20 shares
        let shares_to_mint_b = 10000000; // 10 shares
        let expected_total_supply = shares_to_mint_a + shares_to_mint_b ; 

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, rate);

        let receipt_a = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, shares_to_mint_a, option::none());
        let receipt_b = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, shares_to_mint_b, option::none());

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
    fun should_fail_when_blacklisted_user_tries_to_mint_shares() {

        let operator = test_utils::bob();
        let blacklisted_user = test_utils::alice();
        let shares_to_mint = 20000000; // 20 shares

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
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, blacklisted_user, shares_to_mint, option::none());

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
    }

    #[test]
    fun should_allow_mint_shares_after_user_is_removed_from_blacklist() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        let shares_to_mint = 20000000; // 20 shares

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
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, shares_to_mint, option::none());

        assert!(coin::value(&receipt) > 0, 0);
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EZeroAmount)]
    fun should_fail_when_user_tries_to_mint_shares_with_zero_shares() {
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let shares_to_mint = 0; // 0 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario,  user,  shares_to_mint, option::none());

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInsufficientBalance)]
    fun should_fail_when_user_tries_to_mint_shares_with_insufficient_balance() {
        
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let shares_to_mint = 20000000; // 20 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario,  user,  shares_to_mint, option::some<u64>(100000));

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           

    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EMaxTVLReached)]
    fun should_fail_to_mint_shares_when_max_tvl_is_reached() {
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let shares_to_mint = 20000000; // 20 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // First, let's create a scenario where we have existing shares that would make TVL calculation work
        // We need to first deposit some assets to create shares, then try to exceed max TVL
        test_scenario::next_tx(&mut scenario, user);
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, 999990000000); // 999.99 USDC
        
        // Now the vault has 999.99 shares (since rate = 1.0)
        // The current TVL = 999.99 shares / 1.0 = 999.99 USDC
        // The max_tvl is 1000 USDC, so we're at 99.999% capacity
        
        // Now try to mint additional shares - this should fail because it would exceed max TVL
        let mint_receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, user, shares_to_mint, option::none());

        coin::burn_for_testing(receipt);
        coin::burn_for_testing(mint_receipt);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::ESubAccount)]
    fun should_fail_when_sub_account_tries_to_mint_shares() {
        let operator = test_utils::bob();
        let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
        let shares_to_mint = 20000000; // 20 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Add the user as a sub account
        test_utils::set_sub_account(&mut scenario, sub_account);

        // Try to mint shares as sub account - should fail
        let receipt = test_utils::mint_shares<USDC, UltraUSDC>(&mut scenario, sub_account, shares_to_mint, option::none());

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);           
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::ESlippageToleranceExceeded)]
    fun should_fail_when_mint_shares_slippage_exceeds_max_amount() {
        // Test that mint_shares fails when the actual amount needed exceeds max_amount
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let shares_to_mint = 100000000; // 100 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // With default rate of 1.0 (1e9), minting 100 shares requires 100 USDC
        // Setting max_amount to 99 should cause slippage failure
        let receipt = test_utils::mint_shares_with_slippage<USDC, UltraUSDC>(&mut scenario, user, shares_to_mint, option::some(200000000), 99000000); // max_amount = 99 (less than required 100)

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);
    }

    #[test]
    fun should_succeed_when_mint_shares_slippage_within_tolerance() {
        // Test that mint_shares succeeds when max_amount is greater than or equal to actual amount needed
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let shares_to_mint = 100000000; // 100 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // With default rate of 1.0 (1e9), minting 100 shares requires 100 USDC
        // Setting max_amount to 101 should succeed (within tolerance)
        let receipt = test_utils::mint_shares_with_slippage<USDC, UltraUSDC>(&mut scenario, user, shares_to_mint, option::some(200000000), 101000000); // max_amount = 101

        assert!(coin::value(&receipt) == shares_to_mint, 0); // Should receive 100 shares
        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);
    }

}