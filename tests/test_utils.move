#[test_only]
module ember_vaults::test_utils {

    // === Imports ===
    use sui::test_scenario::{Self, Scenario};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self};
    use ember_vaults::vault::{Self};
    use ember_vaults::admin::{Self, AdminCap, ProtocolConfig};
    use ember_vaults::vault::Vault;
    use sui::coin::TreasuryCap;
    use ember_vaults::vault::WithdrawalRequest;
    use sui::clock::{Self};

    // === Constants ===

    const PROTOCOL_ADMIN: address = @0xABC;
    const BOB: address = @0xB1;
    const ALICE: address = @0xA1;
    const CHARLIE: address = @0xC1; // Additional test address for sub_account tests
    const MAX_U64: u64 = 18446744073709551615;


    // === Structs ===
    public struct USDC {}
    public struct USDT {}
    public struct SUI {}

    public struct UltraUSDC {}
    public struct UltraUSDT {}
    public struct UltraSUI {}

    // @dev protocol admin is also the vault admin in all tests
    public fun protocol_admin(): address {
        PROTOCOL_ADMIN
    }

    public fun bob(): address {
        BOB
    }

    public fun alice(): address {
        ALICE
    }

    public fun charlie(): address {
        CHARLIE
    }


    public fun initialize(scenario: &mut Scenario){

        let protocol_admin = protocol_admin();

        test_scenario::next_tx(scenario, protocol_admin);
        admin::initialize_module(test_scenario::ctx(scenario));       
        let receipt_token_treasury_cap = coin::create_treasury_cap_for_testing<UltraUSDC>(test_scenario::ctx(scenario));
        
        create_vault<USDC,UltraUSDC>(scenario, receipt_token_treasury_cap);

    }


    public fun create_vault<T,R>(scenario: &mut Scenario, receipt_token_treasury_cap: TreasuryCap<R>) {

        let protocol_admin = protocol_admin();

        test_scenario::next_tx(scenario, protocol_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        let cap = test_scenario::take_from_address<AdminCap>(scenario, protocol_admin);
    
        let mut vault = vault::create_vault<T, R>(
            &config, 
            receipt_token_treasury_cap,
            &cap, 
            b"Sample Vault".to_string(), 
            protocol_admin, bob(), 
            50000000, // max allowed change in vault rate 5%
            1000000, //fee 0.01%    
            1, // min withdrawal shares
            86400000, // rate update interval
            1000000000000, // max_tvl: 1000 USDC (in e9 format)
            vector::empty(), 
            test_scenario::ctx(scenario));


        vault::update_vault_rate_manager<T,R>(&mut vault, &config,  alice(), test_scenario::ctx(scenario));


        vault::share_vault(vault);        
        test_scenario::return_shared(config);
        test_scenario::return_to_address<AdminCap>(protocol_admin, cap);

    }

    public fun set_sub_account(scenario: &mut Scenario, sub_account: address) {
        let vault_admin = protocol_admin();
        test_scenario::next_tx(scenario, vault_admin);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(scenario);
        vault::set_sub_account(&mut vault, &config, sub_account, true, test_scenario::ctx(scenario));
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
    }


    public fun pause_non_admin_operations(scenario: &mut Scenario) {
        let protocol_admin = protocol_admin();
        test_scenario::next_tx(scenario, protocol_admin);
        let mut config = test_scenario::take_shared<ProtocolConfig>(scenario);
        let cap = test_scenario::take_from_address<AdminCap>(scenario, protocol_admin);
        admin::pause_non_admin_operations(&mut config, &cap, true);
        test_scenario::return_shared(config);
        test_scenario::return_to_address<AdminCap>(protocol_admin, cap);
    }

    public fun pause_vault_operations(scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, protocol_admin());
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        vault::set_vault_paused_status(&mut vault, &config, true, test_scenario::ctx(scenario));
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
    }

    public fun black_list_address(scenario: &mut Scenario, address: address, status: bool) {
        let operator = bob();
        test_scenario::next_tx(scenario, operator);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        vault::set_blacklisted_account(&mut vault, &config, address, status, test_scenario::ctx(scenario));
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);
    }

    public fun charge_platform_fee(scenario: &mut Scenario, clock_time: u64) {
        let operator = bob();
        test_scenario::next_tx(scenario, operator);
        let mut clock = clock::create_for_testing(test_scenario::ctx(scenario));
        clock::set_for_testing(&mut clock, clock_time);
        let mut vault = test_scenario::take_shared<Vault<USDC,UltraUSDC>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        vault::charge_platform_fee<USDC,UltraUSDC>(&mut vault, &config, &clock, test_scenario::ctx(scenario));
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(config);
        test_scenario::return_shared(vault);

    }

    public fun deposit_assets<T,R>(scenario: &mut Scenario, user: address, amount: u64): Coin<R> {
        deposit_assets_with_slippage<T,R>(scenario, user, amount, 0) // Default min_shares = 0 (no slippage protection)
    }

    public fun deposit_assets_with_slippage<T,R>(scenario: &mut Scenario, user: address, amount: u64, min_shares: u64): Coin<R> {
        test_scenario::next_tx(scenario, user);
        let mut vault = test_scenario::take_shared<Vault<T,R>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);

        let deposit_balance = balance::create_for_testing<T>(amount);
        let mut clock = clock::create_for_testing(test_scenario::ctx(scenario));
        // Use a timestamp that's always after typical test operations
        clock::set_for_testing(&mut clock, 10000000000);
        
        let receipt = vault::deposit_asset_v2<T,R>(&mut vault, &config, deposit_balance, min_shares, &clock, test_scenario::ctx(scenario));

        clock::destroy_for_testing(clock);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        receipt
    }


    public fun mint_shares<T,R>(scenario: &mut Scenario, user: address, shares: u64, balance_amount: Option<u64>): Coin<R> {
        mint_shares_with_slippage<T,R>(scenario, user, shares, balance_amount, MAX_U64) // Default max_amount = MAX_U64 (no slippage protection)
    }

    public fun mint_shares_with_slippage<T,R>(scenario: &mut Scenario, user: address, shares: u64, balance_amount: Option<u64>, max_amount: u64): Coin<R> {
       test_scenario::next_tx(scenario, user);
       let mut vault = test_scenario::take_shared<Vault<T,R>>(scenario);
       let config = test_scenario::take_shared<ProtocolConfig>(scenario);

       let mut deposit_balance = balance::create_for_testing<T>(option::get_with_default(&balance_amount, MAX_U64));
       let mut clock = clock::create_for_testing(test_scenario::ctx(scenario));
       // Use a timestamp that's always after typical test operations
       clock::set_for_testing(&mut clock, 10000000000);
       
       let receipt = vault::mint_shares_v2<T,R>(&mut vault, &config, &mut deposit_balance, shares, max_amount, &clock, test_scenario::ctx(scenario));

       clock::destroy_for_testing(clock);
       balance::destroy_for_testing(deposit_balance);
       test_scenario::return_shared(vault);
       test_scenario::return_shared(config);

       receipt
    }

    public fun redeem_shares<T,R>(scenario: &mut Scenario, receipt: Coin<R>, shares: u64, user: address, receiver: address): (Coin<R>, WithdrawalRequest) {
        test_scenario::next_tx(scenario, user);

        let mut clock = clock::create_for_testing(test_scenario::ctx(scenario));
        clock::set_for_testing(&mut clock, 1000000000000000000); // random timestamp

        let mut vault = test_scenario::take_shared<Vault<T,R>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);

        let mut receipt_balance = coin::into_balance(receipt);
        let shares_balance = balance::split(&mut receipt_balance, shares);

        let request = vault::redeem_shares<T,R>(&mut vault, &config, shares_balance, receiver, &clock, test_scenario::ctx(scenario));

        clock::destroy_for_testing(clock);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        (coin::from_balance(receipt_balance, test_scenario::ctx(scenario)), request)
    }


    public fun process_withdrawal_request<T,R>(scenario: &mut Scenario, num_requests: u64) {
        test_scenario::next_tx(scenario, bob());

        let mut clock = clock::create_for_testing(test_scenario::ctx(scenario));
        clock::set_for_testing(&mut clock, 1000000000000000000); // random timestamp

        let mut vault = test_scenario::take_shared<Vault<T,R>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);


        vault::process_withdrawal_requests<T,R>(&mut vault, &config, num_requests, &clock, test_scenario::ctx(scenario));

        clock::destroy_for_testing(clock);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    public fun process_withdrawal_request_up_to_timestamp<T,R>(scenario: &mut Scenario, clock_time: u64, process_up_to: u64) {
        test_scenario::next_tx(scenario, bob());

        let mut clock = clock::create_for_testing(test_scenario::ctx(scenario));
        clock::set_for_testing(&mut clock, clock_time);

        let mut vault = test_scenario::take_shared<Vault<T,R>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);


        vault::process_withdrawal_requests_up_to_timestamp<T,R>(&mut vault, &config, process_up_to, &clock, test_scenario::ctx(scenario));

        clock::destroy_for_testing(clock);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    public fun set_vault_rate_manager<T,R>(scenario: &mut Scenario, rate_manager: address) {
        test_scenario::next_tx(scenario, protocol_admin());
        
        let mut vault = test_scenario::take_shared<Vault<T,R>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);
        
        // Try to set the rate manager - if it fails with ESameValue, that's okay
        vault::update_vault_rate_manager<T,R>(&mut vault, &config, rate_manager, test_scenario::ctx(scenario));
        
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

        
    public fun update_vault_rate<T,R>(scenario: &mut Scenario, clock_time: u64, new_rate: u64) {
        test_scenario::next_tx(scenario, alice());

        let mut clock = clock::create_for_testing(test_scenario::ctx(scenario));
        clock::set_for_testing(&mut clock, clock_time);

        let mut vault = test_scenario::take_shared<Vault<T,R>>(scenario);
        let config = test_scenario::take_shared<ProtocolConfig>(scenario);

        vault::update_vault_rate<T,R>(&mut vault, &config, new_rate, &clock, test_scenario::ctx(scenario));

        clock::destroy_for_testing(clock);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }



}