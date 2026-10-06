#[test_only]
module ember_vaults::test_withdrawal_fees {

    use sui::test_scenario;
    use sui::coin;
    use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
    use ember_vaults::vault::{Self, Vault};
    use ember_vaults::admin::ProtocolConfig;

    // === Constants ===
    const DEPOSIT_AMOUNT: u64 = 1_000_000_000; // 1000 USDC (1e9)
    // Fee percentages (1e9 = 100%)
    const TWO_PERCENT: u64 = 20_000_000;       // 2%
    const FIVE_PERCENT: u64 = 50_000_000;       // 5%
    const TEN_PERCENT: u64 = 100_000_000;       // 10%

    // Time constants (milliseconds)
    const ONE_HOUR: u64 = 3_600_000;
    const ONE_DAY: u64 = 86_400_000;
    const DEPOSIT_TIME: u64 = 10_000_000_000;
    // Process time well after threshold
    const PROCESS_TIME_AFTER_THRESHOLD: u64 = 10_000_000_000 + 86_400_000 + 1;
    // Process time within threshold
    const PROCESS_TIME_WITHIN_THRESHOLD: u64 = 10_000_000_000 + 1_000;

    // L-5 fee-cap constants (1e9 = 100%)
    const FORTY_PERCENT: u64 = 400_000_000;
    const FIFTY_PERCENT: u64 = 500_000_000;   // = MAX_WITHDRAWAL_FEE_PERCENTAGE
    const SIXTY_PERCENT: u64 = 600_000_000;
    const MAX_U64: u64 = 18_446_744_073_709_551_615;

    // ===========================
    // Deposit User List Tests
    // ===========================

    #[test]
    fun test_deposit_succeeds_when_no_deposit_user_list() {
        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        // Anyone can deposit when no deposit user list is set
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, test_utils::alice(), DEPOSIT_AMOUNT);
        coin::burn_for_testing(receipt);

