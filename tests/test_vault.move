#[test_only]
module ember_vaults::tests_vault {
        use sui::test_scenario;
        use ember_vaults::admin::{Self, AdminCap, ProtocolConfig  };      
        use ember_vaults::vault::{Self};
        use ember_vaults::test_utils::{Self, USDC, UltraUSDC};
        use ember_vaults::vault::Vault;
        use sui::coin::{Self};
        use sui::coin::Coin;
        use sui::balance::{Self};
        use sui::clock::{Self};

        #[test]
        fun should_create_vault() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       
                let receipt_token_treasury_cap =         coin::create_treasury_cap_for_testing<UltraUSDC>(test_scenario::ctx(&mut scenario));

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                let vault = vault::create_vault<USDC,UltraUSDC>(
                        &config, 
                        receipt_token_treasury_cap,
                        &cap, 
                        b"Sample Vault".to_string(),
                        protocol_admin, test_utils::bob(), 
                        1000000000,
                        1000000, //0.1%    
                        1000000,// 1 share
                        3600000, // 1 hour in milliseconds (valid rate update interval)
                        1000000000000, // max_tvl: 1000 USDC (in e9 format)
                        vector::empty<address>(), 
                        test_scenario::ctx(&mut scenario));


                assert!(vault::get_vault_admin<USDC, UltraUSDC>(&vault) == protocol_admin, 1);
                assert!(vault::get_vault_operator<USDC, UltraUSDC>(&vault) == test_utils::bob(), 1);
                assert!(vault::get_vault_blacklisted<USDC, UltraUSDC>(&vault) == vector::empty(), 1);
                assert!(vault::get_vault_paused<USDC, UltraUSDC>(&vault) == false, 1);
                assert!(vector::length(&vault::get_vault_sub_accounts<USDC, UltraUSDC>(&vault)) == 0, 1);
                assert!(vault::get_vault_rate<USDC, UltraUSDC>(&vault) == admin::get_default_rate(&config), 1);
                assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == 0, 1);
                assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 1000000000, 1);
                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == 0, 1);
                assert!(vault::get_vault_total_shares_in_circulation<USDC, UltraUSDC>(&vault) == 0, 1);

                vault::share_vault(vault);
                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        fun should_update_vault_rate() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, 1010000000);

                test_scenario::next_tx(&mut scenario, operator);
                let vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );
                assert!(vault::get_vault_rate<USDC, UltraUSDC>(&vault) == 1010000000, 1);
                test_scenario::return_shared(vault);

                test_scenario::end(scenario);   
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
        fun should_fail_to_update_vault_rate_when_protocol_is_paused() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);

                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);
                admin::pause_non_admin_operations(&mut config, &cap, true);
                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, 1010000000);

                test_scenario::end(scenario);   
        }

        

        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
        fun should_fail_to_update_vault_rate_when_caller_is_not_operator() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);


                test_scenario::next_tx(&mut scenario, @0x123);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario);
                let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
                clock::set_for_testing(&mut clock, 1000000000);

                vault::update_vault_rate(&mut vault, &config, 1020000000, &clock, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_rate<USDC,UltraUSDC>(&vault) == 1020000000, 3);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                clock::destroy_for_testing(clock);



                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidRate)]
        fun should_fail_to_update_vault_rate_when_rate_is_greater_than_max_rate() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, 60000000000);

                test_scenario::end(scenario);   

        }



        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidRate)]
        fun should_fail_to_update_vault_rate_when_rate_is_less_than_min_rate() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);

                test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, 10000);

                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidRate)]
        fun should_fail_to_update_vault_rate_when_rate_is_greater_than_max_rate_change_per_update() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, 1050000001);

                test_scenario::end(scenario);   
        }

        #[test]
        fun should_return_accounts_pending_withdrawal_shares_as_zero_when_no_pending_withdrawals() {

                let protocol_admin = test_utils::protocol_admin();
                let user = test_utils::alice();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);
                

                test_scenario::next_tx(&mut scenario, user);
                let vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                let pending_shares = vault::get_account_total_pending_withdrawal_shares<USDC, UltraUSDC>(&vault, user);

                assert!(pending_shares == 0, 1);

                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidInterval)]
        fun should_fail_to_update_vault_rate_when_interval_is_not_met() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000, 1010000000);                

                test_utils::update_vault_rate<USDC,UltraUSDC>(&mut scenario, 1000000000 + 8640000, 1020000000);

                test_scenario::end(scenario);   
        }


        #[test]
        fun should_update_vault_admin() {

                let protocol_admin = test_utils::protocol_admin();
                let new_admin = @0x123;

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);
                

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                vault::change_vault_admin<USDC, UltraUSDC>(&mut vault, &config, &cap, new_admin);

                assert!(vault::get_vault_admin<USDC, UltraUSDC>(&vault) == new_admin, 1);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);
                test_scenario::end(scenario);   
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidAccount)]
        fun should_fail_to_update_vault_admin_to_zero_address() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);
                

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                vault::change_vault_admin<USDC, UltraUSDC>(&mut vault, &config, &cap, @0);


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidAccount)]
        fun should_fail_to_update_vault_admin_to_current_admin_address() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);
                

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                vault::change_vault_admin<USDC, UltraUSDC>(&mut vault, &config, &cap, protocol_admin);


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);
                test_scenario::end(scenario);   
        }


        #[test]
        fun should_update_vault_operator() {

                let protocol_admin = test_utils::protocol_admin();
                let new_operator = @0x123;

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);
                

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::change_vault_operator<USDC,UltraUSDC>( &mut vault, &config, new_operator, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_operator<USDC, UltraUSDC>(&vault) == new_operator, 1);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
        fun should_fail_to_update_vault_operator_when_caller_is_not_admin() {

                let protocol_admin = test_utils::protocol_admin();
                let random_user = test_utils::alice();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);
                

                test_scenario::next_tx(&mut scenario, random_user);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::change_vault_operator<USDC,UltraUSDC>( &mut vault, &config, random_user, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_operator<USDC, UltraUSDC>(&vault) == random_user, 1);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidAccount)]
        fun should_fail_to_update_vault_operator_to_zero_address() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);
                

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::change_vault_operator<USDC,UltraUSDC>( &mut vault, &config,@0, test_scenario::ctx(&mut scenario));


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidAccount)]
        fun should_fail_to_update_vault_operator_to_current_operator_address() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);
                

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::change_vault_operator<USDC,UltraUSDC>( &mut vault, &config, operator, test_scenario::ctx(&mut scenario));


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        fun should_update_vault_fee_percentage() {

                let protocol_admin = test_utils::protocol_admin();
                let new_fee_percentage = 2000000; // Change from 0.1% to 0.2%

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );
                let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
                clock::set_for_testing(&mut clock, 10000000000);

                vault::update_vault_fee_percentage_v2<USDC,UltraUSDC>(&mut vault, &config, new_fee_percentage, &clock, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_fee_percentage<USDC, UltraUSDC>(&vault) == new_fee_percentage, 1);

                clock::destroy_for_testing(clock);
                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidFeePercentage)]
        fun should_fail_to_update_vault_fee_percentage_when_fee_percentage_is_greater_than_max_allowed_fee_percentage() {

                let protocol_admin = test_utils::protocol_admin();
                let new_fee_percentage = 200000000; //20%

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );
                let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
                clock::set_for_testing(&mut clock, 10000000000);

                vault::update_vault_fee_percentage_v2<USDC,UltraUSDC>(&mut vault, &config, new_fee_percentage, &clock, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_fee_percentage<USDC, UltraUSDC>(&vault) == new_fee_percentage, 1);

                clock::destroy_for_testing(clock);
                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
        fun should_fail_when_non_admin_tries_to_update_vault_fee_percentage() {

                let protocol_admin = test_utils::protocol_admin();
                let random_user = test_utils::alice();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, random_user);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );
                let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
                clock::set_for_testing(&mut clock, 10000000000);

                vault::update_vault_fee_percentage_v2<USDC,UltraUSDC>(&mut vault, &config, 100, &clock, test_scenario::ctx(&mut scenario));

                clock::destroy_for_testing(clock);
                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EZeroAmount)]
        fun should_fail_to_collect_zero_platform_fee() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::collect_platform_fee<USDC,UltraUSDC>(&mut vault, &config, test_scenario::ctx(&mut scenario));
                
                
                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   

        }


        #[test]
        fun should_collect_platform_fee() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::increase_platform_fee_accrued<USDC,UltraUSDC>(&mut vault, 1000000000, 1000000000);

                let collected_fee_before = vault::get_accrued_platform_fee<USDC, UltraUSDC>(&vault);
                assert!(collected_fee_before == 1000000000, 1);

                vault::collect_platform_fee<USDC,UltraUSDC>(&mut vault, &config, test_scenario::ctx(&mut scenario));                
                let collected_fee_after = vault::get_accrued_platform_fee<USDC, UltraUSDC>(&vault);
                assert!(collected_fee_after == 0, 2);

                let recipient = admin::get_platform_fee_recipient(&config);
                test_scenario::next_tx(&mut scenario, recipient);

                let coins = test_scenario::take_from_address<Coin<USDC>>(&scenario, recipient);

                assert!(coin::value(&coins) == 1000000000, 3);
                
                
                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<Coin<USDC>>(recipient, coins);
                test_scenario::end(scenario);   

        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
        fun should_fail_to_collect_platform_fee_when_protocol_is_paused() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::pause_non_admin_operations(&mut config, &cap, true);
                vault::collect_platform_fee<USDC,UltraUSDC>(&mut vault, &config, test_scenario::ctx(&mut scenario));                
                
                
                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);
                test_scenario::end(scenario);   
        }

        #[test]
        fun should_update_vault_paused_status() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::set_vault_paused_status<USDC,UltraUSDC>(&mut vault, &config, true, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_paused<USDC, UltraUSDC>(&vault) == true, 1);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidStatus)]
        fun should_fail_to_update_vault_paused_status_when_status_is_already_set() {

                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::set_vault_paused_status<USDC,UltraUSDC>(&mut vault, &config, false, test_scenario::ctx(&mut scenario));


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
        fun should_fail_to_update_vault_paused_status_when_caller_is_not_vault_admin() {

                let protocol_admin = test_utils::protocol_admin();
                let random_user = test_utils::alice();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, random_user);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::set_vault_paused_status<USDC,UltraUSDC>(&mut vault, &config, true, test_scenario::ctx(&mut scenario));


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
        fun should_fail_to_update_sub_account_when_caller_is_not_vault_admin() {

                let protocol_admin = test_utils::protocol_admin();
                let random_user = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, random_user);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::set_sub_account<USDC,UltraUSDC>(&mut vault, &config, random_user, true, test_scenario::ctx(&mut scenario));


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);          
        }

        #[test]
        fun should_add_a_new_sub_account() {

                let protocol_admin = test_utils::protocol_admin();
                let sub_account_a = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::set_sub_account<USDC,UltraUSDC>(&mut vault, &config, sub_account_a, true, test_scenario::ctx(&mut scenario));

                let sub_accounts = vault::get_vault_sub_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&sub_accounts) == 1, 1);
                let account = vector::borrow(&sub_accounts, 0);
                assert!(*account == sub_account_a, 2);


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        fun should_add_multiple_new_sub_accounts() {

                let protocol_admin = test_utils::protocol_admin();
                let sub_account_a = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let sub_account_b = @0x1234; // Use a different address (bob is operator, can't be sub_account)

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(&scenario );

                vault::set_sub_account<USDC,UltraUSDC>(&mut vault, &config, sub_account_a, true, test_scenario::ctx(&mut scenario));
                vault::set_sub_account(&mut vault, &config, sub_account_b, true, test_scenario::ctx(&mut scenario));

                let sub_accounts = vault::get_vault_sub_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&sub_accounts) == 2, 1);
                {
                    let account = vector::borrow(&sub_accounts, 0);
                    assert!(*account == sub_account_a, 2);
                };

                {
                    let account = vector::borrow(&sub_accounts, 1);
                    assert!(*account == sub_account_b, 3);
                };

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EAlreadyExists)]
        fun should_not_add_duplicate_sub_accounts_when_adding_a_new_sub_account() {

                let protocol_admin = test_utils::protocol_admin();
                let sub_account_a = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_sub_account(&mut vault, &config, sub_account_a, true, test_scenario::ctx(&mut scenario));
                // This second call should fail with EAlreadyExists
                vault::set_sub_account(&mut vault, &config, sub_account_a, true, test_scenario::ctx(&mut scenario));

                let sub_accounts = vault::get_vault_sub_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&sub_accounts) == 1, 1);
                let account = vector::borrow(&sub_accounts, 0);
                assert!(*account == sub_account_a, 2);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        fun should_remove_a_sub_account() {

                let protocol_admin = test_utils::protocol_admin();
                let sub_account_a = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_sub_account(&mut vault, &config, sub_account_a, true, test_scenario::ctx(&mut scenario));
                vault::set_sub_account(&mut vault, &config, sub_account_a, false, test_scenario::ctx(&mut scenario));

                let sub_accounts = vault::get_vault_sub_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&sub_accounts) == 0, 1);


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidRequest)]
        fun should_not_remove_a_sub_account_that_is_not_in_the_vault() {

                let protocol_admin = test_utils::protocol_admin();
                let sub_account_a = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let sub_account_b = @0x1234; // Use a different address (bob is operator, can't be sub_account)

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_sub_account(&mut vault, &config, sub_account_a, true, test_scenario::ctx(&mut scenario));
                // This should fail with EInvalidRequest because sub_account_b was never added
                vault::set_sub_account(&mut vault, &config, sub_account_b, false, test_scenario::ctx(&mut scenario));

                let sub_accounts = vault::get_vault_sub_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&sub_accounts) == 1, 1);


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
        fun should_fail_to_update_black_listed_accounts_when_protocol_is_paused() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::pause_non_admin_operations(&mut config, &cap, true);
                vault::set_blacklisted_account(&mut vault, &config, operator, true, test_scenario::ctx(&mut scenario));


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);
                test_scenario::end(scenario);          
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
        fun should_fail_to_update_black_listed_accounts_when_caller_is_not_vault_operator() {

                let protocol_admin = test_utils::protocol_admin();
                let random_user = test_utils::alice();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, random_user);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_blacklisted_account(&mut vault, &config, random_user, true, test_scenario::ctx(&mut scenario));


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);          
        }

        #[test]
        fun should_add_a_new_black_listed_account() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();
                let blacklisted_account_a = test_utils::alice();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_a, true, test_scenario::ctx(&mut scenario));

                let blacklisted = vault::get_vault_blacklisted_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&blacklisted) == 1, 1);
                let account = vector::borrow(&blacklisted, 0);
                assert!(*account == blacklisted_account_a, 2);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        fun should_add_multiple_new_black_listed_accounts() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();

                let blacklisted_account_a = test_utils::alice();
                let blacklisted_account_b = test_utils::bob();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_a, true, test_scenario::ctx(&mut scenario));
                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_b, true, test_scenario::ctx(&mut scenario));

                let blacklisted = vault::get_vault_blacklisted_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&blacklisted) == 2, 1);
                {
                    let account = vector::borrow(&blacklisted, 0);
                    assert!(*account == blacklisted_account_a, 2);
                };

                {
                    let account = vector::borrow(&blacklisted, 1);
                    assert!(*account == blacklisted_account_b, 3);
                };

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EAlreadyExists)]
        fun should_not_add_duplicate_black_listed_accounts_when_adding_a_new_black_listed_account() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();
                let blacklisted_account_a = test_utils::alice();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_a, true, test_scenario::ctx(&mut scenario));
                // This second call should fail with EAlreadyExists
                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_a, true, test_scenario::ctx(&mut scenario));

                let blacklisted = vault::get_vault_blacklisted_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&blacklisted) == 1, 1);
                let account = vector::borrow(&blacklisted, 0);
                assert!(*account == blacklisted_account_a, 2);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        fun should_remove_a_black_listed_account() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();
                let blacklisted_account_a = test_utils::alice();

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_a, true, test_scenario::ctx(&mut scenario));
                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_a, false, test_scenario::ctx(&mut scenario));

                let blacklisted = vault::get_vault_blacklisted_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&blacklisted) == 0, 1);


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidRequest)]
        fun should_not_remove_a_black_listed_account_that_is_not_in_the_vault() {

                let protocol_admin = test_utils::protocol_admin();
                let operator = test_utils::bob();
                let blacklisted_account_a = test_utils::alice();
                let blacklisted_account_b = @0x1234; // Use different account to avoid conflicts

                let mut scenario = test_scenario::begin(protocol_admin);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_a, true, test_scenario::ctx(&mut scenario));
                // This should fail with EInvalidRequest because blacklisted_account_b was never added
                vault::set_blacklisted_account(&mut vault, &config, blacklisted_account_b, false, test_scenario::ctx(&mut scenario));

                let blacklisted = vault::get_vault_blacklisted_accounts<USDC, UltraUSDC>(&vault);
                assert!(vector::length(&blacklisted) == 1, 1);


                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        fun should_allow_vault_operator_to_withdraw_from_vault_without_redeeming_shares() {

                let operator = test_utils::bob();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let vault_balance = 1000000000000;
                let withdrawal_amount = 10000;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::increase_vault_balance<USDC, UltraUSDC>(&mut vault, vault_balance);

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance, 1);

                vault::withdraw_from_vault_without_redeeming_shares(&mut vault, &config, sub_account, withdrawal_amount, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance - withdrawal_amount, 2);

                test_scenario::next_tx(&mut scenario, sub_account);
                let sub_account_balance = test_scenario::take_from_address<Coin<USDC>>(&scenario, sub_account);
                assert!(coin::value(&sub_account_balance) == withdrawal_amount, 3);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<Coin<USDC>>(sub_account, sub_account_balance);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
        fun should_revert_when_trying_to_withdraw_without_redeeming_shares_when_protocol_is_paused() {

                let operator = test_utils::bob();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let vault_balance = 1000000000000;
                let withdrawal_amount = 10000;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_utils::pause_non_admin_operations(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::increase_vault_balance<USDC, UltraUSDC>(&mut vault, vault_balance);

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance, 1);

                vault::withdraw_from_vault_without_redeeming_shares(&mut vault, &config, sub_account, withdrawal_amount, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance - withdrawal_amount, 2);

                test_scenario::next_tx(&mut scenario, sub_account);
                let sub_account_balance = test_scenario::take_from_address<Coin<USDC>>(&scenario, sub_account);
                assert!(coin::value(&sub_account_balance) == withdrawal_amount, 3);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<Coin<USDC>>(sub_account, sub_account_balance);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
        fun should_revert_when_non_vault_operator_tries_to_withdraw_from_vault_without_redeeming_shares() {

                let operator = test_utils::alice();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let vault_balance = 1000000000000;
                let withdrawal_amount = 10000;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::increase_vault_balance<USDC, UltraUSDC>(&mut vault, vault_balance);

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance, 1);

                vault::withdraw_from_vault_without_redeeming_shares(&mut vault, &config, sub_account, withdrawal_amount, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance - 10000, 2);

                test_scenario::next_tx(&mut scenario, sub_account);
                let sub_account_balance = test_scenario::take_from_address<Coin<USDC>>(&scenario, sub_account);
                assert!(coin::value(&sub_account_balance) == withdrawal_amount, 3);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<Coin<USDC>>(sub_account, sub_account_balance);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidAccount)]
        fun should_fail_to_withdraw_without_redeeming_shares_to_non_sub_account() {

                let operator = test_utils::bob();
                let sub_account = test_utils::alice();
                let vault_balance = 1000000000000;
                let withdrawal_amount = 10000;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::increase_vault_balance<USDC, UltraUSDC>(&mut vault, vault_balance);

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance, 1);

                vault::withdraw_from_vault_without_redeeming_shares(&mut vault, &config, sub_account, withdrawal_amount, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance - withdrawal_amount, 2);

                test_scenario::next_tx(&mut scenario, sub_account);
                let sub_account_balance = test_scenario::take_from_address<Coin<USDC>>(&scenario, sub_account);
                assert!(coin::value(&sub_account_balance) == withdrawal_amount, 3);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<Coin<USDC>>(sub_account, sub_account_balance);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInsufficientBalance)]
        fun should_fail_to_withdraw_zero_amount_from_vault_without_redeeming_shares() {

                let operator = test_utils::bob();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let vault_balance = 1000000000000;
                let withdrawal_amount = 0;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::increase_vault_balance<USDC, UltraUSDC>(&mut vault, vault_balance);

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance, 1);

                vault::withdraw_from_vault_without_redeeming_shares(&mut vault, &config, sub_account, withdrawal_amount, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance - withdrawal_amount, 2);

                test_scenario::next_tx(&mut scenario, sub_account);
                let sub_account_balance = test_scenario::take_from_address<Coin<USDC>>(&scenario, sub_account);
                assert!(coin::value(&sub_account_balance) == withdrawal_amount, 3);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<Coin<USDC>>(sub_account, sub_account_balance);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInsufficientBalance)]
        fun should_fail_to_withdraw_more_than_vault_balance_from_vault_without_redeeming_shares() {

                let operator = test_utils::bob();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let vault_balance = 1000000000000;
                let withdrawal_amount = vault_balance + 1;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::increase_vault_balance<USDC, UltraUSDC>(&mut vault, vault_balance);

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance, 1);

                vault::withdraw_from_vault_without_redeeming_shares(&mut vault, &config, sub_account, withdrawal_amount, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance - withdrawal_amount, 2);

                test_scenario::next_tx(&mut scenario, sub_account);
                let sub_account_balance = test_scenario::take_from_address<Coin<USDC>>(&scenario, sub_account);
                assert!(coin::value(&sub_account_balance) == withdrawal_amount, 3);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<Coin<USDC>>(sub_account, sub_account_balance);
                test_scenario::end(scenario);   
        }

        #[test]
        fun should_allow_vault_operator_to_withdraw_complete_vault_balance_from_vault_without_redeeming_shares() {

                let operator = test_utils::bob();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let vault_balance = 1000000000000;
                let withdrawal_amount = vault_balance;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                vault::increase_vault_balance<USDC, UltraUSDC>(&mut vault, vault_balance);

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance, 1);

                vault::withdraw_from_vault_without_redeeming_shares(&mut vault, &config, sub_account, withdrawal_amount, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == vault_balance - withdrawal_amount, 2);

                test_scenario::next_tx(&mut scenario, sub_account);
                let sub_account_balance = test_scenario::take_from_address<Coin<USDC>>(&scenario, sub_account);
                assert!(coin::value(&sub_account_balance) == withdrawal_amount, 3);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::return_to_address<Coin<USDC>>(sub_account, sub_account_balance);
                test_scenario::end(scenario);   
        }


        #[test]
        fun should_allow_vault_operator_to_deposit_to_vault_without_minting_shares() {

                let operator = test_utils::bob();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let deposit_amount = 10000;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                let deposit_balance = balance::create_for_testing<USDC>(deposit_amount);


                vault::deposit_to_vault_without_minting_shares(&mut vault, &config, deposit_balance, sub_account, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == deposit_amount, 2);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
        fun should_revert_when_trying_to_deposit_to_vault_without_minting_shares_when_protocol_is_paused() {

                let operator = test_utils::bob();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let deposit_amount = 10000;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_utils::pause_non_admin_operations(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                let deposit_balance = balance::create_for_testing<USDC>(deposit_amount);

                vault::deposit_to_vault_without_minting_shares(&mut vault, &config, deposit_balance, sub_account, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == deposit_amount, 2);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
        fun should_revert_when_non_vault_operator_tries_to_deposit_to_vault_without_minting_shares() {

                let operator = test_utils::alice();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let deposit_amount = 10000;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                let deposit_balance = balance::create_for_testing<USDC>(deposit_amount);

                vault::deposit_to_vault_without_minting_shares(&mut vault, &config, deposit_balance, sub_account, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == deposit_amount, 2);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EInvalidAccount)]
        fun should_fail_to_deposit_to_vault_without_minting_shares_from_non_sub_account() {

                let operator = test_utils::bob();
                let sub_account = test_utils::alice();
                let deposit_amount = 10000;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                let deposit_balance = balance::create_for_testing<USDC>(deposit_amount);

                vault::deposit_to_vault_without_minting_shares(&mut vault, &config, deposit_balance, sub_account, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == deposit_amount, 2);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }


        #[test]
        #[expected_failure(abort_code = ember_vaults::vault::EZeroAmount)]
        fun should_fail_to_deposit_zero_amount_to_vault_without_minting_shares() {

                let operator = test_utils::bob();
                let sub_account = test_utils::charlie(); // Use charlie instead of alice (alice is rate_manager)
                let deposit_amount = 0;

                let mut scenario = test_scenario::begin(operator);
                test_utils::initialize(&mut scenario);
                test_utils::set_sub_account(&mut scenario, sub_account);

                test_scenario::next_tx(&mut scenario, operator);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario );

                let deposit_balance = balance::create_for_testing<USDC>(deposit_amount);

                vault::deposit_to_vault_without_minting_shares(&mut vault, &config, deposit_balance, sub_account, test_scenario::ctx(&mut scenario));

                assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == deposit_amount, 2);

                test_scenario::return_shared(config);
                test_scenario::return_shared(vault);
                test_scenario::end(scenario);   
        }

         /// Test account with no pending shares returns 0
    #[test]
    fun should_return_zero_for_account_with_no_pending_shares() {
        let operator = test_utils::bob();
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, operator);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            // Test account with no pending shares should return 0
            let pending_shares = vault::get_account_total_pending_withdrawal_shares(&vault, test_utils::alice());
            assert!(pending_shares == 0, 0);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test verify_vault_not_paused function directly when vault is paused
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EVaultPaused)]
    fun should_fail_verify_vault_not_paused_when_vault_is_paused() {
        let operator = test_utils::bob();
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        
        // Pause the vault
        test_utils::pause_vault_operations(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, operator);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            // Directly call verify_vault_not_paused - this should fail
            vault::verify_vault_not_paused(&vault);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test verify_not_blacklisted function directly 
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EBlacklistedAccount)]
    fun should_fail_verify_not_blacklisted_when_account_is_blacklisted() {
        let operator = test_utils::bob();
        let blacklisted_user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        
        // Blacklist the user
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            vault::set_blacklisted_account(&mut vault, &config, blacklisted_user, true, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };
        
        // Now test verify_not_blacklisted directly
        test_scenario::next_tx(&mut scenario, operator);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            // This should fail since the user is blacklisted
            vault::verify_not_blacklisted(&vault, blacklisted_user);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test all getter functions to ensure they return correct values
    #[test]
    fun should_get_all_vault_properties() {
        let operator = test_utils::bob();
        let admin = test_utils::protocol_admin();
        
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, operator);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            // Test all getter functions
            let _vault_id = vault::get_vault_id(&vault);
            let _vault_name = vault::get_vault_name(&vault);
            let vault_admin = vault::get_vault_admin(&vault);
            let vault_operator = vault::get_vault_operator(&vault);
            let _blacklisted = vault::get_vault_blacklisted(&vault);
            let _paused = vault::get_vault_paused(&vault);
            let _pending_redemption_shares = vault::get_account_total_pending_withdrawal_shares(&vault, test_utils::alice());
            let _pending_shares_to_redeem = vault::get_pending_shares_to_redeem(&vault);
            let _sub_accounts = vault::get_vault_sub_accounts(&vault);
            let _rate = vault::get_vault_rate(&vault);
            let _balance = vault::get_vault_balance(&vault);
            let _sequence_number = vault::get_vault_sequence_number(&vault);
            let _max_rate_change = vault::get_vault_max_rate_change_per_update(&vault);
            let _fee_percentage = vault::get_vault_fee_percentage(&vault);
            let _accrued_fee = vault::get_accrued_platform_fee(&vault);
            let _last_charged_at = vault::get_last_charged_at_platform_fee(&vault);
            let _blacklisted_accounts = vault::get_vault_blacklisted_accounts(&vault);
            let _total_shares_circulation = vault::get_vault_total_shares_in_circulation(&vault);
            let _total_shares = vault::get_vault_total_shares(&vault);
            let _is_blacklisted = vault::is_blacklisted(&vault, test_utils::alice());
            let _withdrawal_queue = vault::get_withdrawal_queue(&vault);
            
            // Verify some key values
            assert!(vault_admin == admin, 0);
            assert!(vault_operator == operator, 1);
            
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test decode_withdrawal_request function
    #[test]
    fun should_decode_withdrawal_request() {
        let operator = test_utils::bob();
        let user = test_utils::alice();
        let deposit_amount = 10000000; // 10 USDC
        let redeem_amount = 5000000;   // 5 shares

        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);

        // Create a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);
        
        // Test decode function
        let (owner, receiver, shares, estimated_amount, timestamp, sequence_number) = vault::decode_withdrawal_request(&withdrawal_request);
        
        assert!(owner == user, 0);
        assert!(receiver == user, 1);
        assert!(shares == redeem_amount, 2);
        assert!(estimated_amount == redeem_amount, 3); // 1:1 ratio at default rate
        assert!(timestamp > 0, 4);
        assert!(sequence_number > 0, 5);

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test edge case: trying to add sub-account that's already blacklisted
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EBlacklistedAccount)]
    fun should_fail_to_add_blacklisted_account_as_sub_account() {
        let operator = test_utils::bob();
        let admin = test_utils::protocol_admin();
        let account = test_utils::alice();
        
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        
        // First blacklist the account
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            vault::set_blacklisted_account(&mut vault, &config, account, true, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };
        
        // Now try to add the blacklisted account as sub-account (should fail)
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            // This should fail with EBlacklistedAccount
            vault::set_sub_account(&mut vault, &config, account, true, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test edge case: trying to blacklist account that's already a sub-account
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidAccount)]
    fun should_fail_to_blacklist_sub_account() {
        let operator = test_utils::bob();
        let admin = test_utils::protocol_admin();
        let account = test_utils::alice();
        
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        
        // First add account as sub-account
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            vault::set_sub_account(&mut vault, &config, account, true, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };
        
        // Now try to blacklist the sub-account (should fail)
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            // This should fail with EInvalidAccount
            vault::set_blacklisted_account(&mut vault, &config, account, true, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test complex vault state transitions to cover edge cases
    #[test]
    fun should_handle_complex_vault_state_transitions() {
        let operator = test_utils::bob();
        let user1 = test_utils::alice();
        let user2 = @0xBEEF;
        
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        
        // Multiple deposits and redeems to create complex state
        let receipt1 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, 10000000);
        let receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user2, 5000000);
        
        // Partial redemptions
        let (remaining1, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, 3000000, user1, user1);
        let (remaining2, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, 2000000, user2, user2);
        
        // Test vault state after complex operations
        test_scenario::next_tx(&mut scenario, operator);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let pending_shares1 = vault::get_account_total_pending_withdrawal_shares(&vault, user1);
            let pending_shares2 = vault::get_account_total_pending_withdrawal_shares(&vault, user2);
            let total_pending = vault::get_pending_shares_to_redeem(&vault);
            
            // Verify state consistency
            assert!(pending_shares1 == 3000000, 0);
            assert!(pending_shares2 == 2000000, 1);
            assert!(total_pending == 5000000, 2);
            
            // Test is_blacklisted with non-blacklisted account
            assert!(!vault::is_blacklisted(&vault, user1), 3);
            
            test_scenario::return_shared(vault);
        };
        
        coin::burn_for_testing(remaining1);
        coin::burn_for_testing(remaining2);
        test_scenario::end(scenario);
    }

    /// Test vault blacklist functionality edge cases  
    #[test]
    fun should_handle_blacklist_edge_cases() {
        let operator = test_utils::bob();
        let user = test_utils::alice();
        
        let mut scenario = test_scenario::begin(operator);
        test_utils::initialize(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, operator);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            // Test blacklisting and unblacklisting same account
            vault::set_blacklisted_account(&mut vault, &config, user, true, test_scenario::ctx(&mut scenario));
            assert!(vault::is_blacklisted(&vault, user), 0);
            
            vault::set_blacklisted_account(&mut vault, &config, user, false, test_scenario::ctx(&mut scenario));
            assert!(!vault::is_blacklisted(&vault, user), 1);
            
            // Test that account is not in blacklisted list after removal
            let blacklisted = vault::get_vault_blacklisted_accounts(&vault);
            assert!(!std::vector::contains(&blacklisted, &user), 2);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test setting minimum withdrawal shares successfully
    #[test]
    fun should_set_min_withdrawal_shares() {
        let admin = test_utils::protocol_admin();
        let mut scenario = test_scenario::begin(admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            // Verify initial value
            let initial_min_shares = vault::get_vault_min_withdrawal_shares(&vault);
            assert!(initial_min_shares == 1, 0); // Default value from test_utils
            
            let new_min_withdrawal_shares = 1000000; // 1 share
            
            vault::set_min_withdrawal_shares(&mut vault, &config, new_min_withdrawal_shares, test_scenario::ctx(&mut scenario));
            
            // Verify the value was updated
            let updated_min_shares = vault::get_vault_min_withdrawal_shares(&vault);
            assert!(updated_min_shares == new_min_withdrawal_shares, 1);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidAmount)]
    fun should_fail_to_set_min_withdrawal_shares_to_same_value() {
        let admin = test_utils::protocol_admin();
        let mut scenario = test_scenario::begin(admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            let new_min_withdrawal_shares = 1; 
            
            vault::set_min_withdrawal_shares(&mut vault, &config, new_min_withdrawal_shares, test_scenario::ctx(&mut scenario));
                        
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test failure when non-admin tries to set min withdrawal shares
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun should_fail_when_non_admin_sets_min_withdrawal_shares() {
        let admin = test_utils::protocol_admin();
        let non_admin = test_utils::alice();
        let mut scenario = test_scenario::begin(admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, non_admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            let new_min_withdrawal_shares = 1000000;
            
            // This should fail since non-admin is calling
            vault::set_min_withdrawal_shares(&mut vault, &config, new_min_withdrawal_shares, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test failure when setting min withdrawal shares to zero
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EZeroAmount)]
    fun should_fail_when_setting_min_withdrawal_shares_to_zero() {
        let admin = test_utils::protocol_admin();
        let mut scenario = test_scenario::begin(admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            // This should fail with EZeroAmount
            vault::set_min_withdrawal_shares(&mut vault, &config, 0, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that redeem_shares respects minimum withdrawal shares
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInsufficientShares)]
    fun should_fail_redeem_when_shares_below_minimum() {
        let admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 10000000; // 10 USDC
        let mut scenario = test_scenario::begin(admin);
        test_utils::initialize(&mut scenario);

        // Set minimum withdrawal shares to a high value
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            vault::set_min_withdrawal_shares(&mut vault, &config, 5000000, test_scenario::ctx(&mut scenario)); // Set min to 5 shares
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // User deposits
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        
        // Try to redeem less than minimum (should fail)
        let (remaining_receipt, _withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, 1000000, user, user); // Only 1 share, below min
        
        // Clean up (though this line should never be reached due to expected failure)
        coin::burn_for_testing(remaining_receipt);

        test_scenario::end(scenario);
    }

    /// Test successful redeem when shares meet minimum requirement
    #[test]
    fun should_succeed_redeem_when_shares_meet_minimum() {
        let admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 10000000; // 10 USDC
        let mut scenario = test_scenario::begin(admin);
        test_utils::initialize(&mut scenario);

        // Set minimum withdrawal shares
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            vault::set_min_withdrawal_shares(&mut vault, &config, 2000000, test_scenario::ctx(&mut scenario)); // Set min to 2 shares
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // User deposits
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        
        // Redeem shares that meet minimum requirement (should succeed)
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, 5000000, user, user); // 5 shares, above min
        
        // Verify withdrawal request was created
        let (requester, receiver, shares, _, _, _) = vault::decode_withdrawal_request(&withdrawal_request);
        assert!(requester == user, 0);
        assert!(receiver == user, 1);
        assert!(shares == 5000000, 2);

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test min withdrawal shares value changes correctly
    #[test]
    fun should_update_min_withdrawal_shares_value() {
        let admin = test_utils::protocol_admin();
        let mut scenario = test_scenario::begin(admin);
        test_utils::initialize(&mut scenario);

        // Set initial min withdrawal shares
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            vault::set_min_withdrawal_shares(&mut vault, &config, 1000000, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Update min withdrawal shares to a different value
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            vault::set_min_withdrawal_shares(&mut vault, &config, 3000000, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Test that the new minimum is enforced
        let user = test_utils::alice();
        let deposit_amount = 10000000;
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        
        // This should succeed with 4 shares (above new min of 3)
        let (remaining_receipt, _) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, 4000000, user, user);
        
        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test failure when setting min withdrawal shares to the same value
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidAmount)]
    fun should_fail_when_setting_min_withdrawal_shares_to_same_value() {
        let admin = test_utils::protocol_admin();
        let mut scenario = test_scenario::begin(admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            
            // Get current min withdrawal shares (should be 1 from test_utils)
            let current_min_shares = vault::get_vault_min_withdrawal_shares(&vault);
            
            // Try to set the same value - this should fail with EInvalidAmount
            vault::set_min_withdrawal_shares(&mut vault, &config, current_min_shares, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Tests for change_vault_rate_update_interval ===

    /// Test successful change of vault rate update interval by admin
    #[test]
    fun should_change_vault_rate_update_interval() {
        let protocol_admin = test_utils::protocol_admin();
        let new_interval = 43200000; // 12 hours in milliseconds (within 24 hour limit)

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Get initial interval and sequence number
        let initial_interval = vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault);
        let initial_sequence = vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault);

        // Change the rate update interval
        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, new_interval, test_scenario::ctx(&mut scenario));

        // Verify the change
        assert!(vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault) == new_interval, 1);
        assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == initial_sequence + 1, 2);
        assert!(initial_interval != new_interval, 3); // Ensure we actually changed it

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when non-admin tries to change vault rate update interval  
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun should_fail_to_change_vault_rate_update_interval_when_caller_is_not_admin() {
        let protocol_admin = test_utils::protocol_admin();
        let non_admin = test_utils::alice();
        let new_interval = 172800000; // 48 hours

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Non-admin tries to change the interval
        test_scenario::next_tx(&mut scenario, non_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, new_interval, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when setting interval to zero
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidInterval)]
    fun should_fail_to_change_vault_rate_update_interval_to_zero() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Try to set interval to zero - should fail
        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, 0, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when protocol is paused
    #[test]
    #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
    fun should_fail_to_change_vault_rate_update_interval_when_protocol_is_paused() {
        let protocol_admin = test_utils::protocol_admin();
        let new_interval = 172800000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Pause the protocol
        test_utils::pause_non_admin_operations(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Try to change interval while protocol is paused - should fail
        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, new_interval, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test edge cases with different interval values
    #[test]
    fun should_handle_edge_case_interval_values() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Test minimum valid value (1 hour = 3,600,000 ms)
        let min_interval = admin::get_min_rate_interval(&config);
        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, min_interval, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault) == min_interval, 1);

        // Test maximum valid value (1 day = 86,400,000 ms)
        let max_interval = admin::get_max_rate_interval(&config);
        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, max_interval, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault) == max_interval, 2);

        // Test typical value (12 hours)
        let twelve_hours_ms = 12 * 60 * 60 * 1000;
        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, twelve_hours_ms, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault) == twelve_hours_ms, 3);

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test sequence number increments correctly when changing rate update interval
    #[test]
    fun should_increment_sequence_number_when_changing_rate_update_interval() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        let initial_sequence = vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault);

        // Change interval multiple times and verify sequence increments
        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, 3600000, test_scenario::ctx(&mut scenario)); // 1 hour
        assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == initial_sequence + 1, 1);

        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, 7200000, test_scenario::ctx(&mut scenario)); // 2 hours
        assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == initial_sequence + 2, 2);

        vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, 10800000, test_scenario::ctx(&mut scenario)); // 3 hours
        assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == initial_sequence + 3, 3);

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test that changing rate update interval allows for quicker/slower rate updates
    #[test]
    fun should_affect_rate_update_timing_validation() {
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // First change the rate update interval to a very short period
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, 3600000, test_scenario::ctx(&mut scenario)); // 1 hour (minimum valid)
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Now verify that rate updates work with the new interval
        test_utils::update_vault_rate<USDC, UltraUSDC>(&mut scenario, 1000000000, 1010000000); // First update

        // This should work since interval is 1 hour and we're simulating more than 1 hour later
        test_utils::update_vault_rate<USDC, UltraUSDC>(&mut scenario, 1000000000 + 3700000, 1020000000); // Second update 1 hour and 10 minutes later

        // Verify the rate was actually updated
        test_scenario::next_tx(&mut scenario, operator);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            assert!(vault::get_vault_rate<USDC, UltraUSDC>(&vault) == 1020000000, 1);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that admin role is properly checked for rate update interval changes
    #[test]
    fun should_only_allow_admin_to_change_rate_update_interval() {
        let protocol_admin = test_utils::protocol_admin();
        let new_interval = 7200000; // 2 hours

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Admin should be able to change it
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, new_interval, test_scenario::ctx(&mut scenario));
            assert!(vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault) == new_interval, 1);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Change operator to a new address to test permissions (bob was already the operator)
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::change_vault_operator<USDC, UltraUSDC>(&mut vault, &config, @0x123, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Now the new operator (who is operator but not admin) should not be able to change interval
        // This test case demonstrates that only admin role works, not operator role
        let new_operator_addr = @0x123;
        test_scenario::next_tx(&mut scenario, new_operator_addr);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            // This should show that operator cannot change the interval
            assert!(vault::get_vault_admin<USDC, UltraUSDC>(&vault) == protocol_admin, 2);
            assert!(vault::get_vault_operator<USDC, UltraUSDC>(&vault) == new_operator_addr, 3);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Tests for cancel_pending_withdrawal_request ===

    /// Test successful cancellation of a pending withdrawal request
    #[test]
    fun should_cancel_pending_withdrawal_request() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 10000000; // 10 USDC
        let redeem_amount = 5000000;   // 5 shares

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User deposits and creates a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);
        
        let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);

        // Verify initial state
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let pending_requests = vault::get_account_pending_withdrawal_requests(&vault, user);
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            
            assert!(vector::length(&pending_requests) == 1, 1);
            assert!(vector::length(&cancelled_requests) == 0, 2);
            
            test_scenario::return_shared(vault);
        };

        // Cancel the withdrawal request
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify cancellation state
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let pending_requests = vault::get_account_pending_withdrawal_requests(&vault, user);
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            
            assert!(vector::length(&pending_requests) == 1, 3); // Still in pending (until processed)
            assert!(vector::length(&cancelled_requests) == 1, 4); // Now in cancelled list
            assert!(*vector::borrow(&cancelled_requests, 0) == sequence_number, 5);
            
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test failure when trying to cancel already cancelled request
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidRequest)]
    fun should_fail_to_cancel_already_cancelled_withdrawal_request() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 10000000;
        let redeem_amount = 5000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User deposits and creates a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);
        
        let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);

        // Cancel the withdrawal request first time
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Try to cancel the same request again - should fail
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test failure when trying to cancel non-existent withdrawal request
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidRequest)]
    fun should_fail_to_cancel_nonexistent_withdrawal_request() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 10000000;
        let redeem_amount = 5000000;
        let fake_sequence_number = 999999u128;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User creates a real request first (so they have account state)
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, _withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);

        // Try to cancel a non-existent request - should fail
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, fake_sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test failure when protocol is paused
    #[test]
    #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
    fun should_fail_to_cancel_withdrawal_request_when_protocol_is_paused() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 10000000;
        let redeem_amount = 5000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User deposits and creates a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);
        
        let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);

        // Pause the protocol
        test_utils::pause_non_admin_operations(&mut scenario);

        // Try to cancel while protocol is paused - should fail
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test failure when vault is paused
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EVaultPaused)]
    fun should_fail_to_cancel_withdrawal_request_when_vault_is_paused() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 10000000;
        let redeem_amount = 5000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User deposits and creates a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);
        
        let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);

        // Pause the vault
        test_utils::pause_vault_operations(&mut scenario);

        // Try to cancel while vault is paused - should fail
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test failure when user has no account state (no pending requests)
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EUserDoesNotHaveAccount)]
    fun should_fail_to_cancel_when_user_has_no_pending_requests() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let fake_sequence_number = 123u128;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User tries to cancel without having any requests - should fail with EUserDoesNotHaveAccount
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, fake_sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test cancelling multiple withdrawal requests from the same user
    #[test]
    fun should_cancel_multiple_withdrawal_requests() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 20000000; // 20 USDC
        let redeem_amount1 = 3000000;  // 3 shares
        let redeem_amount2 = 4000000;  // 4 shares
        let redeem_amount3 = 5000000;  // 5 shares

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User deposits
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        // Create multiple withdrawal requests
        let (receipt1, withdrawal_request1) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount1, user, user);
        let (receipt2, withdrawal_request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, redeem_amount2, user, user);
        let (remaining_receipt, withdrawal_request3) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, redeem_amount3, user, user);
        
        let sequence_number1 = vault::get_withdrawal_receipt_nonce(&withdrawal_request1);
        let sequence_number2 = vault::get_withdrawal_receipt_nonce(&withdrawal_request2);
        let sequence_number3 = vault::get_withdrawal_receipt_nonce(&withdrawal_request3);

        // Verify initial state - 3 pending requests
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let pending_requests = vault::get_account_pending_withdrawal_requests(&vault, user);
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            
            assert!(vector::length(&pending_requests) == 3, 1);
            assert!(vector::length(&cancelled_requests) == 0, 2);
            
            test_scenario::return_shared(vault);
        };

        // Cancel first and third requests
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number1, test_scenario::ctx(&mut scenario));
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number3, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify cancellation state
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let pending_requests = vault::get_account_pending_withdrawal_requests(&vault, user);
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            
            assert!(vector::length(&pending_requests) == 3, 3); // Still 3 pending (until processed)
            assert!(vector::length(&cancelled_requests) == 2, 4); // 2 cancelled
            
            // Verify the correct sequence numbers are cancelled
            assert!(vector::contains(&cancelled_requests, &sequence_number1), 5);
            assert!(vector::contains(&cancelled_requests, &sequence_number3), 6);
            assert!(!vector::contains(&cancelled_requests, &sequence_number2), 7);
            
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test that cancelled requests are properly skipped during processing
    #[test]
    fun should_skip_cancelled_requests_during_processing() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 15000000;
        let redeem_amount1 = 5000000;
        let redeem_amount2 = 6000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User deposits
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        // Create two withdrawal requests
        let (receipt1, withdrawal_request1) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount1, user, user);
        let (remaining_receipt, _withdrawal_request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, redeem_amount2, user, user);
        
        let sequence_number1 = vault::get_withdrawal_receipt_nonce(&withdrawal_request1);

        // Cancel the first request
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number1, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify user has pending shares before processing
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let total_pending_shares = vault::get_account_total_pending_withdrawal_shares(&vault, user);
            assert!(total_pending_shares == redeem_amount1 + redeem_amount2, 1);
            
            test_scenario::return_shared(vault);
        };

        // Process requests - cancelled request should be skipped and shares returned
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 2);

        // Verify that cancelled request was skipped and shares returned to user
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            // User should have no more pending requests after processing
            let total_pending_shares = vault::get_account_total_pending_withdrawal_shares(&vault, user);
            assert!(total_pending_shares == 0, 2);
            
            test_scenario::return_shared(vault);
        };

        // Check if user received back shares from cancelled request
        test_scenario::next_tx(&mut scenario, user);
        {
            let user_receipts = test_scenario::take_from_address<Coin<UltraUSDC>>(&scenario, user);
            // User should have received back the cancelled shares
            assert!(coin::value(&user_receipts) == redeem_amount1, 3);
            test_scenario::return_to_address<Coin<UltraUSDC>>(user, user_receipts);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test cancellation state verification through getter functions
    #[test]
    fun should_verify_cancellation_state_through_getters() {
        let protocol_admin = test_utils::protocol_admin();
        let user1 = test_utils::alice();
        let user2 = test_utils::bob();
        let deposit_amount = 10000000;
        let redeem_amount = 5000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Both users create withdrawal requests
        let receipt1 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, deposit_amount);
        let (remaining_receipt1, withdrawal_request1) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, redeem_amount, user1, user1);
        
        let receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user2, deposit_amount);
        let (remaining_receipt2, _withdrawal_request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, redeem_amount, user2, user2);
        
        let sequence_number1 = vault::get_withdrawal_receipt_nonce(&withdrawal_request1);

        // Only user1 cancels their request
        test_scenario::next_tx(&mut scenario, user1);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number1, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify state using getter functions
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            // User1 should have 1 cancelled request
            let user1_cancelled = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user1);
            assert!(vector::length(&user1_cancelled) == 1, 1);
            assert!(*vector::borrow(&user1_cancelled, 0) == sequence_number1, 2);
            
            // User2 should have no cancelled requests
            let user2_cancelled = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user2);
            assert!(vector::length(&user2_cancelled) == 0, 3);
            
            // Both users should still have pending requests (until processed)
            let user1_pending = vault::get_account_pending_withdrawal_requests(&vault, user1);
            let user2_pending = vault::get_account_pending_withdrawal_requests(&vault, user2);
            assert!(vector::length(&user1_pending) == 1, 4);
            assert!(vector::length(&user2_pending) == 1, 5);
            
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt1);
        coin::burn_for_testing(remaining_receipt2);
        test_scenario::end(scenario);
    }

    /// Test that cancellation works correctly with sequence number ordering
    #[test]
    fun should_handle_cancellation_with_sequence_number_ordering() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 30000000;
        let redeem_amount = 5000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User deposits
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);

        // Create 4 withdrawal requests to test ordering
        let (receipt1, request1) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);
        let (receipt2, request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, redeem_amount, user, user);
        let (receipt3, request3) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, redeem_amount, user, user);
        let (remaining_receipt, request4) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt3, redeem_amount, user, user);
        
        let seq1 = vault::get_withdrawal_receipt_nonce(&request1);
        let seq2 = vault::get_withdrawal_receipt_nonce(&request2);
        let seq3 = vault::get_withdrawal_receipt_nonce(&request3);
        let seq4 = vault::get_withdrawal_receipt_nonce(&request4);

        // Cancel requests in non-sequential order (3rd, 1st, 4th)
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, seq3, test_scenario::ctx(&mut scenario));
            vault::cancel_pending_withdrawal_request(&mut vault, &config, seq1, test_scenario::ctx(&mut scenario));
            vault::cancel_pending_withdrawal_request(&mut vault, &config, seq4, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify cancellation state
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            assert!(vector::length(&cancelled_requests) == 3, 1);
            
            // All cancelled sequence numbers should be present
            assert!(vector::contains(&cancelled_requests, &seq1), 2);
            assert!(vector::contains(&cancelled_requests, &seq3), 3);
            assert!(vector::contains(&cancelled_requests, &seq4), 4);
            assert!(!vector::contains(&cancelled_requests, &seq2), 5); // seq2 not cancelled
            
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test that only the request owner can cancel their own requests
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EUserDoesNotHaveAccount)]
    fun should_fail_when_wrong_user_tries_to_cancel_request() {
        let protocol_admin = test_utils::protocol_admin();
        let user1 = test_utils::alice();
        let user2 = test_utils::bob();
        let deposit_amount = 10000000;
        let redeem_amount = 5000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User1 creates a withdrawal request
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, deposit_amount);
        let (remaining_receipt, withdrawal_request) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user1, user1);
        
        let sequence_number = vault::get_withdrawal_receipt_nonce(&withdrawal_request);

        // User2 tries to cancel User1's request - should fail with EUserDoesNotHaveAccount
        test_scenario::next_tx(&mut scenario, user2);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    /// Test that user with account cannot cancel another user's request
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidRequest)]
    fun should_fail_when_user_tries_to_cancel_another_users_request() {
        let protocol_admin = test_utils::protocol_admin();
        let user1 = test_utils::alice();
        let user2 = test_utils::bob();
        let deposit_amount = 10000000;
        let redeem_amount = 5000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Both users create withdrawal requests
        let receipt1 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user1, deposit_amount);
        let (remaining_receipt1, withdrawal_request1) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, redeem_amount, user1, user1);
        
        let receipt2 = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user2, deposit_amount);
        let (remaining_receipt2, _withdrawal_request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, redeem_amount, user2, user2);
        
        let sequence_number1 = vault::get_withdrawal_receipt_nonce(&withdrawal_request1);

        // User2 (who has account) tries to cancel User1's request - should fail with EInvalidRequest
        test_scenario::next_tx(&mut scenario, user2);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, sequence_number1, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt1);
        coin::burn_for_testing(remaining_receipt2);
        test_scenario::end(scenario);
    }

    /// Test cancellation with mixed processed and unprocessed requests
    #[test]
    fun should_handle_cancellation_with_mixed_request_states() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();
        let deposit_amount = 20000000;
        let redeem_amount = 5000000;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // User deposits and creates 3 withdrawal requests
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, deposit_amount);
        let (receipt1, request1) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt, redeem_amount, user, user);
        let (receipt2, request2) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt1, redeem_amount, user, user);
        let (remaining_receipt, request3) = test_utils::redeem_shares<USDC, UltraUSDC>(&mut scenario, receipt2, redeem_amount, user, user);
        
        let _seq1 = vault::get_withdrawal_receipt_nonce(&request1);
        let seq2 = vault::get_withdrawal_receipt_nonce(&request2);
        let seq3 = vault::get_withdrawal_receipt_nonce(&request3);

        // Cancel the second request before processing
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, seq2, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Process the first request (which is not cancelled)
        test_utils::process_withdrawal_request<USDC, UltraUSDC>(&mut scenario, 1);

        // Cancel the third request after first one is processed
        test_scenario::next_tx(&mut scenario, user);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::cancel_pending_withdrawal_request(&mut vault, &config, seq3, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Verify final state
        test_scenario::next_tx(&mut scenario, user);
        {
            let vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            let pending_requests = vault::get_account_pending_withdrawal_requests(&vault, user);
            let cancelled_requests = vault::get_account_cancelled_withdraw_request_sequencer_numbers(&vault, user);
            
            // Should have 2 pending requests remaining (seq2 cancelled but not processed yet, seq3 just cancelled)
            assert!(vector::length(&pending_requests) == 2, 1);
            
            // Should have 2 cancelled requests
            assert!(vector::length(&cancelled_requests) == 2, 2);
            assert!(vector::contains(&cancelled_requests, &seq2), 3);
            assert!(vector::contains(&cancelled_requests, &seq3), 4);
            
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(remaining_receipt);
        test_scenario::end(scenario);
    }

    // === Tests for ESameValue Error ===

    /// Test that update_vault_rate fails when trying to set the same rate value
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::ESameValue)]
    fun should_fail_when_updating_vault_rate_to_same_value() {
        let protocol_admin = test_utils::protocol_admin();
        let rate_manager = test_utils::alice();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, rate_manager);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000000000);

            // Get the current rate
            let current_rate = vault::get_vault_rate<USDC, UltraUSDC>(&vault);

            // Try to set the same rate - this should fail with ESameValue
            vault::update_vault_rate<USDC, UltraUSDC>(&mut vault, &config, current_rate, &clock, test_scenario::ctx(&mut scenario));

            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that change_vault_rate_update_interval fails when trying to set the same interval value
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::ESameValue)]
    fun should_fail_when_changing_vault_rate_update_interval_to_same_value() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Get the current rate update interval
            let current_interval = vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault);

            // Try to set the same interval - this should fail with ESameValue
            vault::change_vault_rate_update_interval<USDC, UltraUSDC>(&mut vault, &config, current_interval, test_scenario::ctx(&mut scenario));

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that update_vault_fee_percentage fails when trying to set the same fee percentage value
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::ESameValue)]
    fun should_fail_when_updating_vault_fee_percentage_to_same_value() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 10000000000);

            // Get the current fee percentage
            let current_fee_percentage = vault::get_vault_fee_percentage<USDC, UltraUSDC>(&vault);

            // Try to set the same fee percentage - this should fail with ESameValue
            vault::update_vault_fee_percentage_v2<USDC, UltraUSDC>(&mut vault, &config, current_fee_percentage, &clock, test_scenario::ctx(&mut scenario));

            clock::destroy_for_testing(clock);
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Tests for update_vault_max_tvl ===

    /// Test that update_vault_max_tvl succeeds when called by vault admin with valid parameters
    #[test]
    fun should_successfully_update_vault_max_tvl() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Get the current max_tvl and sequence number
            let current_max_tvl = vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault);
            let current_sequence_number = vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault);

            // Update max_tvl to a new value
            let new_max_tvl = 2000000000000; // 2000 USDC (in e9 format)
            vault::update_vault_max_tvl<USDC, UltraUSDC>(&mut vault, &config, new_max_tvl, test_scenario::ctx(&mut scenario));

            // Verify the max_tvl was updated
            assert!(vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault) == new_max_tvl, 0);
            assert!(vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault) != current_max_tvl, 1);

            // Verify sequence number was incremented
            assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == current_sequence_number + 1, 2);

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that update_vault_max_tvl fails when called by non-admin user
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun should_fail_when_non_admin_tries_to_update_vault_max_tvl() {
        let protocol_admin = test_utils::protocol_admin();
        let non_admin = test_utils::alice();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, non_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Try to update max_tvl as non-admin - this should fail with EInvalidPermission
            let new_max_tvl = 2000000000000; // 2000 USDC (in e9 format)
            vault::update_vault_max_tvl<USDC, UltraUSDC>(&mut vault, &config, new_max_tvl, test_scenario::ctx(&mut scenario));

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that update_vault_max_tvl fails when trying to set max_tvl to zero
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidAmount)]
    fun should_fail_when_trying_to_set_max_tvl_to_zero() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Try to set max_tvl to zero - this should fail with EInvalidAmount
            vault::update_vault_max_tvl<USDC, UltraUSDC>(&mut vault, &config, 0, test_scenario::ctx(&mut scenario));

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that update_vault_max_tvl fails when trying to set the same max_tvl value
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::ESameValue)]
    fun should_fail_when_trying_to_set_max_tvl_to_same_value() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Get the current max_tvl
            let current_max_tvl = vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault);

            // Try to set the same max_tvl - this should fail with ESameValue
            vault::update_vault_max_tvl<USDC, UltraUSDC>(&mut vault, &config, current_max_tvl, test_scenario::ctx(&mut scenario));

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that update_vault_max_tvl fails when trying to set max_tvl below current TVL
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EMaxTVLReached)]
    fun should_fail_when_trying_to_set_max_tvl_below_current_tvl() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // First, deposit some assets to create a current TVL
        test_scenario::next_tx(&mut scenario, user);
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, 500000000000); // 500 USDC
        
        // Now try to set max_tvl below the current TVL
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Current TVL is 500 USDC, try to set max_tvl to 400 USDC - this should fail
            let new_max_tvl = 400000000000; // 400 USDC (in e9 format)
            vault::update_vault_max_tvl<USDC, UltraUSDC>(&mut vault, &config, new_max_tvl, test_scenario::ctx(&mut scenario));

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);
    }

    /// Test that update_vault_max_tvl succeeds when setting max_tvl above current TVL
    #[test]
    fun should_succeed_when_setting_max_tvl_above_current_tvl() {
        let protocol_admin = test_utils::protocol_admin();
        let user = test_utils::alice();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // First, deposit some assets to create a current TVL
        test_scenario::next_tx(&mut scenario, user);
        let receipt = test_utils::deposit_assets<USDC, UltraUSDC>(&mut scenario, user, 500000000000); // 500 USDC
        
        // Now set max_tvl above the current TVL
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Current TVL is 500 USDC, set max_tvl to 800 USDC - this should succeed
            let new_max_tvl = 800000000000; // 800 USDC (in e9 format)
            let current_sequence_number = vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault);
            
            vault::update_vault_max_tvl<USDC, UltraUSDC>(&mut vault, &config, new_max_tvl, test_scenario::ctx(&mut scenario));

            // Verify the max_tvl was updated
            assert!(vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault) == new_max_tvl, 0);

            // Verify sequence number was incremented
            assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == current_sequence_number + 1, 1);

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        coin::burn_for_testing(receipt);
        test_scenario::end(scenario);
    }



    /// Test that update_vault_max_tvl works correctly with edge case values
    #[test]
    fun should_handle_edge_case_max_tvl_values() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Test with very large max_tvl value
            let very_large_max_tvl = 1000000000000000000; // 1,000,000,000 USDC (in e9 format)
            let current_sequence_number = vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault);
            
            vault::update_vault_max_tvl<USDC, UltraUSDC>(&mut vault, &config, very_large_max_tvl, test_scenario::ctx(&mut scenario));

            // Verify the max_tvl was updated
            assert!(vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault) == very_large_max_tvl, 0);

            // Verify sequence number was incremented
            assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == current_sequence_number + 1, 1);

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test that update_vault_max_tvl correctly emits events
    #[test]
    fun should_emit_correct_events_when_updating_max_tvl() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

            // Get the current max_tvl and sequence number
            let current_max_tvl = vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault);
            let current_sequence_number = vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault);

            // Update max_tvl to a new value
            let new_max_tvl = 1500000000000; // 1500 USDC (in e9 format)
            vault::update_vault_max_tvl<USDC, UltraUSDC>(&mut vault, &config, new_max_tvl, test_scenario::ctx(&mut scenario));

            // Verify the max_tvl was updated
            assert!(vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault) == new_max_tvl, 0);
            assert!(vault::get_vault_max_tvl<USDC, UltraUSDC>(&vault) != current_max_tvl, 1);

            // Verify sequence number was incremented
            assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == current_sequence_number + 1, 2);

            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    // === Tests for update_max_rate_change_per_update ===

    /// Test successful update of max_rate_change_per_update by admin
    #[test]
    fun should_update_max_rate_change_per_update() {
        let protocol_admin = test_utils::protocol_admin();
        let new_max_rate_change = 500000000; // 50%

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Get initial values
        let initial_max_rate_change = vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault);
        let initial_sequence = vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault);

        // Update the max rate change per update
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, new_max_rate_change, test_scenario::ctx(&mut scenario));

        // Verify the change
        assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == new_max_rate_change, 1);
        assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == initial_sequence + 1, 2);
        assert!(initial_max_rate_change != new_max_rate_change, 3); // Ensure we actually changed it

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when non-admin tries to update max_rate_change_per_update
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun should_fail_to_update_max_rate_change_per_update_when_caller_is_not_admin() {
        let protocol_admin = test_utils::protocol_admin();
        let non_admin = test_utils::alice();
        let new_max_rate_change = 500000000; // 50%

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Non-admin tries to update
        test_scenario::next_tx(&mut scenario, non_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, new_max_rate_change, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when operator tries to update max_rate_change_per_update (only admin allowed)
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun should_fail_to_update_max_rate_change_per_update_when_caller_is_operator() {
        let protocol_admin = test_utils::protocol_admin();
        let operator = test_utils::bob(); // Bob is the operator in test_utils::initialize()
        let new_max_rate_change = 500000000; // 50%

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Operator tries to update (should fail)
        test_scenario::next_tx(&mut scenario, operator);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, new_max_rate_change, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when setting max_rate_change_per_update to zero
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidAmount)]
    fun should_fail_to_update_max_rate_change_per_update_to_zero() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Try to set to zero - should fail
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 0, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when setting max_rate_change_per_update to 100% (1000000000) or above
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidAmount)]
    fun should_fail_to_update_max_rate_change_per_update_to_100_percent() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Try to set to 100% (1000000000) - should fail
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 1000000000, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when setting max_rate_change_per_update above 100%
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidAmount)]
    fun should_fail_to_update_max_rate_change_per_update_above_100_percent() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Try to set to above 100% - should fail
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 2000000000, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when setting max_rate_change_per_update to the same value
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidAmount)]
    fun should_fail_to_update_max_rate_change_per_update_to_same_value() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Get current value
        let current_value = vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault);

        // Try to set to same value - should fail
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, current_value, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test failure when protocol is paused
    #[test]
    #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
    fun should_fail_to_update_max_rate_change_per_update_when_protocol_is_paused() {
        let protocol_admin = test_utils::protocol_admin();
        let new_max_rate_change = 500000000; // 50%

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Pause the protocol
        test_utils::pause_non_admin_operations(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Try to update while protocol is paused - should fail
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, new_max_rate_change, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test edge cases with different valid values
    #[test]
    fun should_handle_edge_case_max_rate_change_values() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Test minimum valid value (1 = 0.0000001%)
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 1, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 1, 1);

        // Test a small percentage (0.01% = 100000)
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 100000, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 100000, 2);

        // Test 1% (10000000)
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 10000000, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 10000000, 3);

        // Test 10% (100000000)
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 100000000, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 100000000, 4);

        // Test 50% (500000000)
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 500000000, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 500000000, 5);

        // Test maximum valid value (just under 100% = 999999999)
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 999999999, test_scenario::ctx(&mut scenario));
        assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 999999999, 6);

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test sequence number increments correctly when updating max_rate_change_per_update
    #[test]
    fun should_increment_sequence_number_when_updating_max_rate_change_per_update() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        let initial_sequence = vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault);

        // Update multiple times and verify sequence increments
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 100000000, test_scenario::ctx(&mut scenario)); // 10%
        assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == initial_sequence + 1, 1);

        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 200000000, test_scenario::ctx(&mut scenario)); // 20%
        assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == initial_sequence + 2, 2);

        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 300000000, test_scenario::ctx(&mut scenario)); // 30%
        assert!(vault::get_vault_sequence_number<USDC, UltraUSDC>(&vault) == initial_sequence + 3, 3);

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test that max_rate_change_per_update affects rate update validation
    #[test]
    fun should_affect_rate_update_validation_after_updating_max_rate_change() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // First, set a small max_rate_change_per_update (1%)
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 10000000, test_scenario::ctx(&mut scenario)); // 1%
            assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 10000000, 1);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        // Now increase it to 50%
        test_scenario::next_tx(&mut scenario, protocol_admin);
        {
            let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
            let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);
            
            vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 500000000, test_scenario::ctx(&mut scenario)); // 50%
            assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 500000000, 2);
            
            test_scenario::return_shared(config);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Test multiple consecutive updates with different valid values
    #[test]
    fun should_allow_multiple_consecutive_updates_to_max_rate_change_per_update() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Perform many updates
        let values = vector[10000000u64, 50000000, 100000000, 250000000, 500000000, 750000000, 999999999, 1, 100];
        let mut i = 0;
        while (i < vector::length(&values)) {
            let value = *vector::borrow(&values, i);
            vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, value, test_scenario::ctx(&mut scenario));
            assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == value, i);
            i = i + 1;
        };

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test that only the admin can update, not any random user
    #[test]
    #[expected_failure(abort_code = ember_vaults::vault::EInvalidPermission)]
    fun should_fail_to_update_max_rate_change_per_update_when_caller_is_random_user() {
        let protocol_admin = test_utils::protocol_admin();
        let random_user = @0x9999;

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        // Random user tries to update
        test_scenario::next_tx(&mut scenario, random_user);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 500000000, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }

    /// Test preserving other vault state when updating max_rate_change_per_update
    #[test]
    fun should_preserve_other_vault_state_when_updating_max_rate_change_per_update() {
        let protocol_admin = test_utils::protocol_admin();

        let mut scenario = test_scenario::begin(protocol_admin);
        test_utils::initialize(&mut scenario);

        test_scenario::next_tx(&mut scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC, UltraUSDC>>(&scenario);

        // Record state before update
        let admin_before = vault::get_vault_admin<USDC, UltraUSDC>(&vault);
        let operator_before = vault::get_vault_operator<USDC, UltraUSDC>(&vault);
        let rate_before = vault::get_vault_rate<USDC, UltraUSDC>(&vault);
        let paused_before = vault::get_vault_paused<USDC, UltraUSDC>(&vault);
        let balance_before = vault::get_vault_balance<USDC, UltraUSDC>(&vault);
        let rate_interval_before = vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault);

        // Update max_rate_change_per_update
        vault::update_vault_max_rate_change_per_update<USDC, UltraUSDC>(&mut vault, &config, 500000000, test_scenario::ctx(&mut scenario));

        // Verify other state is preserved
        assert!(vault::get_vault_admin<USDC, UltraUSDC>(&vault) == admin_before, 1);
        assert!(vault::get_vault_operator<USDC, UltraUSDC>(&vault) == operator_before, 2);
        assert!(vault::get_vault_rate<USDC, UltraUSDC>(&vault) == rate_before, 3);
        assert!(vault::get_vault_paused<USDC, UltraUSDC>(&vault) == paused_before, 4);
        assert!(vault::get_vault_balance<USDC, UltraUSDC>(&vault) == balance_before, 5);
        assert!(vault::get_vault_rate_update_interval<USDC, UltraUSDC>(&vault) == rate_interval_before, 6);

        // Verify max_rate_change_per_update was updated
        assert!(vault::get_vault_max_rate_change_per_update<USDC, UltraUSDC>(&vault) == 500000000, 7);

        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
        test_scenario::end(scenario);
    }
}