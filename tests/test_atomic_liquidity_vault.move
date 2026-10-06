/*
  Copyright (c) 2026 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  Smoke tests for `atomic_liquidity_vault`. Coverage focuses on the
  no-strategy paths that do not require Suilend mocks (those
  protocols' interface stubs have `abort 0` bodies, so anything that touches
  them aborts unless run against a real testnet integration).
*/
#[test_only]
module ember_vaults::test_atomic_liquidity_vault {

    use std::string;

    use sui::sui::SUI;
    use sui::test_scenario;

    use ember_vaults::admin::{Self, AdminCap, ProtocolConfig};
    use ember_vaults::atomic_liquidity_vault::{Self as al, AtomicLiquidityVault};
    use ember_vaults::strategy;
    use ember_vaults::test_atomic_utils as au;
    use ember_vaults::test_utils::USDC;
    use suilend::lending_market;

    /// Phantom marker standing in for Suilend's main-pool witness type `P`.
    public struct MAIN_POOL {}

    // === SUI-vault fixture (M-01) ===

    /// Creates and shares an `AtomicLiquidityVault<SUI>`. The standard
    /// `au::initialize` fixture is USDC-only; the SUI-strategy paths need a
    /// vault whose collateral type actually is `SUI`.
    fun init_sui_atomic_vault(sc: &mut test_scenario::Scenario) {
        let pa = au::protocol_admin();
        test_scenario::next_tx(sc, pa);
        admin::initialize_module(test_scenario::ctx(sc));

        test_scenario::next_tx(sc, pa);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        let cap = test_scenario::take_from_address<AdminCap>(sc, pa);
        let (vault, ticket) = al::create_atomic_liquidity_vault<SUI>(
            &config,
            &cap,
            string::utf8(b"Atomic SUI Vault"),
            pa,          // admin
            au::bob(),   // operator
            au::alice(), // rate manager
            50_000_000,
            0,
            1,
            86_400_000,
            1_000_000_000_000,
            vector::empty(),
            test_scenario::ctx(sc),
        );
        al::share_atomic_vault(vault, ticket);
        test_scenario::return_shared(config);
        test_scenario::return_to_address(pa, cap);
    }