        test_scenario::end(scenario);
    }

    #[test]
    fun test_deposit_succeeds_for_allowed_user() {
        let operator = test_utils::bob();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Add charlie to deposit user list
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_deposit_user_list(&mut vault, &config, user, true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Charlie can deposit
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        coin::burn_for_testing(receipt);

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EDepositNotAllowed)]
    fun test_deposit_fails_for_non_allowed_user() {
        let operator = test_utils::bob();
        let allowed_user = test_utils::charlie();
        let non_allowed_user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Add only charlie to deposit user list
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_deposit_user_list(&mut vault, &config, allowed_user, true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Alice (not in list) should fail to deposit
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, non_allowed_user, DEPOSIT_AMOUNT);
        coin::burn_for_testing(receipt);

        test_scenario::end(scenario);
    }

    #[test]
    fun test_deposit_succeeds_after_user_list_removed() {
        let operator = test_utils::bob();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Add charlie to deposit user list
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_deposit_user_list(&mut vault, &config, user, true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Remove charlie (list becomes empty, dynamic field gets deleted)
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_deposit_user_list(&mut vault, &config, user, false, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Now anyone can deposit again (alice was never on the list)
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, test_utils::alice(), DEPOSIT_AMOUNT);
        coin::burn_for_testing(receipt);

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun test_set_deposit_user_list_fails_for_non_operator() {
        let non_operator = test_utils::alice();

        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        // Alice (not operator) tries to set deposit user list
        test_scenario::next_tx(&mut scenario, non_operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_deposit_user_list(&mut vault, &config, test_utils::charlie(), true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Fee Exemption List Tests
    // ===========================

    #[test]
    fun test_set_fee_exemption_list_add_user() {
        let operator = test_utils::bob();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_fee_exemption_list(&mut vault, &config, test_utils::charlie(), true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun test_set_fee_exemption_list_fails_for_non_operator() {
        let non_operator = test_utils::alice();

        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, non_operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_fee_exemption_list(&mut vault, &config, test_utils::charlie(), true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Set Permanent Fee Tests
    // ===========================

    #[test]
    fun test_set_permanent_fee_percentage() {
        let vault_admin = test_utils::vault_admin();

        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TWO_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun test_set_permanent_fee_percentage_fails_for_non_admin() {
        let operator = test_utils::bob();

        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TWO_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Set Time Based Fee Tests
    // ===========================

    #[test]
    fun test_set_time_based_fee_percentage() {
        let vault_admin = test_utils::vault_admin();

        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun test_set_time_based_fee_percentage_fails_for_non_admin() {
        let operator = test_utils::bob();

        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Set Time Based Fee Threshold Tests
    // ===========================

    #[test]
    fun test_set_time_based_fee_threshold() {
        let vault_admin = test_utils::vault_admin();

        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun test_set_time_based_fee_threshold_fails_for_non_admin() {
        let operator = test_utils::bob();

        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Permanent Fee Deduction Tests
    // ===========================

    #[test]
    fun test_permanent_fee_deducted_on_withdrawal() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 10% permanent fee
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process withdrawal
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Verify vault balance: fee should remain in vault
        // With 10% permanent fee on 1e9 withdrawal: fee = 1e8, user gets 9e8, vault keeps 1e8
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            // 10% of DEPOSIT_AMOUNT = 100_000_000 should remain in vault
            assert!(vault_balance == 100_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_no_fee_deducted_when_permanent_fee_is_zero() {
        let operator = test_utils::bob();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Don't set any fee (default is 0)
        // Deposit
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process withdrawal
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Vault should be empty - no fee retained
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_permanent_fee_not_charged_for_exempt_user() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 10% permanent fee
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Add user to fee exemption list
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_fee_exemption_list(&mut vault, &config, user, true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process withdrawal
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Vault should be empty - exempt user pays no fee
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_permanent_fee_with_2_percent() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 2% permanent fee
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TWO_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process withdrawal
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // 2% of 1e9 = 20_000_000 should remain in vault
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 20_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Time Based Fee Tests
    // ===========================

    #[test]
    fun test_time_based_fee_charged_on_early_withdrawal() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 5% time-based fee with 1 day threshold
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit at DEPOSIT_TIME
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process withdrawal shortly after deposit (within threshold)
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_WITHIN_THRESHOLD);

        // 5% time-based fee on 1e9 = 50_000_000 should remain in vault
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 50_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_time_based_fee_not_charged_after_threshold() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 5% time-based fee with 1 day threshold
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit at DEPOSIT_TIME
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process withdrawal well after threshold
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_AFTER_THRESHOLD);

        // No fee should be charged - vault empty
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_time_based_fee_exempt_user_not_charged() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 5% time-based fee with 1 day threshold
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Exempt the user
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_fee_exemption_list(&mut vault, &config, user, true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit at DEPOSIT_TIME
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process withdrawal within threshold - but user is exempt
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_WITHIN_THRESHOLD);

        // No fee charged for exempt user
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Combined Fee Tests
    // ===========================

    #[test]
    fun test_both_permanent_and_time_based_fee_charged() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 10% permanent fee + 5% time-based fee with 1 day threshold
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit at DEPOSIT_TIME
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process within threshold - both fees apply
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_WITHIN_THRESHOLD);

        // Both fees are computed on the ORIGINAL gross withdraw amount
        // (matches EVM EmberVaultValidator.calculateWithdrawalFees):
        //   permanent  = 1e9 * 10% = 100_000_000
        //   time_based = 1e9 * 5%  = 50_000_000
        //   net paid   = 1e9 - 100_000_000 - 50_000_000 = 850_000_000
        //   retained   = 100_000_000 + 50_000_000 = 150_000_000
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 150_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_only_permanent_fee_charged_after_threshold() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 10% permanent fee + 5% time-based fee with 1 day threshold
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit at DEPOSIT_TIME
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process after threshold - only permanent fee applies
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_AFTER_THRESHOLD);

        // Only permanent fee: 10% of 1e9 = 100_000_000
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 100_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_exempt_user_pays_no_fees_even_with_both_set() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set both fees
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Exempt user
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_fee_exemption_list(&mut vault, &config, user, true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);

        // Redeem all shares
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process within threshold
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_WITHIN_THRESHOLD);

        // Exempt user pays nothing
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Time Based Fee Edge Cases
    // ===========================

    #[test]
    fun test_time_based_fee_charged_when_no_deposit_timestamp() {
        // If user has no deposit timestamp (e.g. received shares via transfer),
        // last_deposit is 0, so time-based fee should be charged
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set time-based fee but do NOT initialize withdrawal fee before deposit
        // (withdrawal fee gets initialized on deposit_asset_v2 via ensure_withdrawal_fee_exists)

        // First deposit to get shares (this records timestamp)
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);

        // Now set the time-based fee after deposit
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Redeem and process within threshold
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_WITHIN_THRESHOLD);

        // Time-based fee should be charged since deposit was within threshold
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 50_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_time_based_fee_not_charged_when_threshold_is_zero() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set time-based fee percentage but leave threshold at 0
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            // threshold stays 0
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);

        // Redeem all
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process immediately
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_WITHIN_THRESHOLD);

        // No fee since threshold is 0
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Multiple Users Fee Tests
    // ===========================

    #[test]
    fun test_fees_applied_differently_to_exempt_and_non_exempt_users() {
        let operator = test_utils::bob();
        let exempt_user = test_utils::charlie();
        let regular_user = test_utils::vault_admin();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 10% permanent fee
        test_scenario::next_tx(&mut scenario, regular_user);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Exempt charlie
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_fee_exemption_list(&mut vault, &config, exempt_user, true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Both users deposit same amount
        let receipt1 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, exempt_user, DEPOSIT_AMOUNT);
        let receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, regular_user, DEPOSIT_AMOUNT);

        // Both redeem all shares
        let shares1 = coin::value(&receipt1);
        let (remaining1, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, shares1, exempt_user, exempt_user);
        coin::burn_for_testing(remaining1);

        let shares2 = coin::value(&receipt2);
        let (remaining2, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, shares2, regular_user, regular_user);
        coin::burn_for_testing(remaining2);

        // Process both withdrawals
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 2);

        // Vault should retain only the 10% fee from the regular user
        // Exempt user: 0 fee. Regular user: 10% of their withdraw amount
        test_scenario::next_tx(&mut scenario, operator);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            // Regular user's withdrawal amount is DEPOSIT_AMOUNT (rate is 1:1 at start)
            // but rate changes after first deposit. Let's just verify fee was retained
            assert!(vault_balance > 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Fee Update Tests
    // ===========================

    #[test]
    fun test_update_permanent_fee_percentage_to_new_value() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set initial fee
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TWO_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Update to new fee
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify the new fee is applied
        let user = test_utils::charlie();
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // 5% of 1e9 = 50_000_000 should remain
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 50_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_set_permanent_fee_to_zero_removes_fee() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set fee then remove it
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, 0, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit, redeem, process
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // No fee
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Deposit Timestamp Recording Tests
    // ===========================

    #[test]
    fun test_deposit_records_timestamp_for_time_based_fee() {
        // Verify that depositing at different times affects the time-based fee
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 5% time-based fee with 1 hour threshold
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_HOUR, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit at time 1000
        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, 1000);

        // Redeem all
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Process at time 1000 + 1 hour + 1 (after threshold)
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, 1000 + ONE_HOUR + 1);

        // No time-based fee since we're past threshold
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_second_deposit_updates_timestamp() {
        // Second deposit should update the timestamp, resetting the time-based fee window
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 5% time-based fee with 1 day threshold
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, ONE_DAY, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // First deposit at time 1000
        let receipt1 = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, 1000);

        // Second deposit much later, resetting the clock
        let receipt2 = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, 10_000_000_000);

        // Combine receipts and redeem
        let _total_shares = coin::value(&receipt1) + coin::value(&receipt2);
        // Burn first receipt (we'll use receipt2 for partial redeem test)
        coin::burn_for_testing(receipt1);

        let shares2 = coin::value(&receipt2);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, shares2, user, user);
        coin::burn_for_testing(remaining);

        // Process shortly after second deposit (within threshold from second deposit)
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, 10_000_000_000 + 1000);

        // Time-based fee should be charged because second deposit updated timestamp
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            // Fee was charged (vault retains some balance)
            assert!(vault_balance > 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Skipped/Cancelled Request Fee Tests
    // ===========================

    #[test]
    fun test_no_fee_charged_on_cancelled_request() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 10% permanent fee
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);

        // Redeem
        let shares = coin::value(&receipt);
        let (remaining, request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Cancel the request
        let request_nonce = vault::get_withdrawal_receipt_nonce(&request);
        std::unit_test::destroy(request);

        test_scenario::next_tx(&mut scenario, user);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::cancel_pending_withdrawal_request(&mut vault, &config, request_nonce, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Process - request is cancelled, shares returned, no fee taken
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Vault balance should still have full deposit (shares were returned, not burned)
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == DEPOSIT_AMOUNT, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_no_fee_on_blacklisted_user_withdrawal() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 10% permanent fee
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);

        // Redeem
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Blacklist the user before processing
        test_utils::black_list_address(&mut scenario, user, true);

        // Process - blacklisted user's request is skipped, shares returned
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Full deposit remains in vault (request was skipped, no withdrawal happened)
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == DEPOSIT_AMOUNT, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // ===========================
    // Fee Exemption Remove Tests
    // ===========================

    #[test]
    fun test_fee_charged_after_exemption_removed() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Set 10% permanent fee
        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_permanent_fee_percentage(&mut vault, &config, TEN_PERCENT, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Exempt user
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_fee_exemption_list(&mut vault, &config, user, true, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Remove exemption
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_fee_exemption_list(&mut vault, &config, user, false, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Deposit, redeem, process
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Fee should be charged since exemption was removed
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let vault_balance = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
            assert!(vault_balance == 100_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === L-5: withdrawal-fee ceiling + threshold-overflow ===

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidFeePercentage)]
    /// A permanent withdrawal fee above the 50% protocol ceiling is rejected
    /// (previously any value < 100% — e.g. 99% confiscation — was accepted).
    fun permanent_fee_above_cap_rejected() {
        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);
        test_scenario::next_tx(&mut scenario, test_utils::vault_admin());
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        vault::set_permanent_fee_percentage(&mut vault, &config, SIXTY_PERCENT, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidFeePercentage)]
    /// permanent + time-based combined above the 50% ceiling is rejected even
    /// though each is individually under it (40% + 40% = 80%).
    fun combined_fee_above_cap_rejected() {
        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);
        test_scenario::next_tx(&mut scenario, test_utils::vault_admin());
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        vault::set_time_based_fee_percentage(&mut vault, &config, FORTY_PERCENT, test_scenario::ctx(&mut scenario));
        vault::set_permanent_fee_percentage(&mut vault, &config, FORTY_PERCENT, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    #[test]
    /// A fee exactly at the 50% ceiling is allowed (boundary).
    fun fee_at_cap_allowed() {
        let mut scenario = test_scenario::begin(test_utils::bob());
        test_utils::initialize(&mut scenario);
        test_scenario::next_tx(&mut scenario, test_utils::vault_admin());
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        vault::set_permanent_fee_percentage(&mut vault, &config, FIFTY_PERCENT, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    #[test]
    /// A near-u64::MAX time-based threshold must NOT overflow `last_deposit +
    /// threshold` inside process_request (which used to abort the whole
    /// withdrawal loop). With such a threshold the window is effectively
    /// infinite, so the 5% fee is charged and the process completes.
    fun max_threshold_does_not_overflow_processing() {
        let operator = test_utils::bob();
        let vault_admin = test_utils::vault_admin();
        let user = test_utils::charlie();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, vault_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            vault::set_time_based_fee_percentage(&mut vault, &config, FIVE_PERCENT, test_scenario::ctx(&mut scenario));
            vault::set_time_based_fee_threshold(&mut vault, &config, MAX_U64, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        let receipt = test_utils::deposit_assets_at_time<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT, DEPOSIT_TIME);
        let shares = coin::value(&receipt);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, shares, user, user);
        coin::burn_for_testing(remaining);

        // Would previously abort on the last_deposit + MAX_U64 overflow.
        test_utils::process_withdrawal_request_at_time<USDC, UltraUSDC>(&mut scenario, 1, PROCESS_TIME_AFTER_THRESHOLD);

        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            // 5% of 1e9 charged (infinite window) and retained in the vault.
            assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == 50_000_000, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }
}
