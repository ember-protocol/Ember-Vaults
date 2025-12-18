#[test_only]
module ember_vaults::test_redeem {

    use sui::test_scenario;
    use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
    use ember_vaults::vault::{Self, Vault};
    use sui::coin::{Self};
    use ember_vaults::queue;

    #[test]
    fun should_redeem_shares_from_vault() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        // the rae is 100 for 1:1 ratio
        let deposit_amount = 1000000; // 10 USDC
        let redeem_amount = 500000; // 5 Shares
 
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);

        // Verify the withdrawal request was created
        test_scenario::next_tx(&mut scenario, user);
        let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
        let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
        assert!(queue::len(pending_withdrawals) == 1, 1);
        test_scenario::return_shared(vault);

        // Verify withdrawal request properties
        let (requester, receiver, asset_amount, shares_amount, _timestamp, _nonce) = vault::decode_withdrawal_request(&withdrawal_request);
        assert!(requester == user, 2);
        assert!(receiver == user, 3);
        assert!(asset_amount == redeem_amount, 4);
        assert!(shares_amount == redeem_amount, 5); // 1:1 ratio at default rate

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);           
        
    }

    #[test]
    fun should_redeem_all_shares_and_have_zero_receipt_tokens() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        // the rae is 100 for 1:1 ratio
        let deposit_amount = 1000000; // 10 USDC
        let redeem_shares = 1000000; // 10 Shares
 
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_shares, user, user);

        // Verify we have no remaining receipt tokens (all withdrawn)
        assert!(coin::value(&remaining_receipt) == 0, 1);

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);           
    }

    #[test]
    fun should_show_correct_pending_withdrawal_shares_for_user_after_multiple_withdrawals() {

        let user = test_utils::alice();
        // the rae is 100 for 1:1 ratio
        let deposit_amount = 1000000; // 10 USDC
        let redeem_shares = 200000; // 2 Shares

        let mut scenario = test_scenario::begin(user);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_shares, user, user);

        // Verify the withdrawal request was created
        test_scenario::next_tx(&mut scenario, user);
        let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
        let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
        assert!(queue::len(pending_withdrawals) == 1, 1);
        test_scenario::return_shared(vault);

        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, remaining_receipt, redeem_shares, user, user);

        // Verify the withdrawal request was created
        test_scenario::next_tx(&mut scenario, user);
        let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
        let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
        // Verify the pending withdrawal shares for the user
        let pending_shares = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user);
        assert!(pending_shares == redeem_shares * 2, 1);

        let request = queue::peek(pending_withdrawals);
        let (requester, receiver, asset_amount, shares_amount, _timestamp, _nonce) = vault::decode_withdrawal_request(request);
        assert!(requester == user, 2);
        assert!(receiver == user, 3);
        assert!(asset_amount == redeem_shares, 4);
        assert!(shares_amount == redeem_shares, 5); // 1:1 ratio at default rate

        coin::burn_for_testing(remaining_receipt);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);           
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInsufficientShares)]
    fun should_fail_if_redeem_shares_is_less_than_min_withdrawal_shares() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        // the rae is 100 for 1:1 ratio
        let deposit_amount = 1000000; // 10 USDC
        let redeem_shares = 0; // 0 Shares
 
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_shares, user, user);

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
    fun should_fail_if_protocol_is_paused() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        // the rae is 100 for 1:1 ratio
        let deposit_amount = 1000000; // 10 USDC
        let redeem_shares = 500000; // 5 Shares
 
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        test_utils::pause_non_admin_operations(&mut scenario);

        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_shares, user, user);

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);           
        
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EVaultPaused)]
    fun should_fail_if_vault_is_paused() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        // the rae is 100 for 1:1 ratio
        let deposit_amount = 1000000; // 10 USDC
        let redeem_shares = 500000; // 5 Shares
 
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        test_utils::pause_vault_operations(&mut scenario);

        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_shares, user, user);

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);           
        
    }


    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EBlacklistedAccount)]
    fun should_fail_if_user_is_blacklisted() {

        let operator = test_utils::bob();
        let user = test_utils::alice();
        // the rae is 100 for 1:1 ratio
        let deposit_amount = 1000000; // 10 USDC
        let redeem_shares = 500000; // 5 Shares
 
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        test_utils::black_list_address(&mut scenario, user, true);

        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_shares, user, user);

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);           
        
    }
    
}