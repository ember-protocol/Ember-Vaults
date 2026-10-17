# Ember Vaults v10 — Test Coverage

| | |
|---|---|
| Release | v10, package `0xb82df65c5bae83c2f4c5eb4ec2fc57cc124b228cd9aef7a60ddb7d89c4e2b88e` |
| Source | commit [`dedb410`](https://github.com/ember-protocol/Ember-Vaults/commit/dedb4103200b81d276a62a4db6791a5e133446f6) |
| Toolchain | Sui CLI `mainnet-v1.80.1`, the toolchain that reproduces the deployed bytecode |
| Tests | 435 Move unit tests in `tests/`. All pass. |
| Generated | 2026-10-17 |

## Coverage (production code)

| File | Lines | Line coverage | Branches | Branch coverage |
|---|---:|---:|---:|---:|
| `sources/admin.move` | 113 / 116 | 97.41% | 95 / 103 | 92.23% |
| `sources/atomic_liquidity_vault.move` | 1184 / 1915 | 61.83% | 633 / 1136 | 55.72% |
| `sources/common.move` | 15 / 28 | 53.57% | 13 / 41 | 31.71% |
| `sources/events.move` | 139 / 163 | 85.28% | 0 / 0 | n/a |
| `sources/gateway.move` | 76 / 313 | 24.28% | 8 / 40 | 20.00% |
| `sources/math.move` | 25 / 29 | 86.21% | 16 / 19 | 84.21% |
| `sources/queue.move` | 26 / 26 | 100.00% | 10 / 10 | 100.00% |
| `sources/strategy.move` | 64 / 325 | 19.69% | 36 / 129 | 27.91% |
| `sources/vault.move` | 839 / 889 | 94.38% | 540 / 659 | 81.94% |
| **Total** | **2481 / 3804** | **65.22%** | **1351 / 2137** | **63.22%** |

Uncovered production lines are listed in [`uncovered-lines.md`](uncovered-lines.md).

Three files account for most of the gap:
- **`strategy.move`.** It calls Suilend through local interface stubs (`external_stubs/`) whose bodies `abort 0`. Any code after a Suilend call cannot run in a unit test. The checks that run before the call can, and are listed below.
- **`gateway.move`.** It contains entry-point wrappers that only delegate to `vault` and `atomic_liquidity_vault`. Tests call the module functions directly, so most wrappers are not executed.
- **`atomic_liquidity_vault.move`.** Several administrative setters and operator paths have no tests. They are listed below.

### How these numbers were produced

```sh
sui move test --coverage --trace
sui move coverage lcov                       # writes lcov.info
sui move coverage source --module <module>   # per-module covered/uncovered source
```

- **Lines.** A line is covered if `lcov.info` records a hit on it. It is uncovered if `sui move coverage source` marks code on it as uncovered and it has no hit.
- **Branches.** Branches come from the LCOV `BRDA` records.
- **Production code only.** Lines inside `#[test]` and `#[test_only]` items are excluded.
- **Raw data.** [`lcov.info`](lcov.info) is the CLI output limited to this package's `sources/`.

## Authorization checks and invariants → tests

A negative test counts only if it is `#[expected_failure]` with the abort code of the check itself. Every `#[expected_failure]` test in this suite names an abort code.

Test names are `<test file>::<function>`. Two test files declare a different module name: `test_admin.move` declares `tests_admin`, and `test_vault.move` declares `tests_vault`.

**Where column:** `A` = `sources/admin.move`, `V` = `sources/vault.move`, `ALV` = `sources/atomic_liquidity_vault.move`, `S` = `sources/strategy.move`, `C` = `sources/common.move`.

**Labels used in the tables:**
- **inline:** the check passes inside a test whose expected abort comes from a later check.
- **partial:** the authorized path runs up to a Suilend stub.
- **not testable (stub):** the check sits after a Suilend stub call.

`gateway.move` adds no checks of its own, so it has no rows. Capability-gated functions (`&AdminCap`) cannot be called without the capability object, which cannot be forged, so they have no runtime negative test.

### Authorization

| Check | Where | Positive test | Negative test | Notes |
|---|---|---|---|---|
| AdminCap (`_: &AdminCap`), protocol config | A:pause_non_admin_operations, set_guardian, increase_supported_package_version, update_platform_fee_recipient, update_min_rate, update_max_rate, update_default_rate, update_max_fee_percentage, update_min_rate_interval, update_max_rate_interval | test_admin::should_succeed_when_pausing_non_admin_operations, test_admin::should_set_and_get_guardian, test_admin::should_succeed_when_updating_platform_fee_recipient, test_admin::should_succeed_when_updating_min_rate, test_admin::should_succeed_when_updating_max_rate, test_admin::should_succeed_when_updating_default_rate, test_admin::should_succeed_when_updating_max_allowed_fee_percentage, test_admin::should_succeed_when_updating_min_rate_interval, test_admin::should_succeed_when_updating_max_rate_interval | N/A (type-level) | A `&AdminCap` cannot be forged in a test, so there is no runtime abort to assert. increase_supported_package_version has no positive; only the `_for_testing` bypass runs (test_admin::should_succeed_when_increasing_supported_package_version). |
| AdminCap, classic vault | V:create_vault, change_vault_admin | test_vault::should_create_vault, test_vault::should_update_vault_admin | N/A (type-level) | |
| AdminCap, atomic vault | ALV:create_atomic_liquidity_vault, change_vault_admin | test_atomic_liquidity_vault::should_create_atomic_vault_with_default_state; change_vault_admin: MISSING | N/A (type-level) | ALV:change_vault_admin is never called by any test. |
| Guardian (`verify_guardian`, `admin::EUnauthorized`) | A:guardian_pause_non_admin_operations | test_admin::should_allow_guardian_to_pause_non_admin_operations | test_admin::should_fail_when_non_guardian_calls_guardian_pause, test_admin::should_fail_guardian_pause_when_guardian_unset | Both the wrong-sender branch and the unset (`@0x0`) branch are covered. |
| Guardian | V:guardian_set_vault_paused_status | test_vault::should_pause_deposits_via_guardian_and_leave_others_unpaused | test_vault::should_fail_when_non_guardian_calls_guardian_vault_pause | |
| Guardian | V:guardian_set_blacklisted_account | test_vault::should_allow_guardian_to_blacklist_account, test_vault::guardian_blacklist_works_even_when_protocol_is_paused | MISSING | |
| Guardian | ALV:guardian_set_pause_status, ALV:guardian_set_blacklisted_account | MISSING | MISSING | Neither function is called by any test. |
| Vault admin (`sender == vault.admin`, `vault::EInvalidPermission`) | V:update_vault_rate_manager | test_integration_scenarios::test_admin_operations_sequence | MISSING | Also runs inside every `test_utils::initialize`. |
| Vault admin | V:update_vault_max_tvl | test_vault::should_successfully_update_vault_max_tvl | test_vault::should_fail_when_non_admin_tries_to_update_vault_max_tvl | |
| Vault admin | V:change_vault_rate_update_interval | test_vault::should_change_vault_rate_update_interval | test_vault::should_fail_to_change_vault_rate_update_interval_when_caller_is_not_admin | |
| Vault admin | V:change_vault_operator | test_vault::should_update_vault_operator | test_vault::should_fail_to_update_vault_operator_when_caller_is_not_admin | |
| Vault admin | V:update_vault_fee_percentage_v2 | test_vault::should_update_vault_fee_percentage | test_vault::should_fail_when_non_admin_tries_to_update_vault_fee_percentage | |
| Vault admin | V:set_vault_paused_status | test_vault::should_update_vault_paused_status | test_vault::should_fail_to_update_vault_paused_status_when_caller_is_not_vault_admin, test_gateway::test_gateway_unauthorized_vault_admin_function | |
| Vault admin | V:set_sub_account | test_vault::should_add_a_new_sub_account | test_vault::should_fail_to_update_sub_account_when_caller_is_not_vault_admin | |
| Vault admin | V:set_min_withdrawal_shares | test_vault::should_set_min_withdrawal_shares | test_vault::should_fail_when_non_admin_sets_min_withdrawal_shares | |
| Vault admin | V:update_vault_max_rate_change_per_update | test_vault::should_update_max_rate_change_per_update | test_vault::should_fail_to_update_max_rate_change_per_update_when_caller_is_not_admin, test_vault::should_fail_to_update_max_rate_change_per_update_when_caller_is_operator, test_vault::should_fail_to_update_max_rate_change_per_update_when_caller_is_random_user | |
| Vault admin | V:set_permanent_fee_percentage | test_withdrawal_fees::test_set_permanent_fee_percentage | test_withdrawal_fees::test_set_permanent_fee_percentage_fails_for_non_admin | |
| Vault admin | V:set_time_based_fee_percentage | test_withdrawal_fees::test_set_time_based_fee_percentage | test_withdrawal_fees::test_set_time_based_fee_percentage_fails_for_non_admin | |
| Vault admin | V:set_time_based_fee_threshold | test_withdrawal_fees::test_set_time_based_fee_threshold | test_withdrawal_fees::test_set_time_based_fee_threshold_fails_for_non_admin | |
| Vault admin | V:update_vault_name | MISSING | MISSING | Never called by any test. |
| Operator (`sender == vault.operator`) | V:collect_platform_fee_v2 | test_vault::should_collect_platform_fee | MISSING | |
| Operator | V:set_blacklisted_account | test_vault::should_add_a_new_black_listed_account | test_vault::should_fail_to_update_black_listed_accounts_when_caller_is_not_vault_operator | |
| Operator | V:withdraw_from_vault_without_redeeming_shares | test_vault::should_allow_vault_operator_to_withdraw_from_vault_without_redeeming_shares | test_vault::should_revert_when_non_vault_operator_tries_to_withdraw_from_vault_without_redeeming_shares | |
| Operator | V:deposit_coin_into_vault_without_minting_shares_internal (reached from deposit_to_vault_without_minting_shares v1/v2/v3) | test_vault::should_allow_vault_operator_to_deposit_to_vault_without_minting_shares (v1), test_vault::should_deposit_accumulator_balance_into_vault (v3) | test_vault::should_revert_when_non_vault_operator_tries_to_deposit_to_vault_without_minting_shares (v1), test_vault::should_revert_when_non_vault_operator_tries_to_deposit_accumulator_balance (v3) | v2 (TTO `Receiving`) is untested. |
| Operator | V:process_withdrawal_requests | test_process_withdrawal::test_process_withdrawal_request_single_request | test_process_withdrawal::test_process_withdrawal_request_unauthorized_caller | |
| Operator | V:process_withdrawal_requests_up_to_timestamp | test_process_withdrawal::test_process_withdrawal_request_up_to_timestamp | MISSING | |
| Operator | V:set_deposit_user_list | test_withdrawal_fees::test_deposit_succeeds_for_allowed_user | test_withdrawal_fees::test_set_deposit_user_list_fails_for_non_operator | |
| Operator | V:set_fee_exemption_list | test_withdrawal_fees::test_set_fee_exemption_list_add_user | test_withdrawal_fees::test_set_fee_exemption_list_fails_for_non_operator | |
| Rate manager (the rate-manager DF equals the sender) | V:update_vault_rate | test_vault::should_update_vault_rate | test_vault::should_fail_to_update_vault_rate_when_caller_is_not_operator, test_gateway::test_gateway_unauthorized_vault_operator_function | The first negative is misnamed: it tests the rate-manager check (sender `@0x123`), not the operator. |
| Request owner (the sender has an account and owns the sequence number) | V:cancel_pending_withdrawal_request | test_vault::should_cancel_pending_withdrawal_request | test_vault::should_fail_when_wrong_user_tries_to_cancel_request (EUserDoesNotHaveAccount), test_vault::should_fail_when_user_tries_to_cancel_another_users_request (EInvalidRequest) | |
| `assert_admin` (`atomic_liquidity_vault::EInvalidPermission`) | ALV:update_vault_fee_percentage | MISSING | test_atomic_liquidity_vault::should_reject_admin_setter_from_non_admin | |
| assert_admin | ALV:set_ember_share_max_utilization | test_atomic_liquidity_vault::set_max_utilization_updates_the_cap | test_atomic_liquidity_vault::set_max_utilization_from_non_admin_aborts | |
| assert_admin | ALV:set_pause_status | test_atomic_liquidity_vault::should_pause_each_operation_independently | MISSING | |
| assert_admin | ALV:set_max_instant_withdraw_shares | test_atomic_liquidity_vault::should_burn_shares_and_pay_net_amount_on_instant_withdraw | MISSING | |
| assert_admin | ALV:set_instant_withdraw_fee_percentage | test_atomic_liquidity_vault::should_charge_instant_withdraw_fee_to_platform_fee_accrual | MISSING | |
| assert_admin | ALV:set_ember_share_whitelist | test_atomic_liquidity_vault::whitelist_initialises_max_utilization_and_empty_curve | MISSING | |
| assert_admin | ALV:set_ember_share_fee_multiplier_tier, remove_ember_share_fee_multiplier_tier | test_atomic_liquidity_vault::fee_multiplier_curve_step_function_lookup, test_atomic_liquidity_vault::remove_tier_drops_the_row | MISSING | |
| assert_admin | ALV:set_permanent_fee_percentage, set_time_based_fee_percentage, set_time_based_fee_threshold | test_atomic_liquidity_vault::should_charge_permanent_fee_on_processed_withdrawal, test_atomic_liquidity_vault::should_charge_time_based_fee_when_within_threshold | MISSING | |
| assert_admin | ALV:set_min_withdrawal_shares | inline: test_atomic_liquidity_vault::should_reject_redeem_below_min_withdrawal_shares | MISSING | |
| assert_admin | ALV:set_sub_account | inline: test_atomic_liquidity_vault::suilend_accepts_the_committed_market | MISSING | |
| assert_admin | ALV:set_strategy_suilend | test_atomic_liquidity_vault::should_allow_suilend_activation_on_sui_vault | MISSING | |
| assert_admin | ALV:set_strategy_none_from_suilend | test_atomic_liquidity_vault::suilend_accepts_the_committed_market | MISSING | Only the no-obligation branch is covered. |
| assert_admin | ALV:set_strategy_none_from_suilend_sui | MISSING | MISSING | Not stub-blocked: on a `Vault<SUI>` with no obligation it never enters Suilend. |
| assert_admin | ALV:update_vault_name, update_vault_max_tvl, update_vault_max_rate_change_per_update, change_vault_rate_update_interval, change_vault_operator, update_vault_rate_manager, set_swap_waiver | MISSING | MISSING | None of these is called by any test. |
| `assert_operator` | ALV:set_fee_exemption_list | test_atomic_liquidity_vault::should_skip_permanent_fee_for_exempt_user | test_atomic_liquidity_vault::should_reject_fee_exemption_from_non_operator | The negative calls as the vault admin. |
| assert_operator | ALV:set_blacklisted_account | inline: test_atomic_liquidity_vault::should_reject_deposit_from_blacklisted_user | MISSING | |
| assert_operator | ALV:assert_deposit_from_sub_account_allowed (deposit_from_sub_account, deposit_from_sub_account_v2) | MISSING | test_atomic_liquidity_vault::should_reject_accumulator_deposit_from_non_operator (v2) | v1 is untested. The test file notes the v2 happy path cannot be built in test_scenario. |
| assert_operator | ALV:process_withdrawal_requests | test_atomic_liquidity_vault::should_burn_shares_and_pay_collateral_on_process | MISSING | |
| assert_operator | ALV:release_users_holdback | test_atomic_liquidity_vault::release_normal_haircut_pays_proportionally | MISSING | |
| assert_operator | ALV:redeem_collected_ember_shares | test_atomic_utilization_scenarios::redeem_twice_same_source_ok | MISSING | |
| assert_operator | ALV:withdraw_from_suilend_strategy | partial: test_atomic_liquidity_vault::suilend_withdraw_before_enrolment_reports_the_missing_obligation; full success is not testable (stub) | MISSING | The auth check runs before the stub, so a negative is testable. |
| assert_operator | ALV:supply_to_suilend_strategy, withdraw_from_suilend_strategy_sui | not testable (stub) | MISSING | The auth check runs before the stub, so a negative is testable. |
| assert_operator | ALV:supply_to_sub_account, collect_platform_fee, process_withdrawal_requests_up_to_timestamp, set_deposit_user_list, claim_received_collateral, claim_returned_ember_shares | MISSING | MISSING | None of these is called by any test. |
| `assert_admin_or_operator` | ALV:open_suilend_obligation | not testable (stub) | test_atomic_liquidity_vault::open_suilend_obligation_rejects_an_untrusted_sender | |
| assert_admin_or_operator | ALV:claim_suilend_strategy_reward | partial (operator): test_atomic_liquidity_vault::suilend_reward_claim_requires_an_open_obligation; full success is not testable (stub) | test_atomic_liquidity_vault::collect_reward_rejects_non_admin_non_operator | No test exercises the admin branch of the admin-or-operator check. |
| assert_admin_or_operator | ALV:withdraw_suilend_secondary_collateral, withdraw_suilend_secondary_collateral_sui | not testable (stub) | MISSING | |
| `assert_rate_manager` | ALV:update_vault_rate | MISSING | MISSING | Never called by any test. |
| Request owner | ALV:cancel_pending_withdrawal_request | test_atomic_liquidity_vault::should_skip_and_return_shares_on_processed_cancellation | MISSING | |
| Sub-account whitelist on outflow (`EInvalidAccount`) | V:withdraw_from_vault_without_redeeming_shares | test_vault::should_allow_vault_operator_to_withdraw_from_vault_without_redeeming_shares | test_vault::should_fail_to_withdraw_without_redeeming_shares_to_non_sub_account | |
| Sub-account whitelist on inflow attribution | V:deposit_coin_into_vault_without_minting_shares_internal | test_vault::should_allow_vault_operator_to_deposit_to_vault_without_minting_shares | test_vault::should_fail_to_deposit_to_vault_without_minting_shares_from_non_sub_account (v1), test_vault::should_fail_to_deposit_accumulator_balance_from_non_sub_account (v3) | |
| Sub-account whitelist on outflow | ALV:supply_to_sub_account | MISSING | MISSING | |
| Sub-account whitelist on inflow | ALV:assert_deposit_from_sub_account_allowed | MISSING | test_atomic_liquidity_vault::should_reject_accumulator_deposit_for_unregistered_sub_account | |
| Sub-account whitelist on reward recipient | ALV:claim_suilend_strategy_reward | partial: test_atomic_liquidity_vault::suilend_reward_claim_requires_an_open_obligation | test_atomic_liquidity_vault::suilend_reward_claim_rejects_a_non_sub_account_recipient | |
| Sub-account whitelist on recipient | ALV:withdraw_suilend_secondary_collateral, withdraw_suilend_secondary_collateral_sui | not testable (stub) | MISSING | |
| Non-empty sub-account list before strategy exit (`ENoRewardDestination`) | ALV:set_strategy_none_from_suilend, set_strategy_none_from_suilend_sui | test_atomic_liquidity_vault::suilend_accepts_the_committed_market | test_atomic_liquidity_vault::suilend_exit_is_blocked_when_no_reward_destination_exists | The `_sui` variant is untested. |
| Deposit allowlist (`EDepositNotAllowed`) | V:deposit_asset_v2 | test_withdrawal_fees::test_deposit_succeeds_for_allowed_user | test_withdrawal_fees::test_deposit_fails_for_non_allowed_user | |
| Deposit allowlist | V:mint_shares_v2 | MISSING | MISSING | |
| Deposit allowlist | ALV:deposit | MISSING | MISSING | ALV:set_deposit_user_list is never called by any test. |
| Blacklist (sender) | V:deposit_asset_v2 | test_deposit::should_allow_deposit_after_user_is_removed_from_blacklist | test_deposit::should_fail_when_blacklisted_user_tries_to_deposit | |
| Blacklist (sender) | V:mint_shares_v2 | test_mint::should_allow_mint_shares_after_user_is_removed_from_blacklist | test_mint::should_fail_when_blacklisted_user_tries_to_mint_shares | |
| Blacklist (owner, receiver) | V:redeem_shares_for_owner | test_redeem::should_redeem_shares_from_vault | owner: test_redeem::should_fail_if_user_is_blacklisted; receiver: MISSING | |
| Blacklist (depositor, receiver) | ALV:deposit | test_atomic_liquidity_vault::should_deposit_and_credit_internal_shares | depositor: test_atomic_liquidity_vault::should_reject_deposit_from_blacklisted_user; receiver: MISSING | |
| Blacklist (owner, receiver) | ALV:redeem_shares, do_instant_withdraw_core | test_atomic_liquidity_vault::should_park_shares_in_pending_burn_on_redeem_request, test_atomic_liquidity_vault::should_burn_shares_and_pay_net_amount_on_instant_withdraw | MISSING | |
| Blacklist (owner, receiver; the atomic vault's own address on the source vault, M-02) | ALV:do_swap_ember_shares_core | test_atomic_utilization_scenarios::swap_meets_exact_min_net_out | MISSING | |
| A blacklisted account cannot become a sub-account (`EBlacklistedAccount`) | V:set_sub_account | test_vault::should_add_a_new_sub_account | test_vault::should_fail_to_add_blacklisted_account_as_sub_account | |
| A blacklisted account cannot become a sub-account | ALV:set_sub_account | inline: test_atomic_liquidity_vault::suilend_accepts_the_committed_market | MISSING | |
| A sub-account cannot be blacklisted (`EInvalidAccount`) | V:set_blacklisted_account | test_vault::should_add_a_new_black_listed_account | test_vault::should_fail_to_blacklist_sub_account | |
| A sub-account cannot be blacklisted | V:guardian_set_blacklisted_account, ALV:set_blacklisted_account_internal | test_vault::should_allow_guardian_to_blacklist_account | MISSING | |
| A blacklisted user cannot be put on the deposit list or the fee-exempt list (`EBlacklistedAccount`) | V:set_deposit_user_list, V:set_fee_exemption_list, ALV:set_deposit_user_list, ALV:set_fee_exemption_list | test_withdrawal_fees::test_set_fee_exemption_list_add_user | MISSING | |
| A sub-account cannot deposit (`ESubAccount`) | V:deposit_asset_v2, V:mint_shares_v2 | test_deposit::should_succeed_when_deposit_slippage_within_tolerance | test_deposit::should_fail_when_sub_account_tries_to_deposit_assets, test_mint::should_fail_when_sub_account_tries_to_mint_shares | |
| A sub-account cannot deposit | ALV:deposit (depositor and receiver) | test_atomic_liquidity_vault::should_deposit_and_credit_internal_shares | MISSING | |
| Role distinctness: admin ≠ operator, both ≠ @0, both ∉ sub_accounts (`EInvalidAccount`) | V:create_vault | test_vault::should_create_vault | MISSING | Only the sub-account zero/duplicate loop is tested (see Table 2). |
| Role distinctness (`EInvalidAccount`) | V:change_vault_admin | test_vault::should_update_vault_admin | test_vault::should_fail_to_update_vault_admin_to_zero_address, test_vault::should_fail_to_update_vault_admin_to_current_admin_address | Collisions with operator, rate manager, sub-account and blacklist are MISSING. |
| Role distinctness | V:change_vault_operator | test_vault::should_update_vault_operator | test_vault::should_fail_to_update_vault_operator_to_zero_address, test_vault::should_fail_to_update_vault_operator_to_current_operator_address | Collisions with admin, rate manager, sub-account and blacklist are MISSING. |
| Role distinctness (`ESameValue` and `EInvalidAccount`) | V:update_vault_rate_manager | test_integration_scenarios::test_admin_operations_sequence | MISSING | |
| Role distinctness (account ≠ admin, operator, rate manager) | V:set_sub_account, V:set_deposit_user_list, V:set_fee_exemption_list | test_vault::should_add_a_new_sub_account | MISSING | |
| Role distinctness (admin, operator and rate manager ≠ @0, pairwise distinct, ∉ sub_accounts) | ALV:create_atomic_liquidity_vault | test_atomic_liquidity_vault::should_create_atomic_vault_with_default_state | MISSING | |
| Role distinctness (`common::assert_role_candidate_valid` → `common::ERoleConflict`) | ALV:change_vault_admin, change_vault_operator, update_vault_rate_manager | MISSING | MISSING | No test references `ERoleConflict`. |
| Role distinctness (account ≠ admin, operator, rate manager) | ALV:set_sub_account, set_fee_exemption_list, set_deposit_user_list | inline: test_atomic_liquidity_vault::suilend_accepts_the_committed_market | MISSING | |

### Invariants

| Check | Where | Positive test | Negative test | Notes |
|---|---|---|---|---|
| Version gate (helper) | A:verify_supported_package | test_admin::should_pass_when_verifying_supported_package | test_admin::should_fail_when_verifying_supported_package | |
| Version gate at call sites | A:update_platform_fee_recipient, A:guardian_pause_non_admin_operations | test_admin::should_succeed_when_updating_platform_fee_recipient | test_admin::admin_config_setter_aborts_from_retired_package, test_admin::guardian_pause_aborts_from_retired_package | |
| Version gate at call sites | every public function in V and ALV | (normal-path tests) | MISSING | No `EUnsupportedPackage` test touches vault.move or atomic_liquidity_vault.move. |
| Version only moves forward (`EPackageAlreadySupported`) | A:increase_supported_package_version | not reachable (`config.version == VERSION` at init) | test_admin::should_fail_when_increasing_supported_package_version | `admin::VERSION = 6` in this export. |
| Protocol pause (helper) | A:verify_protocol_not_paused | test_admin::should_succeed_when_pausing_non_admin_operations | test_admin::should_fail_when_protocol_is_paused | |
| Protocol pause at classic call sites | V:deposit_asset_v2, mint_shares_v2, redeem_shares_for_owner, cancel_pending_withdrawal_request, update_vault_rate, collect_platform_fee_v2, set_blacklisted_account, withdraw_from_vault_without_redeeming_shares, deposit_coin_into_vault_without_minting_shares_internal, change_vault_rate_update_interval, update_vault_max_rate_change_per_update | (normal-path tests) | test_deposit::should_fail_to_deposit_when_protocol_is_paused, test_mint::should_fail_to_mint_shares_when_protocol_is_paused, test_redeem::should_fail_if_protocol_is_paused, test_vault::should_fail_to_cancel_withdrawal_request_when_protocol_is_paused, test_vault::should_fail_to_update_vault_rate_when_protocol_is_paused, test_vault::should_fail_to_collect_platform_fee_when_protocol_is_paused, test_vault::should_fail_to_update_black_listed_accounts_when_protocol_is_paused, test_vault::should_revert_when_trying_to_withdraw_without_redeeming_shares_when_protocol_is_paused, test_vault::should_revert_when_trying_to_deposit_to_vault_without_minting_shares_when_protocol_is_paused, test_vault::should_fail_to_change_vault_rate_update_interval_when_protocol_is_paused, test_vault::should_fail_to_update_max_rate_change_per_update_when_protocol_is_paused | |
| Protocol pause at classic call sites | V:process_withdrawal_requests, process_withdrawal_requests_up_to_timestamp, update_vault_name, set_deposit_user_list, set_fee_exemption_list, set_permanent_fee_percentage, set_time_based_fee_percentage, set_time_based_fee_threshold | (normal-path tests) | MISSING | |
| The guardian blacklist bypasses protocol pause (by design) | V:guardian_set_blacklisted_account | test_vault::guardian_blacklist_works_even_when_protocol_is_paused | n/a | |
| Protocol pause at atomic call sites | every `verify_protocol_not_paused` call in ALV | (normal-path tests) | MISSING | No atomic test pauses the protocol. |
| Deposits pause (`EVaultPaused`; the legacy bit OR the per-operation DF) | V:verify_deposits_not_paused, called from deposit_asset_v2 and mint_shares_v2 | test_deposit::should_succeed_when_deposit_slippage_within_tolerance | legacy bit: test_deposit::should_fail_to_deposit_when_vault_is_paused, test_mint::should_fail_to_mint_shares_when_vault_is_paused; per-operation DF: MISSING | |
| Withdrawals pause | V:verify_withdrawals_not_paused, called from redeem_shares_for_owner, cancel_pending_withdrawal_request, process_withdrawal_requests, process_withdrawal_requests_up_to_timestamp | test_redeem::should_redeem_shares_from_vault | legacy bit: test_redeem::should_fail_if_vault_is_paused, test_vault::should_fail_to_cancel_withdrawal_request_when_vault_is_paused; both process functions: MISSING; per-operation DF: MISSING | |
| Privileged pause | V:verify_privileged_operations_not_paused, called from update_vault_rate, collect_platform_fee_v2, withdraw_from_vault_without_redeeming_shares, deposit_coin_into_vault_without_minting_shares_internal | test_vault::should_collect_platform_fee | per-operation DF: test_vault::privileged_pause_blocks_operator_privileged_operation (collect_platform_fee_v2 only); the other call sites are MISSING | |
| Pause readers OR in the legacy bit | V:is_deposits_paused, is_withdrawals_paused, is_privileged_operations_paused | test_vault::legacy_paused_bit_gates_all_three_operations | n/a | |
| Pause setters reject bad input (`EInvalidPauseOperation`, `EInvalidStatus`) | V:set_operation_paused_internal, V:set_vault_paused_status, ALV:set_pause_status_internal | test_vault::should_toggle_per_op_flags_independently, test_atomic_liquidity_vault::should_pause_each_operation_independently | test_vault::should_fail_guardian_pause_on_invalid_operation_string, test_vault::should_fail_guardian_pause_on_same_value, test_vault::should_fail_to_update_vault_paused_status_when_status_is_already_set, test_atomic_liquidity_vault::should_reject_pause_op_with_unknown_string | `EInvalidStatus` on the atomic vault is MISSING. |
| Atomic deposits pause (`EOperationPaused`) | ALV:deposit | test_atomic_liquidity_vault::should_deposit_and_credit_internal_shares | test_atomic_liquidity_vault::should_reject_deposit_when_deposits_paused | |
| Atomic withdrawals pause | ALV:redeem_shares, cancel_pending_withdrawal_request, process_withdrawal_requests, process_withdrawal_requests_up_to_timestamp, do_instant_withdraw_core, do_swap_ember_shares_core | (normal-path tests) | MISSING | |
| Atomic privileged pause | ALV:set_strategy_none_from_suilend, plus update_vault_rate, supply_to_sub_account, deposit_from_sub_account(_v2), collect_platform_fee, open_suilend_obligation, supply/withdraw Suilend, claim reward, secondary collateral, release_users_holdback, redeem_collected_ember_shares, claim_received_collateral, claim_returned_ember_shares, set_strategy_none_from_suilend_sui | test_atomic_liquidity_vault::suilend_accepts_the_committed_market | test_atomic_liquidity_vault::suilend_exit_is_blocked_while_privileged_operations_are_paused (set_strategy_none_from_suilend only); all other call sites MISSING | |
| Max TVL on deposit and mint (`EMaxTVLReached`) | V:deposit_asset_v2, V:mint_shares_v2 | test_deposit::should_succeed_when_deposit_slippage_within_tolerance | test_deposit::should_fail_to_deposit_asset_when_max_tvl_is_reached, test_mint::should_fail_to_mint_shares_when_max_tvl_is_reached | |
| Max TVL setter (> 0 and ≥ current TVL) | V:update_vault_max_tvl | test_vault::should_succeed_when_setting_max_tvl_above_current_tvl | test_vault::should_fail_when_trying_to_set_max_tvl_to_zero, test_vault::should_fail_when_trying_to_set_max_tvl_below_current_tvl | |
| max_tvl > 0 at creation | V:create_vault | test_vault::should_create_vault | test_vault::should_fail_when_creating_vault_with_zero_max_tvl | |
| Max TVL | ALV:deposit, ALV:update_vault_max_tvl, ALV:create_atomic_liquidity_vault | test_atomic_liquidity_vault::should_deposit_and_credit_internal_shares | MISSING | ALV:update_vault_max_tvl is never called by any test. |
| Min withdrawal shares (`EInsufficientShares`) | V:redeem_shares_for_owner | test_vault::should_succeed_redeem_when_shares_meet_minimum | test_vault::should_fail_redeem_when_shares_below_minimum, test_redeem::should_fail_if_redeem_shares_is_less_than_min_withdrawal_shares | |
| Min withdrawal shares > 0 | V:set_min_withdrawal_shares (`EZeroAmount`); V:create_vault (`EInvalidAmount`) | test_vault::should_set_min_withdrawal_shares | setter: test_vault::should_fail_when_setting_min_withdrawal_shares_to_zero; create: MISSING | |
| Min withdrawal shares | ALV:redeem_shares | test_atomic_liquidity_vault::should_park_shares_in_pending_burn_on_redeem_request | test_atomic_liquidity_vault::should_reject_redeem_below_min_withdrawal_shares | |
| Min withdrawal shares | ALV:do_instant_withdraw_core; ALV:set_min_withdrawal_shares (> 0); ALV create (> 0) | test_atomic_liquidity_vault::should_burn_shares_and_pay_net_amount_on_instant_withdraw | MISSING | |
| Protocol rate bounds (`EInvalidRate`) | A:update_min_rate, update_max_rate, update_default_rate | test_admin::should_succeed_when_updating_min_rate, test_admin::should_succeed_when_updating_max_rate, test_admin::should_succeed_when_updating_default_rate | test_admin::should_fail_when_updating_min_rate_to_zero, test_admin::should_fail_when_updating_min_rate_to_greater_than_max_rate, test_admin::should_fail_when_updating_min_rate_to_greater_than_default_rate, test_admin::should_fail_when_updating_max_rate_to_less_than_min_rate, test_admin::should_fail_when_updating_max_rate_to_less_than_default_rate, test_admin::should_fail_when_updating_default_rate_to_less_than_min_rate, test_admin::should_fail_when_updating_default_rate_to_greater_than_max_rate | |
| Protocol rate-interval bounds (`EInvalidRateInterval`) | A:update_min_rate_interval, update_max_rate_interval | test_admin::should_succeed_when_updating_min_rate_interval, test_admin::should_succeed_when_updating_max_rate_interval | test_admin::should_fail_when_updating_min_rate_interval_below_one_minute, test_admin::should_fail_when_updating_min_rate_interval_above_max_rate_interval, test_admin::should_fail_when_updating_max_rate_interval_below_min_rate_interval | The `max_rate_interval > MAX_RATE_INTERVAL` (1 day) clause is MISSING. |
| Rate within [min, max] and change ≤ max_rate_change_per_update (`EInvalidRate`) | V:update_vault_rate | test_vault::should_update_vault_rate | test_vault::should_fail_to_update_vault_rate_when_rate_is_greater_than_max_rate, test_vault::should_fail_to_update_vault_rate_when_rate_is_less_than_min_rate, test_vault::should_fail_to_update_vault_rate_when_rate_is_greater_than_max_rate_change_per_update | |
| Rate update interval has elapsed (`EInvalidInterval`) | V:update_vault_rate | test_vault::should_update_vault_rate | test_vault::should_fail_to_update_vault_rate_when_interval_is_not_met | |
| max_rate_change_per_update ∈ (0, 1e9) (`EInvalidAmount`) | V:update_vault_max_rate_change_per_update, V:create_vault | test_vault::should_update_max_rate_change_per_update, test_vault::should_create_vault | test_vault::should_fail_to_update_max_rate_change_per_update_to_zero, test_vault::should_fail_to_update_max_rate_change_per_update_to_100_percent, test_vault::should_fail_to_update_max_rate_change_per_update_above_100_percent, test_vault::should_fail_when_creating_vault_with_zero_max_rate_change, test_vault::should_fail_when_creating_vault_with_unbounded_max_rate_change | |
| rate_update_interval ∈ [min, max] (`EInvalidInterval`) | V:change_vault_rate_update_interval, V:create_vault | test_vault::should_handle_edge_case_interval_values | setter: test_vault::should_fail_to_change_vault_rate_update_interval_to_zero; create: MISSING | |
| Rate bounds, rate change and interval; the max-change and interval setters; creation | ALV:update_vault_rate, update_vault_max_rate_change_per_update, change_vault_rate_update_interval, create_atomic_liquidity_vault | MISSING | MISSING | None of these setters is called by any test. |
| Protocol max fee < 100% (`EInvalidFeePercentage`) | A:update_max_fee_percentage | test_admin::should_succeed_when_updating_max_allowed_fee_percentage | test_admin::should_fail_when_updating_max_allowed_fee_percentage_to_greater_than_equal_to_100_percent | |
| Platform fee ≤ protocol max | V:update_vault_fee_percentage_v2; V:create_vault | test_vault::should_update_vault_fee_percentage | setter: test_vault::should_fail_to_update_vault_fee_percentage_when_fee_percentage_is_greater_than_max_allowed_fee_percentage; create: MISSING | |
| Platform fee ≤ protocol max | ALV:update_vault_fee_percentage, ALV:create_atomic_liquidity_vault | MISSING | MISSING | |
| Withdrawal fees ≤ 50% each and combined | V:set_permanent_fee_percentage, V:set_time_based_fee_percentage | test_withdrawal_fees::fee_at_cap_allowed | test_withdrawal_fees::permanent_fee_above_cap_rejected (permanent alone), test_withdrawal_fees::combined_fee_above_cap_rejected (the sum, checked in set_permanent) | The time-based individual cap and the sum check inside set_time_based are MISSING. |
| Withdrawal fees ≤ 50% each and combined | ALV:set_permanent_fee_percentage, ALV:set_time_based_fee_percentage | test_atomic_liquidity_vault::should_stack_permanent_and_time_based_fees | test_atomic_liquidity_vault::alv_permanent_fee_above_cap_rejected, test_atomic_liquidity_vault::should_reject_permanent_fee_at_or_above_100_percent (permanent alone) | The sum and the time-based individual cap are MISSING. |
| Instant-withdraw fee < 100% (`EInstantWithdrawFeeTooHigh`) | ALV:set_instant_withdraw_fee_percentage | test_atomic_liquidity_vault::should_charge_instant_withdraw_fee_to_platform_fee_accrual | test_atomic_liquidity_vault::instant_withdraw_fee_at_100pct_rejected, test_atomic_liquidity_vault::should_reject_instant_withdraw_fee_above_100_percent | |
| EmberShare whitelist bounds: fee < 100%; capacity, holdback and utilization ≤ 100%; fee + holdback ≤ 100% (`EInvalidPercentage`) | ALV:set_ember_share_whitelist | test_atomic_liquidity_vault::whitelist_initialises_max_utilization_and_empty_curve | test_atomic_liquidity_vault::whitelist_rejects_100pct_base_swap_fee | Only the base-fee clause is covered; the other clauses are MISSING. |
| Max utilization ≤ 100% | ALV:set_ember_share_max_utilization | test_atomic_liquidity_vault::set_max_utilization_updates_the_cap | test_atomic_liquidity_vault::set_max_utilization_above_100_percent_aborts | |
| Fee curve: threshold ≤ 100%; multiplier in [1x, MAX]; effective fee < 100%; effective fee + holdback ≤ 100%; ≤ 20 tiers; monotonic; re-validated on re-whitelist | ALV:set_ember_share_fee_multiplier_tier, assert_fee_curve_monotonic, set_ember_share_whitelist | test_atomic_liquidity_vault::fee_multiplier_curve_step_function_lookup, test_atomic_liquidity_vault::whitelist_update_preserves_curve | test_atomic_liquidity_vault::set_tier_threshold_above_100_percent_aborts, test_atomic_liquidity_vault::multiplier_below_one_x_aborts, test_atomic_liquidity_vault::fee_tier_multiplier_above_max_rejected, test_atomic_liquidity_vault::fee_tier_effective_fee_at_100pct_rejected, test_atomic_liquidity_vault::fee_tier_bricking_effective_fee_rejected, test_atomic_liquidity_vault::fee_curve_max_tiers_enforced, test_atomic_liquidity_vault::fee_curve_non_monotonic_rejected, test_atomic_liquidity_vault::whitelist_rebase_bricking_curve_rejected | |
| At swap time: effective fee < 100% and fee + holdback ≤ gross | ALV:do_swap_ember_shares_core | (swap positives) | MISSING | Defence-in-depth; unreachable given the setter checks above. |
| Holdback unwinding ≤ 100% (`EInvalidPercentage`) | ALV:release_users_holdback | test_atomic_liquidity_vault::release_normal_haircut_pays_proportionally | MISSING | |
| Slippage: min_shares | V:deposit_asset_v2 | test_deposit::should_succeed_when_deposit_slippage_within_tolerance | test_deposit::should_fail_when_deposit_slippage_exceeds_min_shares | |
| Slippage: max_amount | V:mint_shares_v2 | test_mint::should_succeed_when_mint_shares_slippage_within_tolerance | test_mint::should_fail_when_mint_shares_slippage_exceeds_max_amount | |
| Slippage: min_shares | ALV:deposit | only `min_shares = 0` (test_atomic_liquidity_vault::should_deposit_and_credit_internal_shares) | test_atomic_liquidity_vault::should_reject_deposit_when_min_shares_not_met | There is no non-trivial positive. |
| Slippage: min_net_out | ALV:do_swap_ember_shares_core | test_atomic_utilization_scenarios::swap_meets_exact_min_net_out | test_atomic_utilization_scenarios::swap_slippage_guard_aborts_below_min_net_out | Hits the first assert. The second assert (after `pay_exact`) is redundant by design. |
| Instant-withdraw cumulative cap (`EInstantWithdrawCapExceeded`) | ALV:do_instant_withdraw_core | test_atomic_liquidity_vault::should_burn_shares_and_pay_net_amount_on_instant_withdraw | test_atomic_liquidity_vault::should_reject_instant_withdraw_above_cumulative_cap, test_atomic_liquidity_vault::should_advance_cumulative_across_multiple_calls_then_reject | |
| Owner share balance (`EInsufficientShares`) | ALV:redeem_shares | test_atomic_liquidity_vault::should_park_shares_in_pending_burn_on_redeem_request | test_atomic_liquidity_vault::should_reject_redeem_above_owner_balance | |
| Owner balance; idle liquidity (`EInsufficientBalance`) | ALV:do_instant_withdraw_core, ALV:instant_withdraw | test_atomic_liquidity_vault::should_burn_shares_and_pay_net_amount_on_instant_withdraw | MISSING | |
| Strategy-variant match (`EStrategyMismatch`) | ALV:instant_withdraw, ALV:open_suilend_obligation, and every other strategy-gated function | test_atomic_liquidity_vault::should_burn_shares_and_pay_net_amount_on_instant_withdraw | test_atomic_liquidity_vault::should_reject_no_strategy_variant_when_strategy_is_set, test_atomic_liquidity_vault::open_suilend_obligation_requires_the_suilend_strategy | The other call sites are MISSING: swap variants, set_strategy_suilend, set_strategy_none_*, Suilend supply/withdraw, claim, secondary collateral. |
| Swap source is configured and whitelisted (`EEmberShareNotWhitelisted`) | ALV:do_swap_ember_shares_core; also set_ember_share_max_utilization and set/remove tier on an unknown id | test_atomic_utilization_scenarios::swap_meets_exact_min_net_out | MISSING | |
| Swap rolling 24h capacity (`EEmberShareCapExceeded`) | ALV:do_swap_ember_shares_core | test_atomic_utilization_scenarios::scenario_walk_t0_through_t7 | MISSING | Every fixture sets capacity to 100%. |
| Swap utilization cap, measured after the swap (`EEmberShareUtilizationCapExceeded`) | ALV:do_swap_ember_shares_core | test_atomic_utilization_scenarios::scenario_walk_t0_through_t7 (eACRED lands exactly on its 20% cap) | test_atomic_utilization_scenarios::scenario_t2_eacred_at_max_aborts, test_atomic_utilization_scenarios::scenario_t7_eacred_over_max_aborts | |
| A zero utilization cap is a hard stop | ALV:do_swap_ember_shares_core | n/a | test_atomic_utilization_scenarios::swap_aborts_when_utilization_cap_is_zero | |
| Absolute held-value cap (`EEmberShareHeldValueCapExceeded`) | ALV:do_swap_ember_shares_core | partial: no swap runs under a non-zero cap; only cap = 0 (disabled) | test_atomic_utilization_scenarios::swap_rejected_when_aggregate_exposure_exceeds_cap | |
| Dust floor min_swap_gross (`EEmberShareSwapAmountTooSmall`) | ALV:do_swap_ember_shares_core | only with the floor at 0 (disabled) | MISSING | |
| Atomic vault TVL > 0 (`EZeroVaultTVL`) | ALV:do_swap_ember_shares_core | (swap positives) | MISSING | |
| Source vault withdrawals not paused (`ESourceVaultWithdrawalsPaused`) | ALV:do_swap_ember_shares_core | test_atomic_utilization_scenarios::swap_meets_exact_min_net_out | test_atomic_utilization_scenarios::swap_aborts_when_source_withdrawals_only_paused | Covers the per-operation DF path. |
| Immediate payout liquidity (`EInsufficientBalance`) | ALV:pay_exact | test_atomic_utilization_scenarios::swap_meets_exact_min_net_out | test_atomic_utilization_scenarios::scenario_t3_insufficient_liquidity_aborts | |
| Collected-share redemption: DF exists (`EInvalidRequest`); held ≥ amount (`EInsufficientBalance`); amount > 0 | ALV:redeem_collected_ember_shares | test_atomic_utilization_scenarios::redeem_twice_same_source_ok | MISSING | |
| Suilend market commitment (`ESuilendMarketMismatch`) | S:assert_suilend_market, reached via ALV:set_strategy_none_from_suilend → S:clear_suilend_state | test_atomic_liquidity_vault::suilend_accepts_the_committed_market | test_atomic_liquidity_vault::suilend_rejects_a_market_other_than_the_committed_one | The check runs before the stubs on every path. The other call sites (supply, withdraw, claim, secondary collateral, open) have no negative. |
| Suilend coin-type commitment (`ESuilendCoinTypeMismatch`) | S:assert_suilend_coin_type | test_atomic_liquidity_vault::suilend_accepts_the_committed_coin_type | test_atomic_liquidity_vault::suilend_rejects_a_coin_type_other_than_the_committed_one | Tested directly on a bare UID. |
| Reserve index matches the market (`ESuilendReserveIndexMismatch`) | S:assert_suilend_reserve_index | not testable (stub) | not testable (stub) | `reserve_array_index` aborts 0. |
| An obligation must exist (`ESuilendObligationMissing`) | S:claim_suilend_reward, withdraw_from_suilend, suilend_obligation_id | not testable (stub) | test_atomic_liquidity_vault::suilend_reward_claim_requires_an_open_obligation, test_atomic_liquidity_vault::suilend_withdraw_before_enrolment_reports_the_missing_obligation, test_atomic_liquidity_vault::get_suilend_obligation_id_aborts_before_enrolment | |
| An obligation is not already open (`ESuilendObligationAlreadyExists`) | S:open_suilend_obligation | not testable (stub) | not testable (stub) | |
| Strategy exit requires an empty obligation (`ESuilendResidualDeposit`) | S:drain_suilend_obligation | no-obligation branch only: test_atomic_liquidity_vault::suilend_accepts_the_committed_market | not testable (stub) | `obligation::deposits` and `lending_market::obligation` abort 0. |
| Generic redemption rejects T = SUI (`ESuilendSuiRequiresSuiPath`) | S:assert_suilend_not_sui | test_atomic_liquidity_vault::suilend_accepts_the_committed_market | MISSING | Testable: the check runs before the stubs. |
| Secondary collateral ≠ committed type (`ESuilendSecondaryIsCommittedType`) | S:withdraw_secondary_collateral(_sui) | not testable (stub) | MISSING | Testable: the check runs before the stubs. |
| Strategy state is initialized once (`ESuilendStateAlreadyExists`) | S:init_suilend_state | test_atomic_liquidity_vault::suilend_accepts_the_committed_coin_type | MISSING | Reachable directly; the coin-type tests already call this function. |
| Delivery and sufficiency (`EStrategyShortDelivery`, `EStrategyInsufficientCTokens`) | S:withdraw_from_suilend(_sui), withdraw_obligation_ctokens | not testable (stub) | not testable (stub) | |
| Recipient ≠ @0 (`EInvalidRecipient`) | A:update_platform_fee_recipient | test_admin::should_succeed_when_updating_platform_fee_recipient | test_admin::should_fail_when_making_zero_address_platform_fee_recipient | |
| Fee-collection recipient ≠ @0 (`EInvalidAccount`) | V:collect_platform_fee_v2, ALV:collect_platform_fee | test_vault::should_collect_platform_fee | MISSING | Unreachable: init sets the recipient to the sender, and the setter rejects @0. |
| List entry ≠ @0 | V:update_accounts (`EInvalidAccount`); C:update_accounts (`EZeroAddress`); ALV:set_swap_waiver | test_vault::should_add_a_new_sub_account | MISSING | No test references `EZeroAddress`. |
| Sub-accounts at creation: no @0 and no duplicates (`EInvalidAccount`) | V:create_vault; ALV:create_atomic_liquidity_vault | test_vault::should_create_vault | V: test_vault::should_fail_when_creating_vault_with_zero_address_sub_account, test_vault::should_fail_when_creating_vault_with_duplicate_sub_accounts; ALV: MISSING | |
| Receiver ≠ @0 (`EInvalidAccount`) | V:redeem_shares_for_owner | test_redeem::should_redeem_shares_from_vault | MISSING | |
| Receiver ≠ @0 (`EInvalidReceiver`) | ALV:redeem_shares, ALV:do_instant_withdraw_core | test_atomic_liquidity_vault::should_park_shares_in_pending_burn_on_redeem_request, test_atomic_liquidity_vault::should_burn_shares_and_pay_net_amount_on_instant_withdraw | test_atomic_liquidity_vault::redeem_shares_rejects_zero_receiver, test_atomic_liquidity_vault::instant_withdraw_rejects_zero_receiver | |
| Receiver ≠ @0 (`EInvalidAccount`) | ALV:do_swap_ember_shares_core | test_atomic_utilization_scenarios::swap_meets_exact_min_net_out | MISSING | |
| Zero amounts (classic) | V:mint_shares_v2 (shares > 0); withdraw_from_vault_without_redeeming_shares (0 < amount ≤ balance, `EInsufficientBalance`); deposit_*_without_minting_shares (> 0); process_withdrawal_requests (n > 0); collect_platform_fee_v2 (fee > 0) | test_mint::should_succeed_when_mint_shares_slippage_within_tolerance, test_vault::should_allow_vault_operator_to_withdraw_complete_vault_balance_from_vault_without_redeeming_shares, test_vault::should_collect_platform_fee | test_mint::should_fail_when_user_tries_to_mint_shares_with_zero_shares, test_vault::should_fail_to_withdraw_zero_amount_from_vault_without_redeeming_shares, test_vault::should_fail_to_withdraw_more_than_vault_balance_from_vault_without_redeeming_shares, test_vault::should_fail_to_deposit_zero_amount_to_vault_without_minting_shares, test_process_withdrawal::test_process_withdrawal_request_zero_requests, test_vault::should_fail_to_collect_zero_platform_fee | V:deposit_asset_v2 `amount > 0` is MISSING. |
| Zero amounts (atomic) | ALV:deposit, do_instant_withdraw_core, do_swap_ember_shares_core, deposit_from_sub_account_v2, collect_platform_fee (and `loss ≤ accrued`), process_withdrawal_requests, release_users_holdback (max_entries), redeem_collected_ember_shares, claim_received_collateral, claim_returned_ember_shares, supply/withdraw Suilend strategy | (normal-path tests) | MISSING | |
| List membership integrity (`EAlreadyExists`, `EInvalidRequest`) | V:update_accounts | test_vault::should_remove_a_sub_account | test_vault::should_not_add_duplicate_sub_accounts_when_adding_a_new_sub_account, test_vault::should_not_remove_a_sub_account_that_is_not_in_the_vault, test_vault::should_not_add_duplicate_black_listed_accounts_when_adding_a_new_black_listed_account, test_vault::should_not_remove_a_black_listed_account_that_is_not_in_the_vault | The atomic equivalents `common::EAlreadyExists` and `common::ENotFound` are MISSING. |
| Other create_vault parameter checks: interval, empty treasury cap (`EReceiptTokenTreasuryCapNotEmpty`), fee cap | V:create_vault | test_vault::should_create_vault | MISSING | |

## Gaps

Checks with no negative test, grouped by area. Each row in the tables above marked **MISSING** is the full list.

### Authorization
- **Guardian:** V:guardian_set_blacklisted_account; ALV:guardian_set_pause_status and ALV:guardian_set_blacklisted_account (no positive either).
- **Classic admin:** update_vault_rate_manager; update_vault_name (no positive either).
- **Classic operator:** collect_platform_fee_v2; process_withdrawal_requests_up_to_timestamp.
- **ALV admin, untested entirely:** update_vault_name, update_vault_max_tvl, update_vault_max_rate_change_per_update, change_vault_rate_update_interval, change_vault_operator, update_vault_rate_manager, set_swap_waiver, set_strategy_none_from_suilend_sui.
- **ALV admin, negative only missing:** set_pause_status, set_max_instant_withdraw_shares, set_instant_withdraw_fee_percentage, set_ember_share_whitelist, fee-tier set/remove, withdrawal-fee setters, set_min_withdrawal_shares, set_sub_account, set_strategy_suilend, set_strategy_none_from_suilend. update_vault_fee_percentage is the reverse case: it has a negative but no positive.
- **ALV operator, untested entirely:** supply_to_sub_account, collect_platform_fee, process_withdrawal_requests_up_to_timestamp, set_deposit_user_list, claim_received_collateral, claim_returned_ember_shares.
- **ALV operator, negative only missing:** set_blacklisted_account, process_withdrawal_requests, release_users_holdback, redeem_collected_ember_shares, withdraw_from_suilend_strategy, supply_to_suilend_strategy, withdraw_from_suilend_strategy_sui. The last three have their auth check before the stub, so a negative is testable.
- **ALV, other roles:** admin-or-operator on secondary-collateral withdrawal; rate manager on update_vault_rate (no positive either); cancel ownership.
- **Sub-account whitelist:** ALV:supply_to_sub_account and secondary-collateral recipient. ALV:deposit_from_sub_account has no positive.
- **Deposit allowlist:** V:mint_shares_v2 and ALV:deposit, both directions.
- **Blacklist:**
  - Receiver side of V redeem and ALV deposit.
  - All of ALV redeem, instant withdraw and swap, including the M-02 atomic-address check.
  - Guardian and ALV blacklisting a sub-account.
  - Blacklisted user added to the deposit or fee-exempt list.
  - ALV set_sub_account with a blacklisted account.
  - ALV deposit by a sub-account.
- **Role distinctness:**
  - V:create_vault admin/operator collisions.
  - V:change_vault_admin and change_vault_operator collisions other than zero and same-value.
  - V:update_vault_rate_manager.
  - V set_sub_account and deposit/fee-exempt lists against admin, operator and rate manager.
  - ALV create.
  - ALV change admin, operator and rate manager (`ERoleConflict` is never referenced).
  - ALV list setters.

### Invariants
- **Version gate** at every vault.move and atomic_liquidity_vault.move call site.
- **Protocol pause:**
  - Classic: process_withdrawal_requests (both variants), update_vault_name, deposit/fee-exempt lists, withdrawal-fee setters.
  - Atomic: every call site.
- **Per-operation DF pause, classic:**
  - The deposits DF and the withdrawals DF have no negative; only the legacy bit is tested.
  - The privileged DF is tested on collect_platform_fee_v2 only.
- **Atomic pause flags:** every withdrawals-pause call site, and every privileged-pause call site except set_strategy_none_from_suilend. Atomic `EInvalidStatus` is also untested.
- **Max TVL:** ALV deposit, ALV setter, ALV create.
- **Min withdrawal shares:** ALV instant withdraw, ALV setter > 0, both creates.
- **Rate checks:** all of ALV update_vault_rate, the ALV max-change and interval setters, ALV create, the V:create_vault interval, and the A `max_rate_interval > 1 day` clause.
- **Fee caps:**
  - ALV platform fee in the setter and at create; V:create_vault fee cap.
  - The time-based individual cap in both vaults; the combined cap inside set_time_based (V) and anywhere in ALV.
  - EmberShare whitelist clauses other than the base fee; holdback unwinding ≤ 100%.
- **EmberShare swap:**
  - Not whitelisted / not configured; 24h capacity.
  - Dust floor; zero atomic TVL.
  - Absolute held-value cap has no positive with a non-zero cap.
  - Receiver ≠ @0; strategy mismatch on the swap variants.
  - redeem_collected_ember_shares guards.
- **Suilend:**
  - `ESuilendSuiRequiresSuiPath`, `ESuilendSecondaryIsCommittedType`, `ESuilendStateAlreadyExists` are all testable but untested.
  - The market-mismatch check is only negative-tested on the exit path.
  - Not testable (stub): reserve index, obligation already exists, residual deposit on exit, short delivery, insufficient cTokens.
- **Zero address / zero amount:**
  - V and ALV list entries ≠ @0 (`EZeroAddress` is never referenced); V redeem receiver; ALV create sub-accounts.
  - V:deposit_asset_v2 amount > 0, and every atomic zero-amount guard; ALV `loss ≤ accrued`.
  - ALV `common::EAlreadyExists` / `ENotFound`.
  - V:create_vault interval, `EReceiptTokenTreasuryCapNotEmpty`, min_withdrawal_shares, fee cap.
- **Instant withdraw:** ALV owner-balance and idle-liquidity checks.
