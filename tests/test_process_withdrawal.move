#[test_only]
module ember_vaults::test_process_withdrawal {

    // === Imports ===
    use sui::test_scenario::{Self};
    use sui::coin::{Self};
    use sui::balance::{Self};
    use sui::clock::{Self};
    use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
    use ember_vaults::vault::{Self, Vault};
    use ember_vaults::admin::{ProtocolConfig};
    use ember_vaults::queue;

    // === Test Constants ===
    const DEPOSIT_AMOUNT: u64 = 1000000; // 10 USDC
    const REDEEM_AMOUNT: u64 = 500000;   // 5 shares
    const TIMESTAMP_1: u64 = 1000000000; // Earlier timestamp
    const TIMESTAMP_2: u64 = 2000000000; // Later timestamp
    const TIMESTAMP_3: u64 = 3000000000; // Even later timestamp

    // === Happy Path Tests ===

    #[test]
    fun test_process_withdrawal_request_single_request() {
        let operator = test_utils::bob();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Setup: Deposit and redeem to create a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, REDEEM_AMOUNT, user, user);
        coin::burn_for_testing(remaining_receipt);

        // Verify there's 1 request in the queue
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 1, 0);
            test_scenario::return_shared(vault);
        };

        // Process the withdrawal request
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Verify the queue is now empty
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 0, 1);
            
            // Verify shares were burned
            let pending_shares = vault::get_pending_shares_to_redeem<USDC, UltraUSDC>(&vault);
            assert!(pending_shares == 0, 2);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_withdrawal_request_multiple_requests() {
        let operator = test_utils::bob();
        let user1 = test_utils::alice();
        let user2 = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create multiple withdrawal requests
        let receipt1 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, DEPOSIT_AMOUNT);
        let (remaining1, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, REDEEM_AMOUNT, user1, user1);
        coin::burn_for_testing(remaining1);

        let receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user2, DEPOSIT_AMOUNT);
        let (remaining2, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, REDEEM_AMOUNT, user2, user2);
        coin::burn_for_testing(remaining2);

        // Verify there are 2 requests in the queue
        test_scenario::next_tx(&mut scenario, user1);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 2, 0);
            test_scenario::return_shared(vault);
        };

        // Process both withdrawal requests
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 2);

        // Verify the queue is now empty
        test_scenario::next_tx(&mut scenario, user1);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 0, 1);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_withdrawal_request_up_to_timestamp() {
        let operator = test_utils::bob();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create withdrawal request at TIMESTAMP_1
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

        // Process requests up to TIMESTAMP_2 (should process the request from TIMESTAMP_1)
        test_utils::process_withdrawal_request_up_to_timestamp<USDC, UltraUSDC>(&mut scenario, TIMESTAMP_3, TIMESTAMP_2);

        // Verify the queue is now empty
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 0, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_withdrawal_request_up_to_timestamp_excludes_newer_requests() {
        let operator = test_utils::bob();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create withdrawal request at TIMESTAMP_2 (later timestamp)
        test_scenario::next_tx(&mut scenario, user);
        {
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_2);

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

        // Process requests up to TIMESTAMP_1 (should NOT process the request from TIMESTAMP_2)
        test_utils::process_withdrawal_request_up_to_timestamp<USDC, UltraUSDC>(&mut scenario, TIMESTAMP_3, TIMESTAMP_1);

        // Verify the queue still has 1 request
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 1, 0);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Error Condition Tests ===

    #[test]
    #[expected_failure(abort_code = vault::EInvalidPermission)]
    fun test_process_withdrawal_request_unauthorized_caller() {
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let unauthorized = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, REDEEM_AMOUNT, user, user);
        coin::burn_for_testing(remaining);

        // Try to process with unauthorized caller
        test_scenario::next_tx(&mut scenario, unauthorized);
        {
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1);

            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);

            vault::process_withdrawal_requests<USDC, UltraUSDC>(&mut vault, &config, 1, &clock, test_scenario::ctx(&mut scenario));

            clock::destroy_for_testing(clock);
            test_scenario::return_shared(vault);
            test_scenario::return_shared(config);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = vault::EZeroAmount)]
    fun test_process_withdrawal_request_zero_requests() {
        let operator = test_utils::bob();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Try to process 0 requests - should fail
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, TIMESTAMP_1);

            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);

            vault::process_withdrawal_requests<USDC, UltraUSDC>(&mut vault, &config, 0, &clock, test_scenario::ctx(&mut scenario));

            clock::destroy_for_testing(clock);
            test_scenario::return_shared(vault);
            test_scenario::return_shared(config);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_should_process_zero_requests_from_empty_queue() {
        let operator = test_utils::bob();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Try to process from empty queue - should fail
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_withdrawal_request_with_blacklisted_user() {
        let operator = test_utils::bob();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let (remaining, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, REDEEM_AMOUNT, user, user);
        coin::burn_for_testing(remaining);

        // Blacklist the user
        test_utils::black_list_address(&mut scenario, user, true);

        // Process the withdrawal request - should skip but not fail
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Verify the queue is empty (request was processed but skipped)
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 0, 0);
            
            // Verify shares were still burned even though request was skipped
            let pending_shares = vault::get_pending_shares_to_redeem<USDC, UltraUSDC>(&vault);
            assert!(pending_shares == 0, 1);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_withdrawal_request_fifo_order() {
        let operator = test_utils::bob();
        let user1 = test_utils::alice();
        let user2 = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create requests with different amounts to verify FIFO order
        let receipt1 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, DEPOSIT_AMOUNT);
        let (remaining1, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, 100000, user1, user1); // First request
        coin::burn_for_testing(remaining1);

        let receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user2, DEPOSIT_AMOUNT);
        let (remaining2, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, 200000, user2, user2); // Second request
        coin::burn_for_testing(remaining2);

        // Verify there are 2 requests in queue
        test_scenario::next_tx(&mut scenario, user1);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 2, 0);
            
            // Verify both users have pending withdrawal shares
            let user1_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user1);
            let user2_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user2);
            assert!(user1_pending == 100000, 1);
            assert!(user2_pending == 200000, 2);
            
            test_scenario::return_shared(vault);
        };

        // Process one request - should process user1's request first (FIFO)
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Verify only user1's pending shares were processed (FIFO behavior)
        test_scenario::next_tx(&mut scenario, user1);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 1, 3); // One request left
            
            // user1's pending shares should be 0 (processed)
            let user1_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user1);
            assert!(user1_pending == 0, 4);
            
            // user2's pending shares should still be 200000 (not processed yet)
            let user2_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user2);
            assert!(user2_pending == 200000, 5);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Cancelled Request Processing Tests ===

    #[test]
    fun test_process_cancelled_withdrawal_request() {
        let operator = test_utils::bob();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Setup: Deposit and redeem to create a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, REDEEM_AMOUNT, user, user);
        
        let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);
        coin::burn_for_testing(remaining_receipt);

        // Cancel the withdrawal request
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify request is cancelled but still in queue
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            
            assert!(queue::len(pending_withdrawals) == 1, 0);
            assert!(vector::length(&cancelled_requests) == 1, 1);
            assert!(*vector::borrow(&cancelled_requests, 0) == sequence_number, 2);
            
            test_scenario::return_shared(vault);
        };

        // Process the cancelled withdrawal request
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Verify the queue is now empty and request was skipped
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            
            assert!(queue::len(pending_withdrawals) == 0, 3);
            
            // Verify shares were returned (not burned) - pending shares should be 0
            let pending_shares = vault::get_pending_shares_to_redeem<USDC, UltraUSDC>(&vault);
            assert!(pending_shares == 0, 4);
            
            // User should have no more pending withdrawal shares
            let user_pending_shares = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user);
            assert!(user_pending_shares == 0, 5);
            
            test_scenario::return_shared(vault);
        };

        // Verify user received their shares back
        test_scenario::next_tx(&mut scenario, user);
        {
            let user_receipts = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, user);
            assert!(coin::value(&user_receipts) == REDEEM_AMOUNT, 6);
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(user, user_receipts);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_mixed_cancelled_and_normal_requests() {
        let operator = test_utils::bob();
        let user1 = test_utils::alice();
        let user2 = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // User1 creates a withdrawal request
        let receipt1 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, DEPOSIT_AMOUNT);
        let (remaining1, withdrawal_request1) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, REDEEM_AMOUNT, user1, user1);
        let sequence_number1 = vault::get_withdrawal_receipt_nonce(&withdrawal_request1);
        coin::burn_for_testing(remaining1);

        // User2 creates a withdrawal request  
        let receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user2, DEPOSIT_AMOUNT);
        let (remaining2, _withdrawal_request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, REDEEM_AMOUNT, user2, user2);
        coin::burn_for_testing(remaining2);

        // User1 cancels their request
        test_scenario::next_tx(&mut scenario, user1);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number1, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify initial state: 2 requests in queue, 1 cancelled
        test_scenario::next_tx(&mut scenario, user1);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user1);
            
            assert!(queue::len(pending_withdrawals) == 2, 0);
            assert!(vector::length(&cancelled_requests) == 1, 1);
            
            test_scenario::return_shared(vault);
        };

        // Process both withdrawal requests
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 2);

        // Verify both requests were processed (one skipped, one executed)
        test_scenario::next_tx(&mut scenario, user1);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            
            assert!(queue::len(pending_withdrawals) == 0, 2);
            
            // Both users should have no pending withdrawal shares
            let user1_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user1);
            let user2_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user2);
            assert!(user1_pending == 0, 3);
            assert!(user2_pending == 0, 4);
            
            test_scenario::return_shared(vault);
        };

        // Verify user1 received their shares back (cancelled request)
        test_scenario::next_tx(&mut scenario, user1);
        {
            let user1_receipts = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, user1);
            assert!(coin::value(&user1_receipts) == REDEEM_AMOUNT, 5);
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(user1, user1_receipts);
        };

        // Verify user2 received their withdrawal amount (normal processing)
        test_scenario::next_tx(&mut scenario, user2);
        {
            let user2_coins = test_scenario::take_from_address<coin::Coin<USDC>>(&scenario, user2);
            assert!(coin::value(&user2_coins) == REDEEM_AMOUNT, 6); // 1:1 rate
            test_scenario::return_to_address<coin::Coin<USDC>>(user2, user2_coins);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_multiple_cancelled_requests_from_same_user() {
        let operator = test_utils::bob();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // User creates multiple withdrawal requests
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT * 3);
        
        let (receipt1, withdrawal_request1) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, REDEEM_AMOUNT, user, user);
        let (receipt2, withdrawal_request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, REDEEM_AMOUNT, user, user);
        let (remaining_receipt, withdrawal_request3) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, REDEEM_AMOUNT, user, user);
        
        let sequence_number1 = vault::get_withdrawal_receipt_nonce(&withdrawal_request1);
        let _sequence_number2 = vault::get_withdrawal_receipt_nonce(&withdrawal_request2);
        let sequence_number3 = vault::get_withdrawal_receipt_nonce(&withdrawal_request3);
        coin::burn_for_testing(remaining_receipt);

        // User cancels first and third requests
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number1, test_scenario::ctx(&mut scenario));
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number3, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify initial state: 3 requests in queue, 2 cancelled
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            
            assert!(queue::len(pending_withdrawals) == 3, 0);
            assert!(vector::length(&cancelled_requests) == 2, 1);
            assert!(vector::contains(&cancelled_requests, &sequence_number1), 2);
            assert!(vector::contains(&cancelled_requests, &sequence_number3), 3);
            
            test_scenario::return_shared(vault);
        };

        // Process all withdrawal requests
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 3);

        // Verify all requests were processed
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            
            assert!(queue::len(pending_withdrawals) == 0, 4);
            
            // User should have no pending withdrawal shares
            let user_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user);
            assert!(user_pending == 0, 5);
            
            test_scenario::return_shared(vault);
        };

        // Verify user received shares back for cancelled requests (2 separate coins)
        test_scenario::next_tx(&mut scenario, user);
        {
            let user_receipts1 = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, user);
            let user_receipts2 = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, user);
            
            // Each cancelled request returns a separate coin
            assert!(coin::value(&user_receipts1) == REDEEM_AMOUNT, 6); 
            assert!(coin::value(&user_receipts2) == REDEEM_AMOUNT, 7); 
            
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(user, user_receipts1);
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(user, user_receipts2);
        };

        // Verify user received withdrawal amount for non-cancelled request
        test_scenario::next_tx(&mut scenario, user);
        {
            let user_coins = test_scenario::take_from_address<coin::Coin<USDC>>(&scenario, user);
            assert!(coin::value(&user_coins) == REDEEM_AMOUNT, 7); // One processed request
            test_scenario::return_to_address<coin::Coin<USDC>>(user, user_coins);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_cancelled_request_with_timestamp_processing() {
        let operator = test_utils::bob();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create withdrawal request at TIMESTAMP_1
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

            let withdrawal_request = vault::redeem_shares<USDC, UltraUSDC>(&mut vault, &config, shares_balance, user, &clock, test_scenario::ctx(&mut scenario));
            let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);

            // Cancel the request
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));

            coin::burn_for_testing(coin::from_balance(receipt_balance, test_scenario::ctx(&mut scenario)));
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(vault);
            test_scenario::return_shared(config);
        };

        // Process requests up to TIMESTAMP_2 (should process the cancelled request from TIMESTAMP_1)
        test_utils::process_withdrawal_request_up_to_timestamp<USDC, UltraUSDC>(&mut scenario, TIMESTAMP_3, TIMESTAMP_2);

        // Verify the queue is now empty (cancelled request was processed/skipped)
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            assert!(queue::len(pending_withdrawals) == 0, 0);
            
            // User should have no pending withdrawal shares
            let user_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user);
            assert!(user_pending == 0, 1);
            
            test_scenario::return_shared(vault);
        };

        // Verify user received their shares back
        test_scenario::next_tx(&mut scenario, user);
        {
            let user_receipts = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, user);
            assert!(coin::value(&user_receipts) == REDEEM_AMOUNT, 2);
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(user, user_receipts);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_cancelled_request_fifo_order_maintained() {
        let operator = test_utils::bob();
        let user1 = test_utils::alice();
        let user2 = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create requests in order: user1 (normal), user2 (to be cancelled), user1 (normal)
        let receipt1a = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, DEPOSIT_AMOUNT);
        let (remaining1a, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1a, 100000, user1, user1);
        coin::burn_for_testing(remaining1a);

        let receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user2, DEPOSIT_AMOUNT);
        let (remaining2, withdrawal_request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, 200000, user2, user2);
        let sequence_number2 = vault::get_withdrawal_receipt_nonce(&withdrawal_request2);
        coin::burn_for_testing(remaining2);

        let receipt1b = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, DEPOSIT_AMOUNT);
        let (remaining1b, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1b, 300000, user1, user1);
        coin::burn_for_testing(remaining1b);

        // Cancel user2's request (middle request)
        test_scenario::next_tx(&mut scenario, user2);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number2, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Process all requests - should maintain FIFO order (user1, user2-cancelled, user1)
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 3);

        // Verify all requests were processed
        test_scenario::next_tx(&mut scenario, user1);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            
            assert!(queue::len(pending_withdrawals) == 0, 0);
            
            // Both users should have no pending withdrawal shares
            let user1_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user1);
            let user2_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user2);
            assert!(user1_pending == 0, 1);
            assert!(user2_pending == 0, 2);
            
            test_scenario::return_shared(vault);
        };

        // Verify user1 received withdrawal amounts for both processed requests (2 separate coins)
        test_scenario::next_tx(&mut scenario, user1);
        {
            let user1_coins1 = test_scenario::take_from_address<coin::Coin<USDC>>(&scenario, user1);
            let user1_coins2 = test_scenario::take_from_address<coin::Coin<USDC>>(&scenario, user1);
            
            // Each processed request returns a separate coin (100000 and 300000)
            let total_amount = coin::value(&user1_coins1) + coin::value(&user1_coins2);
            assert!(total_amount == 400000, 3); // 100000 + 300000
            
            test_scenario::return_to_address<coin::Coin<USDC>>(user1, user1_coins1);
            test_scenario::return_to_address<coin::Coin<USDC>>(user1, user1_coins2);
        };

        // Verify user2 received their shares back (cancelled request)
        test_scenario::next_tx(&mut scenario, user2);
        {
            let user2_receipts = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, user2);
            assert!(coin::value(&user2_receipts) == 200000, 4);
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(user2, user2_receipts);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_process_cancelled_and_blacklisted_request() {
        let operator = test_utils::bob();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Setup: Deposit and redeem to create a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, DEPOSIT_AMOUNT);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, REDEEM_AMOUNT, user, user);
        
        let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);
        coin::burn_for_testing(remaining_receipt);

        // Cancel the withdrawal request
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Also blacklist the user
        test_utils::black_list_address(&mut scenario, user, true);

        // Process the withdrawal request (both cancelled AND blacklisted)
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Verify the queue is now empty and request was skipped
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let pending_withdrawals = vault::get_withdrawal_queue<USDC, UltraUSDC>(&vault);
            
            assert!(queue::len(pending_withdrawals) == 0, 0);
            
            // User should have no pending withdrawal shares
            let user_pending = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user);
            assert!(user_pending == 0, 1);
            
            test_scenario::return_shared(vault);
        };

        // Verify user received their shares back (request was skipped due to cancellation/blacklist)
        test_scenario::next_tx(&mut scenario, user);
        {
            let user_receipts = test_scenario::take_from_address<coin::Coin<UltraUSDC>>(&scenario, user);
            assert!(coin::value(&user_receipts) == REDEEM_AMOUNT, 2);
            test_scenario::return_to_address<coin::Coin<UltraUSDC>>(user, user_receipts);
        };

        test_scenario::end(scenario);
    }
}