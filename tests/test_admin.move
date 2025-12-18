#[test_only]
module ember_vaults::tests_admin {
        use sui::test_scenario;
        use ember_vaults::admin::{Self, AdminCap, ProtocolConfig  };      
        use ember_vaults::test_utils;

        #[test]
        fun should_succeed_when_initializing_module() {
                let mut scenario = test_scenario::begin(test_utils::protocol_admin());
                admin::initialize_module(test_scenario::ctx(&mut scenario));        
                test_scenario::end(scenario);
        }


        #[test]
        fun should_succeed_when_transferring_admin_capability() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);        
                transfer::public_transfer(cap, test_utils::bob());
 
                test_scenario::end(scenario);
        }


        #[test]
        fun should_succeed_when_pausing_non_admin_operations() {
                let protocol_admin = test_utils::protocol_admin();
                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::pause_non_admin_operations(&mut config, &cap, true);

                assert!(admin::get_protocol_pause_status(&config), 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EPackageAlreadySupported)]
        fun should_fail_when_increasing_supported_package_version() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::increase_supported_package_version(&mut config, &cap);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);
        }

        #[test]
        fun should_succeed_when_increasing_supported_package_version() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);

                admin::increase_supported_package_version_for_testing(&mut config);

                test_scenario::return_shared(config);

                test_scenario::end(scenario);
        }

        #[test]
        fun should_pass_when_verifying_supported_package() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);

                admin::verify_supported_package(&config);

                test_scenario::return_shared(config);

                test_scenario::end(scenario);
        }

        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EUnsupportedPackage)]
        fun should_fail_when_verifying_supported_package() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);

                admin::increase_supported_package_version_for_testing(&mut config);

                admin::verify_supported_package(&config);

                test_scenario::return_shared(config);

                test_scenario::end(scenario);
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EInvalidRecipient)]
        fun should_fail_when_making_zero_address_platform_fee_recipient() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_platform_fee_recipient(&mut config, &cap, @0x0);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        fun should_succeed_when_updating_platform_fee_recipient() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_platform_fee_recipient(&mut config, &cap, test_utils::bob());

                assert!(admin::get_platform_fee_recipient(&config) == test_utils::bob(), 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        fun should_succeed_when_updating_min_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_min_rate(&mut config, &cap, 1000000000);

                assert!(admin::get_min_rate(&config) == 1000000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        fun should_succeed_when_updating_max_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_max_rate(&mut config, &cap, 1000000000);

                assert!(admin::get_max_rate(&config) == 1000000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        fun should_succeed_when_updating_default_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_default_rate(&mut config, &cap, 1500000000);

                assert!(admin::get_default_rate(&config) == 1500000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EInvalidRate)]
        fun should_fail_when_updating_min_rate_to_greater_than_max_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_min_rate(&mut config, &cap, 100000000000);

                assert!(admin::get_min_rate(&config) == 100000000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EInvalidRate)]
        fun should_fail_when_updating_min_rate_to_greater_than_default_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_min_rate(&mut config, &cap, 2000000000);

                assert!(admin::get_min_rate(&config) == 2000000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EInvalidRate)]
        fun should_fail_when_updating_max_rate_to_less_than_min_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_max_rate(&mut config, &cap, 100000);

                assert!(admin::get_max_rate(&config) == 100000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EInvalidRate)]
        fun should_fail_when_updating_max_rate_to_less_than_default_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_max_rate(&mut config, &cap, 900000000);

                assert!(admin::get_max_rate(&config) == 900000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EInvalidRate)]
        fun should_fail_when_updating_default_rate_to_less_than_min_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_default_rate(&mut config, &cap, 200000000);

                assert!(admin::get_default_rate(&config) == 200000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EInvalidRate)]
        fun should_fail_when_updating_default_rate_to_greater_than_max_rate() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_default_rate(&mut config, &cap, 60000000000);

                assert!(admin::get_default_rate(&config) == 60000000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        fun should_succeed_when_updating_max_allowed_fee_percentage() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_max_fee_percentage(&mut config, &cap, 200000000);

                assert!(admin::get_max_allowed_fee_percentage(&config) == 200000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }


        #[test]
        #[expected_failure(abort_code=ember_vaults::admin::EInvalidFeePercentage)]
        fun should_fail_when_updating_max_allowed_fee_percentage_to_greater_than_equal_to_100_percent() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_max_fee_percentage(&mut config, &cap, 1000000000);

                assert!(admin::get_max_allowed_fee_percentage(&config) == 1000000000, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EProtocolPaused)]
        fun should_fail_when_protocol_is_paused() {
                let protocol_admin = test_utils::protocol_admin();
                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                // First pause the protocol
                admin::pause_non_admin_operations(&mut config, &cap, true);
                
                // Now try to verify protocol is not paused - this should fail
                admin::verify_protocol_not_paused(&config);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);
                test_scenario::end(scenario);           
        }

        #[test]  
        #[expected_failure(abort_code = ember_vaults::admin::EInvalidRate)]
        fun should_fail_when_updating_min_rate_to_zero() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                admin::update_min_rate(&mut config, &cap, 0);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        // === Tests for Rate Interval Functions ===

        #[test]
        fun should_succeed_when_updating_min_rate_interval() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                let new_min_interval = 2 * 60 * 60 * 1000; // 2 hours in milliseconds
                admin::update_min_rate_interval(&mut config, &cap, new_min_interval);

                assert!(admin::get_min_rate_interval(&config) == new_min_interval, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        fun should_succeed_when_updating_max_rate_interval() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                let new_max_interval = 12 * 60 * 60 * 1000; // 12 hours in milliseconds (must be <= 24 hours)
                admin::update_max_rate_interval(&mut config, &cap, new_max_interval);

                assert!(admin::get_max_rate_interval(&config) == new_max_interval, 1);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EInvalidRateInterval)]
        fun should_fail_when_updating_min_rate_interval_below_one_minute() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                let invalid_interval = 30 * 1000; // 30 seconds (below 1 minute minimum)
                admin::update_min_rate_interval(&mut config, &cap, invalid_interval);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EInvalidRateInterval)]
        fun should_fail_when_updating_min_rate_interval_above_max_rate_interval() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                // Try to set min interval greater than max interval (default max is 24 hours)
                let invalid_interval = 48 * 60 * 60 * 1000; // 48 hours (above default 24 hour max)
                admin::update_min_rate_interval(&mut config, &cap, invalid_interval);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        #[expected_failure(abort_code = ember_vaults::admin::EInvalidRateInterval)]
        fun should_fail_when_updating_max_rate_interval_below_min_rate_interval() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                // Try to set max interval less than min interval (default min is 1 hour)
                let invalid_interval = 30 * 60 * 1000; // 30 minutes (below default 1 hour min)
                admin::update_max_rate_interval(&mut config, &cap, invalid_interval);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }

        #[test]
        fun should_correctly_get_rate_interval_values() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let config = test_scenario::take_shared<ProtocolConfig>(&scenario);

                // Verify default values
                let default_min_interval = 60 * 60 * 1000; // 1 hour
                let default_max_interval = 24 * 60 * 60 * 1000; // 24 hours
                
                assert!(admin::get_min_rate_interval(&config) == default_min_interval, 1);
                assert!(admin::get_max_rate_interval(&config) == default_max_interval, 2);

                test_scenario::return_shared(config);
                test_scenario::end(scenario);           
        }

        #[test]
        fun should_update_both_intervals_correctly() {
                let protocol_admin = test_utils::protocol_admin();

                let mut scenario = test_scenario::begin(protocol_admin);
                admin::initialize_module(test_scenario::ctx(&mut scenario));       

                test_scenario::next_tx(&mut scenario, protocol_admin);
                let mut config = test_scenario::take_shared<ProtocolConfig>(&scenario);
                let cap = test_scenario::take_from_address<AdminCap>(&scenario, protocol_admin);

                // First update max to allow for a larger min
                let new_max_interval = 12 * 60 * 60 * 1000; // 12 hours
                admin::update_max_rate_interval(&mut config, &cap, new_max_interval);
                
                // Then update min within the new max
                let new_min_interval = 4 * 60 * 60 * 1000; // 4 hours
                admin::update_min_rate_interval(&mut config, &cap, new_min_interval);

                assert!(admin::get_min_rate_interval(&config) == new_min_interval, 1);
                assert!(admin::get_max_rate_interval(&config) == new_max_interval, 2);

                test_scenario::return_shared(config);
                test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

                test_scenario::end(scenario);           
        }
}