    #[test]
    /// I-11: activation commits the market, and the committed market is
    /// accepted on a later Suilend call. Clearing an empty position never
    /// enters Suilend, so this is exercisable against the `abort 0` stubs.
    fun suilend_accepts_the_committed_market() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );
        assert!(al::get_strategy_kind(&vault) == 1, 0);

        // A reward destination must exist before any exit — see
        // `suilend_exit_is_blocked_when_no_reward_destination_exists`. The
        // fixture's allowlist is empty, so allowlist one.
        al::set_sub_account(&mut vault, &config, au::charlie(), true, test_scenario::ctx(&mut sc));

        al::set_strategy_none_from_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &mut market, &clock, test_scenario::ctx(&mut sc),
        );
        assert!(al::get_strategy_kind(&vault) == 0, 1);

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    /// A vault committed to Suilend that has never opened an obligation values
    /// at 0 rather than aborting, so the view stays callable across the window
    /// between activation and the first supply.
    fun suilend_assets_are_zero_before_an_obligation_exists() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );
        assert!(al::get_strategy_kind(&vault) == 1, 0);

        // Activation alone opens no obligation, so `obligation_ctoken_amount`
        // short-circuits and Suilend is never entered.
        assert!(al::get_suilend_strategy_assets<USDC, MAIN_POOL>(&vault, &market, &clock) == 0, 1);
        assert!(
            al::get_total_backing_suilend<USDC, MAIN_POOL>(&vault, &market, &clock)
                == (al::get_vault_balance(&vault) as u128),
            2,
        );

        al::set_strategy_kind_for_testing(&mut vault, 0);

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    /// A vault with no strategy is allowed through both variants: the idle
    /// balance IS the whole backing there, so each is complete and they agree.
    /// Without that carve-out a STRATEGY_NONE vault could not be read at all.
    fun total_backing_allows_a_vault_with_no_strategy() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        assert!(al::get_strategy_kind(&vault) == 0, 0);
        assert!(
            al::get_total_backing_suilend<USDC, MAIN_POOL>(&vault, &market, &clock)
                == (al::get_vault_balance(&vault) as u128),
            1,
        );

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::strategy::ESuilendMarketMismatch)]
    /// I-11: a structurally identical but DIFFERENT market object must be
    /// refused. Before this, only a reserve index was stored, so the market
    /// object and `P` were whatever the operator passed on first supply and a
    /// wrong market was undetectable on chain.
    fun suilend_rejects_a_market_other_than_the_committed_one() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let committed = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let mut impostor = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &committed, 0, test_scenario::ctx(&mut sc),
        );

        // A reward destination must exist before any exit — see
        // `suilend_exit_is_blocked_when_no_reward_destination_exists`. The
        // fixture's allowlist is empty, so allowlist one.
        al::set_sub_account(&mut vault, &config, au::charlie(), true, test_scenario::ctx(&mut sc));

        al::set_strategy_none_from_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &mut impostor, &clock, test_scenario::ctx(&mut sc),
        );

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(committed);
        lending_market::destroy_for_testing(impostor);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    /// M-01: activating Suilend on a `Vault<SUI>` must be allowed now that the
    /// SUI redemption path (`request -> unstake -> fulfill`) exists. The
    /// interim fix rejected this outright to avoid an unexitable position.
    fun should_allow_suilend_activation_on_sui_vault() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        init_sui_atomic_vault(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<SUI>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        assert!(al::get_strategy_kind(&vault) == 0, 0); // STRATEGY_NONE
        al::set_strategy_suilend<SUI, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );
        assert!(al::get_strategy_kind(&vault) == 1, 1); // STRATEGY_SUILEND
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        test_scenario::end(sc);
    }

    // === Suilend obligation / rewards ===
    //
    // Coverage here is limited to the ember-side guards, because every Suilend
    // call that would actually touch an obligation (`create_obligation`,
    // `deposit_ctokens_into_obligation`, `withdraw_ctokens`, `claim_rewards`)
    // is an `abort 0` stub body. The obligation-present branches — supply
    // landing in the obligation, withdraw pulling from it, the residual-deposit
    // assert, and a real reward claim — need a devnet dev-inspect against the
    // published Suilend package, alongside the M-01 / M-04 / L-06 / L-08 runs
    // already outstanding.

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EStrategyMismatch)]
    /// Opening an obligation is the second half of Suilend activation, so it
    /// must refuse to run while the vault is on STRATEGY_NONE — otherwise a cap
    /// could be parked on a vault that has no committed market to validate it
    /// against.
    fun open_suilend_obligation_requires_the_suilend_strategy() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));

        assert!(al::get_strategy_kind(&vault) == 0, 0);
        al::open_suilend_obligation<USDC, MAIN_POOL>(
            &mut vault, &config, &mut market, test_scenario::ctx(&mut sc),
        );

        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    /// The strategy-assets view is the Sui counterpart of EVM
    /// `getStrategyAssets()`, and exists so an off-chain reader does not treat
    /// idle balance as the whole backing — the `*_with_suilend` exits redeem
    /// from the strategy inline, so a deployed vault can pay out more than it
    /// holds idle.
    ///
    /// Only the guard branches are exercisable here: valuing a real position
    /// enters Suilend, and the stubs abort.
    fun strategy_assets_views_return_zero_off_their_own_strategy() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        // STRATEGY_NONE: nothing is deployed, so backing is exactly the idle
        // balance. The market is never touched, which is why this runs at all.
        assert!(al::get_strategy_kind(&vault) == 0, 0);
        assert!(al::get_suilend_strategy_assets<USDC, MAIN_POOL>(&vault, &market, &clock) == 0, 1);
        assert!(
            al::get_total_backing_suilend<USDC, MAIN_POOL>(&vault, &market, &clock)
                == (al::get_vault_balance(&vault) as u128),
            2,
        );

        // A vault committed to SUILEND but with no obligation also reads 0, and
        // reaches that answer without entering Suilend — the early return in
        // `get_suilend_supplied_value` precedes the market/coin-type asserts so
        // the view stays callable between activation and the first supply.
        al::set_strategy_kind_for_testing(&mut vault, 1);
        assert!(al::get_suilend_strategy_assets<USDC, MAIN_POOL>(&vault, &market, &clock) == 0, 10);

        al::set_strategy_kind_for_testing(&mut vault, 0);

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidPermission)]
    /// Neither the admin nor the operator, so refused. Enrolment is gated to
    /// both trusted roles (so whichever one runs activation can finish it), but
    /// no wider than that.
    fun open_suilend_obligation_rejects_an_untrusted_sender() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );

        // charlie holds no role on this vault.
        test_scenario::next_tx(&mut sc, au::charlie());
        al::open_suilend_obligation<USDC, MAIN_POOL>(
            &mut vault, &config, &mut market, test_scenario::ctx(&mut sc),
        );

        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EOperationPaused)]
    /// L-1, now applicable to Suilend. The exit discards the
    /// `ObligationOwnerCap`, so it must not run while
    /// `claim_suilend_strategy_reward` is frozen — the mandatory
    /// sweep-before-exit would be impossible and every accrued reward stranded.
    /// The Suilend exit did not need this gate while it discarded nothing, and
    /// does now.
    fun suilend_exit_is_blocked_while_privileged_operations_are_paused() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        au::set_pause(&mut sc, b"privileged_operations", true);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_strategy_none_from_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &mut market, &clock, test_scenario::ctx(&mut sc),
        );

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidPermission)]
    /// Reward collection rejects a caller who is neither admin nor operator.
    ///
    /// The auth guard runs before Suilend is entered, which is what makes this
    /// reachable against the abort-only stub.
    fun collect_reward_rejects_non_admin_non_operator() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clk = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );

        // @0xBAD holds no role on this vault.
        test_scenario::next_tx(&mut sc, @0xBAD);
        al::claim_suilend_strategy_reward<USDC, MAIN_POOL, USDC, USDC>(
            &mut vault, &config, &mut market, au::charlie(), 0, true, &clk,
            test_scenario::ctx(&mut sc),
        );

        sui::clock::destroy_for_testing(clk);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }
    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidAccount)]
    /// Rewards may only be forwarded to an allowlisted sub-account, and the
    /// check runs BEFORE entering Suilend — otherwise it would sit behind an
    /// `abort 0` stub and be untestable, and a bad address would cost a claim
    /// before failing. `charlie` is not a sub-account of this vault.
    fun suilend_reward_claim_rejects_a_non_sub_account_recipient() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );

        test_scenario::next_tx(&mut sc, au::bob()); // operator
        al::claim_suilend_strategy_reward<USDC, MAIN_POOL, USDC, SUI>(
            &mut vault, &config, &mut market, au::charlie(), 0, true, &clock,
            test_scenario::ctx(&mut sc),
        );

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::strategy::ESuilendObligationMissing)]
    /// Claiming before enrolment must abort loudly rather than return zero.
    /// A silent no-op here would be indistinguishable from "this reserve pays
    /// nothing", which is exactly the failure mode that let the vault run
    /// unenrolled without anyone noticing.
    fun suilend_reward_claim_requires_an_open_obligation() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::bob()); // operator
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );

        // Allowlist the recipient as admin, then claim as operator.
        al::set_sub_account(&mut vault, &config, au::charlie(), true, test_scenario::ctx(&mut sc));

        test_scenario::next_tx(&mut sc, au::bob());
        al::claim_suilend_strategy_reward<USDC, MAIN_POOL, USDC, SUI>(
            &mut vault, &config, &mut market, au::charlie(), 0, true, &clock,
            test_scenario::ctx(&mut sc),
        );

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    /// The whole point of the vault-level getter: `get_strategy_kind() == 1`
    /// means `set_strategy_suilend` ran, NOT that the vault can supply. Half-
    /// activated is a real, reachable state, and this is what tells the two
    /// apart on chain instead of leaving tooling to infer it from
    /// `SuilendObligationOpenedEvent`.
    fun strategy_kind_alone_does_not_imply_an_open_obligation() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));

        // Non-Suilend vault: false, not an abort.
        assert!(!al::has_suilend_obligation(&vault), 0);

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );

        assert!(al::get_strategy_kind(&vault) == 1, 1);
        assert!(!al::has_suilend_obligation(&vault), 2);

        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::strategy::ESuilendObligationMissing)]
    /// `get_suilend_obligation_id` resolves an object that only exists once
    /// enrolment has run, so it aborts rather than inventing an ID. Callers that
    /// do not already know the state pair it with `has_suilend_obligation`.
    fun get_suilend_obligation_id_aborts_before_enrolment() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );
        al::get_suilend_obligation_id(&vault);

        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::ENoRewardDestination)]
    /// Second way to freeze the reward sweep, and it needs the same guard as the
    /// first. Rewards can only go to an allowlisted sub-account, so an empty
    /// allowlist makes every claim abort for every address. The exit then
    /// discards the `ObligationOwnerCap`, permanently stranding anything
    /// accrued — exactly what the L-1 pause gate exists to prevent, reachable
    /// through configuration instead of pausing.
    ///
    /// An empty allowlist is reachable both ways: `create_atomic_liquidity_vault`
    /// permits `vector::empty()` (the loop validating entries just does not run,
    /// which is the default in this fixture), and `set_sub_account(_, false)`
    /// removes without a floor.
    fun suilend_exit_is_blocked_when_no_reward_destination_exists() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        assert!(vector::is_empty(&al::get_vault_sub_accounts(&vault)), 0);

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );
        al::set_strategy_none_from_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &mut market, &clock, test_scenario::ctx(&mut sc),
        );

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::strategy::ESuilendObligationMissing)]
    /// Withdrawing before enrolment must name the actual cause. Pins the assert
    /// ORDER in `withdraw_obligation_ctokens`: `obligation_ctoken_amount`
    /// returns 0 when no obligation exists, so checking sufficiency first would
    /// report this as `EStrategyInsufficientCTokens` — which by its own
    /// definition means genuine underfunding (M-04), and would send an operator
    /// debugging a failed user withdrawal after the wrong problem. Both orders
    /// abort, so only the error code distinguishes them.
    fun suilend_withdraw_before_enrolment_reports_the_missing_obligation() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let clock = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));

        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );

        test_scenario::next_tx(&mut sc, au::bob()); // operator
        al::withdraw_from_suilend_strategy<USDC, MAIN_POOL>(
            &mut vault, &config, &mut market, 1_000, &clock, test_scenario::ctx(&mut sc),
        );

        sui::clock::destroy_for_testing(clock);
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    /// Activation records the collateral type, and the committed type is
    /// accepted. Exercised against `strategy` directly on a bare UID — the
    /// vault layer can only ever pass its own `T`, so the guard is unreachable
    /// through the public API.
    fun suilend_accepts_the_committed_coin_type() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let mut uid = object::new(test_scenario::ctx(&mut sc));

        strategy::init_suilend_state<MAIN_POOL, USDC>(&mut uid, &market, 0);
        strategy::assert_suilend_coin_type<USDC>(&uid);
        // Enrolment is a separate step, so nothing is open yet.
        assert!(!strategy::has_suilend_obligation(&uid), 0);

        object::delete(uid);
        lending_market::destroy_for_testing(market);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::strategy::ESuilendCoinTypeMismatch)]
    /// The reason the commitment exists. `obligation::deposited_ctoken_amount`
    /// selects the deposit BY COIN TYPE and returns 0 when it finds none, so a
    /// wrong `T` reads an empty position instead of failing — and a teardown
    /// would then skip the drain and discard the obligation cap over a live
    /// deposit. Same failure class as I-11, which the old typed cToken slot
    /// caught implicitly and this replaces.
    fun suilend_rejects_a_coin_type_other_than_the_committed_one() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        let mut uid = object::new(test_scenario::ctx(&mut sc));

        strategy::init_suilend_state<MAIN_POOL, USDC>(&mut uid, &market, 0);
        strategy::assert_suilend_coin_type<SUI>(&uid);

        object::delete(uid);
        lending_market::destroy_for_testing(market);
        test_scenario::end(sc);
    }

    // === Vault Creation ===

    #[test]
    fun should_create_atomic_vault_with_default_state() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);

        assert!(al::get_vault_admin(&vault) == au::protocol_admin(), 1);
        assert!(al::get_vault_operator(&vault) == au::bob(), 2);
        assert!(al::get_vault_rate_manager(&vault) == au::alice(), 3);
        assert!(al::get_total_shares(&vault) == 0, 4);
        assert!(al::get_pending_burn_shares(&vault) == 0, 5);
        assert!(al::get_vault_balance(&vault) == 0, 6);
        assert!(al::get_strategy_kind(&vault) == 0, 7); // STRATEGY_NONE
        assert!(al::get_max_instant_withdraw_shares(&vault) == 0, 8);
        assert!(al::get_cumulative_instant_withdraw_shares(&vault) == 0, 9);
        assert!(al::get_instant_withdraw_fee_percentage(&vault) == 0, 10);
        assert!(!al::is_paused_deposits(&vault), 11);
        assert!(!al::is_paused_withdrawals(&vault), 12);
        assert!(!al::is_paused_privileged_operations(&vault), 13);

        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    // === Deposit ===

    #[test]
    fun should_deposit_and_credit_internal_shares() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        let minted = au::deposit(&mut sc, au::charlie(), 100_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);

        // default rate is 1e9 (DEFAULT_RATE in admin.move): shares == amount.
        assert!(minted == 100_000_000, 1);
        assert!(al::balance_of(&vault, au::charlie()) == 100_000_000, 2);
        assert!(al::get_total_shares(&vault) == 100_000_000, 3);
        assert!(al::get_vault_balance(&vault) == 100_000_000, 4);

        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun should_aggregate_multiple_deposits_for_same_user() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 50_000_000);
        au::deposit(&mut sc, au::charlie(), 30_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::balance_of(&vault, au::charlie()) == 80_000_000, 1);
        assert!(al::get_total_shares(&vault) == 80_000_000, 2);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EOperationPaused)]
    fun should_reject_deposit_when_deposits_paused() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::set_pause(&mut sc, b"deposits", true);
        au::deposit(&mut sc, au::charlie(), 1_000);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EBlacklistedAccount)]
    fun should_reject_deposit_from_blacklisted_user() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::blacklist(&mut sc, au::charlie(), true);
        au::deposit(&mut sc, au::charlie(), 1_000);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::ESlippageToleranceExceeded)]
    fun should_reject_deposit_when_min_shares_not_met() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        // Deposit 1000 USDC asking for >1000 shares (impossible at default rate).
        test_scenario::next_tx(&mut sc, au::charlie());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut clk = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));
        sui::clock::set_for_testing(&mut clk, 10_000_000_000);
        let coin = sui::coin::from_balance(
            sui::balance::create_for_testing<USDC>(1_000),
            test_scenario::ctx(&mut sc),
        );
        al::deposit<USDC>(&mut vault, &config, coin, 9_999, au::charlie(), &clk, test_scenario::ctx(&mut sc));
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    // === Admin Setters: validation ===

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidPermission)]
    fun should_reject_admin_setter_from_non_admin() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        // alice is rate manager, not admin — try to set fee from her account.
        test_scenario::next_tx(&mut sc, au::alice());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let clk = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));
        al::update_vault_fee_percentage<USDC>(&mut vault, &config, 5_000_000, &clk, test_scenario::ctx(&mut sc));
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    // === Sub-account deposit from the accumulator balance ===
    //
    // The happy path can't be exercised here: there is no way to credit an
    // object's accumulator (address) balance from `test_scenario`, and the
    // over-withdraw case aborts inside a native at redemption, which the test
    // framework does not implement. These tests cover what is reachable: the
    // guards, which run *before* the accumulator is touched, so they pin
    // `deposit_from_sub_account_v2` to the same gating as the TTO-based
    // `deposit_from_sub_account`.

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidPermission)]
    fun should_reject_accumulator_deposit_from_non_operator() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        // alice is rate manager, not operator.
        test_scenario::next_tx(&mut sc, au::alice());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::deposit_from_sub_account_v2<USDC>(
            &mut vault,
            &config,
            1_000_000,
            au::charlie(),
            test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidAccount)]
    fun should_reject_accumulator_deposit_for_unregistered_sub_account() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        // bob is the operator, but the default vault has no sub-accounts.
        test_scenario::next_tx(&mut sc, au::bob());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::deposit_from_sub_account_v2<USDC>(
            &mut vault,
            &config,
            1_000_000,
            au::charlie(),
            test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInstantWithdrawFeeTooHigh)]
    fun should_reject_instant_withdraw_fee_above_100_percent() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::set_instant_withdraw_fee(&mut sc, 1_000_000_001); // > PERCENT_MAX
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidPauseOperation)]
    fun should_reject_pause_op_with_unknown_string() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::set_pause(&mut sc, b"bogus_op", true);
        test_scenario::end(sc);
    }

    #[test]
    fun should_pause_each_operation_independently() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::set_pause(&mut sc, b"deposits", true);
        au::set_pause(&mut sc, b"withdrawals", true);
        au::set_pause(&mut sc, b"privileged_operations", true);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::is_paused_deposits(&vault), 1);
        assert!(al::is_paused_withdrawals(&vault), 2);
        assert!(al::is_paused_privileged_operations(&vault), 3);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    // === Redeem (request-based) ===

    /// Helper: enqueue a redeem request from `user` for `shares` and return
    /// the request's sequence number. Pulls the vault + config + clock through
    /// a fresh scenario tx.
    fun redeem_request(sc: &mut test_scenario::Scenario, user: address, shares: u64): u128 {
        test_scenario::next_tx(sc, user);
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        let mut clk = sui::clock::create_for_testing(test_scenario::ctx(sc));
        sui::clock::set_for_testing(&mut clk, 10_000_000_000);
        let req = al::redeem_shares<USDC>(
            &mut vault, &config, shares, user, &clk, test_scenario::ctx(sc),
        );
        let seq = al::test_get_withdrawal_request_sequence(&req);
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        seq
    }

    /// Helper: operator calls process_withdrawal_requests for `n` requests.
    fun process_n(sc: &mut test_scenario::Scenario, n: u64) {
        test_scenario::next_tx(sc, au::bob());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        let mut clk = sui::clock::create_for_testing(test_scenario::ctx(sc));
        sui::clock::set_for_testing(&mut clk, 10_000_000_000);
        al::process_withdrawal_requests<USDC>(
            &mut vault, &config, n, &clk, test_scenario::ctx(sc),
        );
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    #[test]
    fun should_park_shares_in_pending_burn_on_redeem_request() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);

        let _seq = redeem_request(&mut sc, au::charlie(), 40_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::balance_of(&vault, au::charlie()) == 60_000_000, 1);
        assert!(al::get_pending_burn_shares(&vault) == 40_000_000, 2);
        // total_shares is unchanged at request time per EVM semantics.
        assert!(al::get_total_shares(&vault) == 100_000_000, 3);
        assert!(al::get_account_total_pending_withdrawal_shares(&vault, au::charlie()) == 40_000_000, 4);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun should_burn_shares_and_pay_collateral_on_process() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        let _seq = redeem_request(&mut sc, au::charlie(), 40_000_000);

        process_n(&mut sc, 1);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        // Shares burnt out of total_shares.
        assert!(al::get_total_shares(&vault) == 60_000_000, 1);
        assert!(al::get_pending_burn_shares(&vault) == 0, 2);
        // Collateral split out of vault balance to receiver.
        assert!(al::get_vault_balance(&vault) == 60_000_000, 3);
        // Per-account state cleared once balance hits 0.
        assert!(al::get_account_total_pending_withdrawal_shares(&vault, au::charlie()) == 0, 4);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun should_skip_and_return_shares_on_processed_cancellation() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        let seq = redeem_request(&mut sc, au::charlie(), 40_000_000);

        // Owner cancels their own request.
        test_scenario::next_tx(&mut sc, au::charlie());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::cancel_pending_withdrawal_request<USDC>(
            &mut vault, &config, seq, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        process_n(&mut sc, 1);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        // Shares restored to user; total_shares unchanged.
        assert!(al::get_total_shares(&vault) == 100_000_000, 1);
        assert!(al::balance_of(&vault, au::charlie()) == 100_000_000, 2);
        assert!(al::get_pending_burn_shares(&vault) == 0, 3);
        // Vault balance preserved (no payout).
        assert!(al::get_vault_balance(&vault) == 100_000_000, 4);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInsufficientShares)]
    fun should_reject_redeem_below_min_withdrawal_shares() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);

        // Bump min_withdrawal_shares to a value larger than what we'll request.
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_min_withdrawal_shares<USDC>(&mut vault, &config, 1_000_000, test_scenario::ctx(&mut sc));
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        let _ = redeem_request(&mut sc, au::charlie(), 100); // < 1_000_000
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInsufficientShares)]
    fun should_reject_redeem_above_owner_balance() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 1_000);
        let _ = redeem_request(&mut sc, au::charlie(), 5_000); // > balance
        test_scenario::end(sc);
    }

    // === Instant Withdraw (no-strategy variant) ===

    /// Helper: admin enables instant withdraw with `cap` shares + `fee_pct`.
    fun enable_instant_withdraw(sc: &mut test_scenario::Scenario, cap: u64, fee_pct: u64) {
        au::set_max_instant_withdraw_shares(sc, cap);
        if (fee_pct > 0) {
            au::set_instant_withdraw_fee(sc, fee_pct);
        };
    }

    fun call_instant_withdraw(
        sc: &mut test_scenario::Scenario,
        user: address,
        shares: u64,
    ): u64 {
        test_scenario::next_tx(sc, user);
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        let mut clk = sui::clock::create_for_testing(test_scenario::ctx(sc));
        sui::clock::set_for_testing(&mut clk, 10_000_000_000);
        let net = al::instant_withdraw<USDC>(
            &mut vault, &config, shares, user, &clk, test_scenario::ctx(sc),
        );
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        net
    }

    #[test]
    fun should_burn_shares_and_pay_net_amount_on_instant_withdraw() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        // Enable instant withdraw with no fee.
        enable_instant_withdraw(&mut sc, 100_000_000, 0);

        let net = call_instant_withdraw(&mut sc, au::charlie(), 40_000_000);
        // No fee, default rate 1e9 → net == shares == 40e6.
        assert!(net == 40_000_000, 1);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::balance_of(&vault, au::charlie()) == 60_000_000, 2);
        assert!(al::get_total_shares(&vault) == 60_000_000, 3);
        assert!(al::get_cumulative_instant_withdraw_shares(&vault) == 40_000_000, 4);
        // Vault balance: 100e6 - 40e6 = 60e6.
        assert!(al::get_vault_balance(&vault) == 60_000_000, 5);
        // No fee accrued (fee_pct == 0).
        assert!(al::get_accrued_platform_fee(&vault) == 0, 6);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun should_charge_instant_withdraw_fee_to_platform_fee_accrual() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        // 1% instant withdraw fee.
        enable_instant_withdraw(&mut sc, 100_000_000, 10_000_000);

        let net = call_instant_withdraw(&mut sc, au::charlie(), 40_000_000);
        // gross = 40e6. fee = 40e6 * 1% = 4e5. net = 39_600_000.
        assert!(net == 39_600_000, 1);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::get_accrued_platform_fee(&vault) == 400_000, 2);
        // Vault balance: 100e6 - 39.6e6 = 60.4e6 (the fee stays on-vault until collected).
        assert!(al::get_vault_balance(&vault) == 60_400_000, 3);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInstantWithdrawCapExceeded)]
    fun should_reject_instant_withdraw_above_cumulative_cap() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        // Cap = 30e6 — request 40e6 → exceeds.
        enable_instant_withdraw(&mut sc, 30_000_000, 0);
        let _ = call_instant_withdraw(&mut sc, au::charlie(), 40_000_000);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInstantWithdrawCapExceeded)]
    fun should_advance_cumulative_across_multiple_calls_then_reject() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        enable_instant_withdraw(&mut sc, 60_000_000, 0);

        let _ = call_instant_withdraw(&mut sc, au::charlie(), 40_000_000);
        let _ = call_instant_withdraw(&mut sc, au::charlie(), 30_000_000); // cum 70 > 60 cap
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EStrategyMismatch)]
    fun should_reject_no_strategy_variant_when_strategy_is_set() {
        // Tries to use the no-strategy `instant_withdraw` after we've flipped
        // the vault into Suilend strategy. We set strategy via test helper to
        // avoid invoking the actual Suilend stub (which aborts).
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        enable_instant_withdraw(&mut sc, 100_000_000, 0);

        // Activate Suilend strategy with a placeholder reserve index. This
        // doesn't touch the lending market; it just stores the index in a
        // dynamic field so the vault's strategy_kind flips to SUILEND.
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let market = lending_market::new_for_testing<MAIN_POOL>(test_scenario::ctx(&mut sc));
        al::set_strategy_suilend<USDC, MAIN_POOL>(
            &mut vault, &config, &market, 0, test_scenario::ctx(&mut sc),
        );
        lending_market::destroy_for_testing(market);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        // Now this should abort EStrategyMismatch.
        let _ = call_instant_withdraw(&mut sc, au::charlie(), 1_000);
        test_scenario::end(sc);
    }

    // === Withdrawal Fees ===

    /// Helper: admin sets the permanent fee percentage.
    fun set_permanent_fee(sc: &mut test_scenario::Scenario, pct: u64) {
        test_scenario::next_tx(sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        al::set_permanent_fee_percentage<USDC>(&mut vault, &config, pct, test_scenario::ctx(sc));
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    /// Helper: admin sets the time-based fee percentage and threshold.
    fun set_time_based_fee(sc: &mut test_scenario::Scenario, pct: u64, threshold_ms: u64) {
        test_scenario::next_tx(sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        al::set_time_based_fee_percentage<USDC>(&mut vault, &config, pct, test_scenario::ctx(sc));
        al::set_time_based_fee_threshold<USDC>(&mut vault, &config, threshold_ms, test_scenario::ctx(sc));
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    /// Helper: operator adds/removes user from the fee exemption list.
    fun set_fee_exempt(sc: &mut test_scenario::Scenario, user: address, status: bool) {
        test_scenario::next_tx(sc, au::bob()); // operator
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        al::set_fee_exemption_list<USDC>(
            &mut vault, &config, user, status, test_scenario::ctx(sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    /// Helper: process N withdrawal requests at a specific clock time.
    fun process_n_at(sc: &mut test_scenario::Scenario, n: u64, clock_time: u64) {
        test_scenario::next_tx(sc, au::bob());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        let mut clk = sui::clock::create_for_testing(test_scenario::ctx(sc));
        sui::clock::set_for_testing(&mut clk, clock_time);
        al::process_withdrawal_requests<USDC>(
            &mut vault, &config, n, &clk, test_scenario::ctx(sc),
        );
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    }

    #[test]
    fun should_charge_permanent_fee_on_processed_withdrawal() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        // 2% permanent fee.
        set_permanent_fee(&mut sc, 20_000_000);

        let _ = redeem_request(&mut sc, au::charlie(), 40_000_000);
        process_n(&mut sc, 1);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        // gross = 40e6, fee = 800_000, net = 39_200_000.
        // Vault balance: 100e6 - 39_200_000 = 60_800_000 (fee stays on-vault).
        assert!(al::get_vault_balance(&vault) == 60_800_000, 1);
        assert!(al::get_total_shares(&vault) == 60_000_000, 2);
        // Fee is NOT routed into platform_fee.accrued — it stays in balance.
        assert!(al::get_accrued_platform_fee(&vault) == 0, 3);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun should_skip_permanent_fee_for_exempt_user() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        set_permanent_fee(&mut sc, 20_000_000); // 2%
        set_fee_exempt(&mut sc, au::charlie(), true);

        let _ = redeem_request(&mut sc, au::charlie(), 40_000_000);
        process_n(&mut sc, 1);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        // No fee — gross == net == 40e6. Balance = 100e6 - 40e6 = 60e6.
        assert!(al::get_vault_balance(&vault) == 60_000_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun should_charge_time_based_fee_when_within_threshold() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        // Deposit at t=10_000_000_000. Set threshold = 100_000 ms (large
        // enough that t+100k > 10_000_000_000 + 100_000).
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        set_time_based_fee(&mut sc, 50_000_000, 100_000); // 5% within 100k ms

        let _ = redeem_request(&mut sc, au::charlie(), 40_000_000);
        // Process at clock 10_000_050_000 — still within last_deposit + 100_000.
        process_n_at(&mut sc, 1, 10_000_050_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        // gross = 40e6, fee = 2e6, net = 38e6. Balance = 100e6 - 38e6 = 62e6.
        assert!(al::get_vault_balance(&vault) == 62_000_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun should_skip_time_based_fee_outside_threshold() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        set_time_based_fee(&mut sc, 50_000_000, 100); // 5% within 100 ms

        let _ = redeem_request(&mut sc, au::charlie(), 40_000_000);
        // Process at clock far beyond the threshold window.
        process_n_at(&mut sc, 1, 999_999_999_999);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        // No fee — gross == net == 40e6.
        assert!(al::get_vault_balance(&vault) == 60_000_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun should_stack_permanent_and_time_based_fees() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        set_permanent_fee(&mut sc, 10_000_000); // 1% permanent
        set_time_based_fee(&mut sc, 50_000_000, 100_000); // 5% time-based within 100k ms

        let _ = redeem_request(&mut sc, au::charlie(), 40_000_000);
        process_n_at(&mut sc, 1, 10_000_050_000); // within threshold

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        // gross = 40e6
        // Both fees computed on gross (matches EVM
        // EmberVaultValidator.calculateWithdrawalFees):
        //   permanent   = 40e6 * 1% = 400_000
        //   time_based  = 40e6 * 5% = 2_000_000
        //   net         = 40e6 - 400_000 - 2_000_000 = 37_600_000
        // Balance = 100e6 - 37_600_000 = 62_400_000.
        assert!(al::get_vault_balance(&vault) == 62_400_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidFeePercentage)]
    fun should_reject_permanent_fee_at_or_above_100_percent() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        set_permanent_fee(&mut sc, 1_000_000_000); // == PERCENT_MAX → rejected
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidPermission)]
    fun should_reject_fee_exemption_from_non_operator() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        // Try to set fee exemption from admin (alice is rate manager, not
        // operator either). Either should fail.
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_fee_exemption_list<USDC>(
            &mut vault, &config, au::charlie(), true, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    // === EmberShare utilization + fee-multiplier curve ===
    //
    // These tests exercise the configuration surface only — the actual
    // swap path requires a fully-set-up source Vault<T, R> which is
    // significantly more plumbing. Curve correctness and setter
    // validation are tested here; end-to-end swap is verified manually
    // on testnet before mainnet rollout.

    /// Whitelists a dummy source vault id with the given parameters and
    /// returns the id.
    fun whitelist_share(
        sc: &mut test_scenario::Scenario,
        max_util: u64,
    ): sui::object::ID {
        // Synthesise an opaque source id (we never dereference it; it's
        // just a key into ember_share_configs).
        let id = sui::object::id_from_address(@0xDEAD_BEEF);
        test_scenario::next_tx(sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        al::set_ember_share_whitelist<USDC>(
            &mut vault, &config, id,
            true,         // whitelisted
            10_000_000,   // fee_percentage = 1%
            500_000_000,  // max_capacity_percentage = 50%
            50_000_000,   // holdback_percentage = 5%
            max_util,     // max_utilization_percentage
            0,            // min_swap_gross: dust floor disabled
            0,            // max_held_value_absolute: absolute cap disabled
            test_scenario::ctx(sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        id
    }

    #[test]
    fun whitelist_initialises_max_utilization_and_empty_curve() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 600_000_000); // 60%

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);

        assert!(al::get_ember_share_max_utilization(&vault, share_id) == 600_000_000, 1);
        assert!(al::get_ember_share_fee_multiplier_curve_length(&vault, share_id) == 0, 2);
        // Empty curve resolves to 1x (1e9) at any utilization.
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 250_000_000) == 1_000_000_000, 3);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 900_000_000) == 1_000_000_000, 4);

        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun set_max_utilization_updates_the_cap() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 600_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_max_utilization<USDC>(
            &mut vault, &config, share_id, 200_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::get_ember_share_max_utilization(&vault, share_id) == 200_000_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidPercentage)]
    fun set_max_utilization_above_100_percent_aborts() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 600_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_max_utilization<USDC>(
            &mut vault, &config, share_id, 1_000_000_001, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    fun fee_multiplier_curve_step_function_lookup() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 1_000_000_000);

        // Insert three tiers out of order — verify ascending invariant
        // and step-function lookup behaviour.
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);

        // 2x at 50%
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 500_000_000, 2_000_000_000, test_scenario::ctx(&mut sc),
        );
        // 3x at 80%
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 800_000_000, 3_000_000_000, test_scenario::ctx(&mut sc),
        );
        // 1.5x at 30% (inserted at the front)
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 300_000_000, 1_500_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);

        assert!(al::get_ember_share_fee_multiplier_curve_length(&vault, share_id) == 3, 1);

        // Ascending order maintained:
        let (t0, m0) = al::get_ember_share_fee_multiplier_tier_at(&vault, share_id, 0);
        let (t1, m1) = al::get_ember_share_fee_multiplier_tier_at(&vault, share_id, 1);
        let (t2, m2) = al::get_ember_share_fee_multiplier_tier_at(&vault, share_id, 2);
        assert!(t0 == 300_000_000 && m0 == 1_500_000_000, 2);
        assert!(t1 == 500_000_000 && m1 == 2_000_000_000, 3);
        assert!(t2 == 800_000_000 && m2 == 3_000_000_000, 4);

        // Step-function lookup at various utilizations:
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 0) == 1_000_000_000, 5);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 299_999_999) == 1_000_000_000, 6);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 300_000_000) == 1_500_000_000, 7);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 499_999_999) == 1_500_000_000, 8);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 500_000_000) == 2_000_000_000, 9);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 700_000_000) == 2_000_000_000, 10);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 800_000_000) == 3_000_000_000, 11);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 1_000_000_000) == 3_000_000_000, 12);

        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun upserting_same_threshold_replaces_multiplier() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 1_000_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        // First insert
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 500_000_000, 2_000_000_000, test_scenario::ctx(&mut sc),
        );
        // Same threshold, new multiplier
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 500_000_000, 4_000_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::get_ember_share_fee_multiplier_curve_length(&vault, share_id) == 1, 1);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 600_000_000) == 4_000_000_000, 2);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    fun remove_tier_drops_the_row() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 1_000_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 300_000_000, 1_500_000_000, test_scenario::ctx(&mut sc),
        );
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 500_000_000, 2_000_000_000, test_scenario::ctx(&mut sc),
        );
        al::remove_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 300_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::get_ember_share_fee_multiplier_curve_length(&vault, share_id) == 1, 1);
        // After removal, 30% utilization now resolves to 1x (no tier matches below 50%)
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 400_000_000) == 1_000_000_000, 2);
        assert!(al::get_ember_share_fee_multiplier_at(&vault, share_id, 600_000_000) == 2_000_000_000, 3);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidRequest)]
    fun remove_nonexistent_tier_aborts() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 1_000_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::remove_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 750_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidFeeMultiplier)]
    fun multiplier_below_one_x_aborts() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 1_000_000_000);

        // multiplier = 0.9x (below 1e9) — fees can only go UP via curve
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 500_000_000, 900_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidPercentage)]
    fun set_tier_threshold_above_100_percent_aborts() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 1_000_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 1_500_000_000, 2_000_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ::ember_vaults::atomic_liquidity_vault::EInvalidPermission)]
    fun set_max_utilization_from_non_admin_aborts() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 1_000_000_000);

        test_scenario::next_tx(&mut sc, au::charlie());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_max_utilization<USDC>(
            &mut vault, &config, share_id, 100_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    fun whitelist_update_preserves_curve() {
        // Whitelist with a curve attached, then re-call set_ember_share_whitelist
        // (e.g., to change fee_percentage). The curve must survive.
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let share_id = whitelist_share(&mut sc, 600_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, share_id, 500_000_000, 2_000_000_000, test_scenario::ctx(&mut sc),
        );
        // Re-whitelist with different parameters.
        al::set_ember_share_whitelist<USDC>(
            &mut vault, &config, share_id, true,
            20_000_000,    // fee 2%
            500_000_000,   // capacity 50%
            50_000_000,    // holdback 5%
            700_000_000,   // max_util 70%
            0,             // min_swap_gross: dust floor disabled
            0,             // max_held_value_absolute: absolute cap disabled
            test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::get_ember_share_max_utilization(&vault, share_id) == 700_000_000, 1);
        assert!(al::get_ember_share_fee_multiplier_curve_length(&vault, share_id) == 1, 2);
        let (t, m) = al::get_ember_share_fee_multiplier_tier_at(&vault, share_id, 0);
        assert!(t == 500_000_000 && m == 2_000_000_000, 3);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    // === Audit-fix checks: solvency_margin view ===

    #[test]
    fun solvency_margin_reports_backing_and_claims() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        // Empty vault: 0 == 0, solvent.
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let (backing0, claims0, ok0) = al::solvency_margin(&vault);
        assert!(backing0 == 0 && claims0 == 0 && ok0, 100);
        test_scenario::return_shared(vault);

        // After a deposit: idle balance == TVL (rate 1e9, no accrued fee yet
        // because the fresh vault's `last_charged_at` == deposit time).
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let (backing1, claims1, ok1) = al::solvency_margin(&vault);
        assert!(backing1 == 100_000_000, 101);
        assert!(claims1 == 100_000_000, 102);
        assert!(ok1, 103);
        test_scenario::return_shared(vault);

        test_scenario::end(sc);
    }

    // === Audit-fix checks: EmberShareConfig new fields wired through ===

    #[test]
    fun whitelist_persists_min_swap_gross_and_max_held_value_absolute() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        let id = sui::object::id_from_address(@0xC0FFEE);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_whitelist<USDC>(
            &mut vault, &config, id,
            true,
            10_000_000,   // fee 1%
            500_000_000,  // capacity 50%
            50_000_000,   // holdback 5%
            600_000_000,  // max_util 60%
            123_456_789,  // min_swap_gross
            999_888_777,  // max_held_value_absolute
            test_scenario::ctx(&mut sc),
        );

        let (max_util, min_swap_gross, max_held_value_abs) =
            al::get_ember_share_limits(&vault, id);
        assert!(max_util == 600_000_000, 200);
        assert!(min_swap_gross == 123_456_789, 201);
        assert!(max_held_value_abs == 999_888_777, 202);

        // Re-whitelist with different values — both fields update in place.
        al::set_ember_share_whitelist<USDC>(
            &mut vault, &config, id,
            true, 10_000_000, 500_000_000, 50_000_000, 600_000_000,
            42,
            84,
            test_scenario::ctx(&mut sc),
        );
        let (_, m2, a2) = al::get_ember_share_limits(&vault, id);
        assert!(m2 == 42 && a2 == 84, 203);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    // === Audit-fix checks: receiver != @0 rejections ===

    // Redeem-shares with receiver @0x0 aborts with EInvalidReceiver (8032).
    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidReceiver)]
    fun redeem_shares_rejects_zero_receiver() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);

        test_scenario::next_tx(&mut sc, au::charlie());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let clk = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));
        let _r = al::redeem_shares<USDC>(
            &mut vault, &config, 10_000_000, @0x0, &clk, test_scenario::ctx(&mut sc),
        );
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    // Instant-withdraw with receiver @0x0 aborts with EInvalidReceiver (8032).
    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidReceiver)]
    fun instant_withdraw_rejects_zero_receiver() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        au::deposit(&mut sc, au::charlie(), 100_000_000);
        au::set_max_instant_withdraw_shares(&mut sc, 100_000_000_000);
        au::fund_vault_balance(&mut sc, 100_000_000);

        test_scenario::next_tx(&mut sc, au::charlie());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let clk = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));
        let _amt = al::instant_withdraw<USDC>(
            &mut vault, &config, 5_000_000, @0x0, &clk, test_scenario::ctx(&mut sc),
        );
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    // === Audit-fix M-2: holdback dust auto-lift cannot invert the haircut ===

    /// Calls `release_users_holdback` as the operator and returns
    /// `total_released`. Seeds `entries` (as `(receiver, amount)` pairs) onto
    /// the queue for `source_id` first, and pre-funds the vault so the payout
    /// split can't fail for balance reasons.
    fun release_seeded(
        sc: &mut test_scenario::Scenario,
        source_id: sui::object::ID,
        entries: vector<address>,
        amounts: vector<u64>,
        unwinding_percentage: u64,
    ): u64 {
        test_scenario::next_tx(sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        al::test_fund_balance<USDC>(&mut vault, 1_000_000_000);
        let mut i = 0;
        while (i < vector::length(&entries)) {
            al::test_enqueue_holdback<USDC>(
                &mut vault,
                source_id,
                *vector::borrow(&entries, i),
                *vector::borrow(&amounts, i),
                test_scenario::ctx(sc),
            );
            i = i + 1;
        };
        test_scenario::return_shared(vault);

        test_scenario::next_tx(sc, au::bob()); // operator
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(sc);
        let config = test_scenario::take_shared<ProtocolConfig>(sc);
        let clk = sui::clock::create_for_testing(test_scenario::ctx(sc));
        let (_processed, total_released) = al::release_users_holdback<USDC>(
            &mut vault, &config, source_id, unwinding_percentage, 100, &clk,
            test_scenario::ctx(sc),
        );
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        total_released
    }

    #[test]
    /// A low `unwinding_percentage` whose payout floors to zero must NOT pay a
    /// non-dust entry in full (the inversion M-2 flagged: 999 @ 0.001% → 0
    /// computed → used to pay 999). A genuine sub-dust entry in the same batch
    /// is still auto-lifted, so `total_released` counts only the dust one.
    fun release_low_unwinding_does_not_pay_nondust_in_full() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let source_id = sui::object::id_from_address(@0xC0FFEE);

        // 999 @ 0.001% (1e4) floors to 0 and exceeds HOLDBACK_DUST_UNITS (100)
        // → paid 0. 50 floors to 0 and is <= dust → auto-lifted to 50.
        let total = release_seeded(
            &mut sc, source_id,
            vector[au::charlie(), au::alice()],
            vector[999, 50],
            10_000, // 0.001%
        );
        assert!(total == 50, 1);
        test_scenario::end(sc);
    }

    #[test]
    /// `unwinding_percentage == 0` means "pay nothing / socialize the full
    /// loss" and must be honoured even for sub-dust entries — the auto-lift is
    /// suppressed entirely.
    fun release_zero_unwinding_pays_nothing() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let source_id = sui::object::id_from_address(@0xC0FFEE);

        let total = release_seeded(
            &mut sc, source_id,
            vector[au::charlie(), au::alice()],
            vector[10, 100], // both <= dust, would auto-lift at any nonzero pct
            0,
        );
        assert!(total == 0, 1);
        test_scenario::end(sc);
    }

    #[test]
    /// Sanity: a normal proportional haircut is unchanged by the fix.
    fun release_normal_haircut_pays_proportionally() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let source_id = sui::object::id_from_address(@0xC0FFEE);

        // 100_000_000 @ 50% → 50_000_000 (well above dust; no auto-lift).
        let total = release_seeded(
            &mut sc, source_id,
            vector[au::charlie()],
            vector[100_000_000],
            500_000_000, // 50%
        );
        assert!(total == 50_000_000, 1);
        test_scenario::end(sc);
    }

    #[test]
    /// A-3: on a partial drain, the release event's `new_queue_start_index`
    /// carries the queue HEAD (the consumed index), not the remaining count.
    /// Seed 10, release 3 → head is 3, remaining is 7 — they must differ, and
    /// the emitted value tracks the head.
    fun release_start_index_is_head_not_remaining() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let source_id = sui::object::id_from_address(@0xC0FFEE);

        // Seed 10 entries and fund the vault.
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        al::test_fund_balance<USDC>(&mut vault, 1_000_000_000);
        let mut i = 0;
        while (i < 10) {
            al::test_enqueue_holdback<USDC>(
                &mut vault, source_id, au::charlie(), 1_000_000, test_scenario::ctx(&mut sc),
            );
            i = i + 1;
        };
        test_scenario::return_shared(vault);

        // Operator releases 3 (partial drain).
        test_scenario::next_tx(&mut sc, au::bob());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let clk = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));
        let (processed, _released) = al::release_users_holdback<USDC>(
            &mut vault, &config, source_id, 1_000_000_000, 3, &clk, test_scenario::ctx(&mut sc),
        );
        sui::clock::destroy_for_testing(clk);

        assert!(processed == 3, 0);
        // Emitted start index == head == 3; remaining count is 7 — they diverge.
        assert!(al::test_get_holdback_queue_head<USDC>(&vault, source_id) == 3, 1);
        assert!(al::get_holdback_queue_length<USDC>(&vault, source_id) == 7, 2);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    // === Audit-fix M-3: amount-weighted anti-JIT deposit clock (receiver-keyed) ===

    #[test]
    /// A first (self) deposit records `now` as the receiver's clock.
    fun self_deposit_records_now() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        au::deposit_from_to_at_time(&mut sc, au::charlie(), au::charlie(), 1_000_000, 7_000_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::test_get_last_deposit_ts<USDC>(&vault, au::charlie()) == 7_000_000_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    /// Grief-resistance (original M-3): a third-party DUST deposit naming an
    /// already-aged victim as receiver moves the weighted clock only
    /// negligibly — it is NOT reset toward `now`, so the victim's aged shares
    /// stay aged. Victim deposits 1e9 shares at t0=1e9; attacker dust-deposits
    /// 1 unit to the victim at t1=9e9. Weighted ts stays ~t0, far below t1.
    fun dust_deposit_barely_moves_aged_receiver_clock() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        let victim = au::alice();
        let attacker = au::charlie();
        au::deposit_from_to_at_time(&mut sc, victim, victim, 1_000_000_000, 1_000_000_000);
        au::deposit_from_to_at_time(&mut sc, attacker, victim, 1 /* dust */, 9_000_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let ts = al::test_get_last_deposit_ts<USDC>(&vault, victim);
        // Barely moved from t0 (~+7 ms), nowhere near the attacker's t1 (9e9).
        assert!(ts >= 1_000_000_000 && ts < 2_000_000_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    /// Bypass closed (M-3 follow-up): a LARGE fresh top-up crediting an aged
    /// receiver ages the weighted clock forward, so the new shares can't inherit
    /// the old deposit's age to dodge the JIT fee. 1e9 shares at t0=1e9 then
    /// another 1e9 at t1=9e9 → weighted ts is the share-weighted midpoint, 5e9.
    fun fresh_topup_ages_weighted_clock_forward() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);

        let user = au::alice();
        au::deposit_from_to_at_time(&mut sc, user, user, 1_000_000_000, 1_000_000_000);
        au::deposit_from_to_at_time(&mut sc, user, user, 1_000_000_000, 9_000_000_000);

        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        assert!(al::test_get_last_deposit_ts<USDC>(&vault, user) == 5_000_000_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    #[test]
    /// M-3 follow-up: the weight includes shares already queued for withdrawal,
    /// so a dust deposit that front-runs process_withdrawal_requests can't reset
    /// the victim's clock. Victim deposits 1e9 at t0=1e9 then redeems ALL of it
    /// (shares leave `shares` for the pending-burn pool); an attacker then dusts
    /// the victim at t1=9e9. The weighted clock must stay ~t0, not reset to t1.
    fun dust_deposit_after_redeem_does_not_reset_clock() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let victim = au::charlie();
        let attacker = au::alice();

        // Victim deposits (self) at t0, establishing an aged clock.
        au::deposit_from_to_at_time(&mut sc, victim, victim, 1_000_000_000, 1_000_000_000);

        // Victim queues a withdrawal for all their shares — balance -> 0,
        // pending -> 1e9.
        test_scenario::next_tx(&mut sc, victim);
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let clk = sui::clock::create_for_testing(test_scenario::ctx(&mut sc));
        let _req = al::redeem_shares<USDC>(
            &mut vault, &config, 1_000_000_000, victim, &clk, test_scenario::ctx(&mut sc),
        );
        sui::clock::destroy_for_testing(clk);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);

        // Attacker front-runs with a 1-unit deposit naming the victim as receiver.
        au::deposit_from_to_at_time(&mut sc, attacker, victim, 1, 9_000_000_000);

        // Clock still ~t0 (queued shares kept the weight), far below the dust t1.
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let ts = al::test_get_last_deposit_ts<USDC>(&vault, victim);
        assert!(ts >= 1_000_000_000 && ts < 2_000_000_000, 1);
        test_scenario::return_shared(vault);
        test_scenario::end(sc);
    }

    // === Audit-fix L-5: fee ceilings on the atomic vault ===

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInstantWithdrawFeeTooHigh)]
    /// A 100% instant-withdraw fee is rejected (was `<= PERCENT_MAX`, now
    /// strictly `<`), so an instant withdraw can't burn shares for zero payout.
    fun instant_withdraw_fee_at_100pct_rejected() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_instant_withdraw_fee_percentage<USDC>(
            &mut vault, &config, 1_000_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidFeePercentage)]
    /// The atomic vault mirrors the 50% withdrawal-fee ceiling.
    fun alv_permanent_fee_above_cap_rejected() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_permanent_fee_percentage<USDC>(
            &mut vault, &config, 600_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidPercentage)]
    /// A 100% base swap fee is rejected at whitelist time (`< PERCENT_MAX`),
    /// matching the swap's effective-fee guard — otherwise it would brick every
    /// swap for that source.
    fun whitelist_rejects_100pct_base_swap_fee() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_whitelist<USDC>(
            &mut vault, &config, sui::object::id_from_address(@0xC0FFEE),
            true,
            1_000_000_000, // fee_percentage = 100% — must be rejected
            500_000_000,   // max_capacity_percentage
            0,             // holdback_percentage
            600_000_000,   // max_utilization_percentage
            0,             // min_swap_gross
            0,             // max_held_value_absolute
            test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    // === Audit-fix L-1 follow-up: reward-collection / exit role + pause alignment ===

    // === Audit-fix A-10: fee-multiplier curve validation ===
    // whitelist_share sets base fee = 1% (1e7), holdback = 5% (5e7).

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidFeeMultiplier)]
    /// A multiplier above MAX_FEE_MULTIPLIER (100x) is rejected.
    fun fee_tier_multiplier_above_max_rejected() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let id = whitelist_share(&mut sc, 1_000_000_000);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, id, 500_000_000, 200_000_000_000 /* 200x > max */, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidFeeMultiplier)]
    /// A tier whose effective fee (base*multiplier) + holdback exceeds 100% is
    /// rejected at set time instead of silently bricking swaps at that tier.
    /// base 1% * 100x = 100%; + 5% holdback = 105% > 100%.
    fun fee_tier_bricking_effective_fee_rejected() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let id = whitelist_share(&mut sc, 1_000_000_000);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, id, 500_000_000, 100_000_000_000 /* 100x */, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidFeeMultiplier)]
    /// Boundary: an effective fee of EXACTLY 100% with zero holdback passes the
    /// `effective + holdback <= 100%` bound but must be rejected by the strict
    /// `effective < 100%` bound that matches the swap guard. base 1% * 100x =
    /// 100%, holdback 0.
    fun fee_tier_effective_fee_at_100pct_rejected() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let id = sui::object::id_from_address(@0xFEE0);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        // Whitelist with base 1%, holdback 0 so only the strict effective-fee
        // bound can reject the tier.
        al::set_ember_share_whitelist<USDC>(
            &mut vault, &config, id,
            true, 10_000_000 /* 1% */, 500_000_000, 0 /* holdback 0 */, 1_000_000_000, 0, 0,
            test_scenario::ctx(&mut sc),
        );
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, id, 500_000_000, 100_000_000_000 /* 100x -> effective 100% */, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidFeeMultiplier)]
    /// A curve whose multipliers decrease with rising threshold is rejected.
    /// 3x at 50% then 2x at 80% (both individually valid on fee/holdback).
    fun fee_curve_non_monotonic_rejected() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let id = whitelist_share(&mut sc, 1_000_000_000);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, id, 500_000_000, 3_000_000_000, test_scenario::ctx(&mut sc),
        );
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, id, 800_000_000, 2_000_000_000, test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidFeeMultiplier)]
    /// The 21st tier (MAX_FEE_MULTIPLIER_TIERS = 20) is rejected. All tiers use
    /// the same 2x multiplier so only the length bound fires.
    fun fee_curve_max_tiers_enforced() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let id = whitelist_share(&mut sc, 1_000_000_000);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        let mut i = 0;
        while (i < 21) {
            al::set_ember_share_fee_multiplier_tier<USDC>(
                &mut vault, &config, id, i * 10_000_000, 2_000_000_000, test_scenario::ctx(&mut sc),
            );
            i = i + 1;
        };
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::atomic_liquidity_vault::EInvalidFeeMultiplier)]
    /// Re-whitelisting to raise the base fee is rejected when it would brick the
    /// preserved curve's top tier: a 90x tier is fine at base 1% (95% + ... ),
    /// but re-whitelisting at base 10% makes it 900% and is refused.
    fun whitelist_rebase_bricking_curve_rejected() {
        let mut sc = test_scenario::begin(au::protocol_admin());
        au::initialize(&mut sc);
        let id = whitelist_share(&mut sc, 1_000_000_000);
        test_scenario::next_tx(&mut sc, au::protocol_admin());
        let mut vault = test_scenario::take_shared<AtomicLiquidityVault<USDC>>(&sc);
        let config = test_scenario::take_shared<ProtocolConfig>(&sc);
        // 90x at 50%: base 1% * 90 = 90% + 5% holdback = 95% <= 100% — allowed.
        al::set_ember_share_fee_multiplier_tier<USDC>(
            &mut vault, &config, id, 500_000_000, 90_000_000_000, test_scenario::ctx(&mut sc),
        );
        // Re-whitelist raising the base fee to 10% — top tier now 900%, refused.
        al::set_ember_share_whitelist<USDC>(
            &mut vault, &config, id,
            true,
            100_000_000, // fee 10%
            500_000_000, // capacity
            50_000_000,  // holdback 5%
            1_000_000_000,
            0,
            0,
            test_scenario::ctx(&mut sc),
        );
        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::end(sc);
    }
}
