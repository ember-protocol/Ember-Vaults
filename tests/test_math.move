#[test_only]
module ember_vaults::test_math {
    use ember_vaults::math::{Self};

    // Constants for testing
    const BASE: u64 = 1_000_000_000;
    const MAX_U64: u64 = 18446744073709551615;


   #[test]
   fun should_give_correct_result_for_mul(){
    let a = 5000000000;
    let b = 6000000000;
    let result = math::mul(a, b);
    assert!(result == 30000000000, 1);
   }

   #[test]
    fun should_give_correct_result_for_div(){
    let a = 30000000000;
    let b = 10000000000;
    let result = math::div(a, b);
    assert!(result == 3000000000, 1);
   }

   #[test]
   fun should_give_correct_result_for_div_ceil_exact_division(){
    let a = 30000000000;
    let b = 10000000000;
    let result = math::div_ceil(a, b);
    assert!(result == 3000000000, 1); // Exact division should be same as regular div
   }

   #[test]
   fun should_give_correct_result_for_div_ceil_with_remainder(){
    // Test case where division does not result in an exact result
    // Using smaller numbers to ensure we get a clear remainder
    let a = 10000000001; // 10.000000001 in BASE units
    let b = 5000000000;  // 5.0 in BASE units
    let result = math::div_ceil(a, b);
    let regular_div = math::div(a, b);
    
    // 10.000000001 / 5.0 = 2.0000000002, so:
    // regular_div should truncate to 2000000000 (2.0 * BASE)
    // div_ceil should round up to 2000000001
    assert!(result > regular_div, 2); // Should be greater than regular division
   }

   #[test]
   fun should_give_correct_result_for_div_ceil_small_remainder(){
    let a = 3000000001; // Very small remainder: 3.000000001
    let b = 3000000000;  // 3.0
    let result = math::div_ceil(a, b);
    let regular_div = math::div(a, b);
    
    // 3.000000001 / 3.0 = 1.0000000003333..., so:
    // regular_div should be 1000000000 (1.0 * BASE)
    // div_ceil should be 1000000001 (rounded up)
    assert!(result > regular_div, 2); // Should be greater than regular division
    assert!(result == regular_div + 1, 1); // Should be exactly one more
   }

   #[test]
    fun should_correctly_calculate_diff_abs_when_a_is_greater_than_b(){
    let a = 9000000000;
    let b = 3000000000;
    let result = math::diff_abs(a, b);
    assert!(result == 6000000000, 1);
   }

   #[test]
    fun should_correctly_calculate_diff_abs_when_b_is_greater_than_a(){
    let a = 3000000000;
    let b = 9000000000;
    let result = math::diff_abs(a, b);
    assert!(result == 6000000000, 1);
   }

   #[test]
   fun should_correctly_calculate_percent_change_from_when_a_is_greater_than_b(){
    let a = 9000000000;
    let b = 3000000000;
    let result = math::percent_change_from(a, b);
    assert!(result == 666666666, 1);
   }

   #[test]
   fun should_correctly_calculate_percent_change_from_when_b_is_greater_than_a(){
    let a = 3000000000;
    let b = 9000000000;
    let result = math::percent_change_from(a, b);
    assert!(result == 2000000000, 1);
   }

    #[test]
    #[expected_failure(abort_code = ember_vaults::math::EOverflow)]
    fun should_revert_due_to_overflow_when_mul_is_called(){
        let a = 10000000000000000000;
        let b = 10000000000000000000;
        math::mul(a, b);    
   }

    #[test]
    #[expected_failure(abort_code = ember_vaults::math::EOverflow)]
    fun should_revert_due_to_overflow_when_div_is_called_with_b_as_1(){
        let a = 10000000000000000000;
        let b = 1;
        math::div(a, b);    
   }

    #[test]
    #[expected_failure(abort_code = ember_vaults::math::EDivisionByZero)]
    fun should_revert_due_to_division_by_zero_when_div_is_called_with_b_as_0(){
        let a = 10000000000000000000;
        let b = 0;
        math::div(a, b);    
   }

    #[test]
    fun test_mul_with_zero() {
        assert!(math::mul(0, 1000000000) == 0, 0);
        assert!(math::mul(1000000000, 0) == 0, 1);
        assert!(math::mul(0, 0) == 0, 2);
    }

    #[test]
    fun test_mul_with_base() {
        // When multiplying by BASE, result should equal first operand
        assert!(math::mul(1000000000, BASE) == 1000000000, 0);
        assert!(math::mul(500000000, BASE) == 500000000, 1);
    }

    #[test]
    fun test_mul_precision() {
        // Test precision with small numbers
        let result = math::mul(1, 500000000); // 1 * 0.5 = 0.5
        assert!(result == 0, 0); // Should round down to 0
        
        let result2 = math::mul(1, 1500000000); // 1 * 1.5 = 1.5
        assert!(result2 == 1, 1); // Should round down to 1
    }

    #[test]
    fun test_mul_large_numbers() {
        // Test with large numbers that shouldn't overflow
        let large_num = 1000000000000; // 1 trillion
        let result = math::mul(large_num, BASE); // Should equal large_num
        assert!(result == large_num, 0);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::math::EOverflow)]
    fun test_mul_overflow() {
        // This should cause overflow
        let very_large = MAX_U64 / 1000; // Still very large
        math::mul(very_large, very_large);
    }

    #[test]
    fun test_div_basic() {
        // 1000 / 1 = 1000 * BASE / 1 = 1000 * BASE
        assert!(math::div(1000, 1) == 1000 * BASE, 0);
        
        // 1000 / 2 = 500 * BASE  
        assert!(math::div(1000, 2) == 500 * BASE, 1);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::math::EDivisionByZero)]
    fun test_div_by_zero() {
        math::div(1000, 0);
    }

    #[test]
    fun test_div_precision() {
        // Test precision with division
        let result = math::div(1, 3); // 1/3 should be approximately 0.333... * BASE
        let expected = BASE / 3; // Should be 333,333,333
        assert!(result == expected, 0);
    }

    #[test]
    fun test_div_with_base() {
        // Dividing by BASE should give the quotient in base units
        assert!(math::div(BASE, BASE) == BASE, 0); // 1/1 = 1
        assert!(math::div(2 * BASE, BASE) == 2 * BASE, 1); // 2/1 = 2
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::math::EOverflow)]
    fun test_div_overflow() {
        // This should cause overflow when multiplying by BASE
        math::div(MAX_U64, 1);
    }

    #[test]
    fun test_diff_abs_basic() {
        assert!(math::diff_abs(10, 5) == 5, 0);
        assert!(math::diff_abs(5, 10) == 5, 1);
        assert!(math::diff_abs(10, 10) == 0, 2);
    }

    #[test]
    fun test_diff_abs_large_numbers() {
        let large1 = 1000000000000;
        let large2 = 500000000000;
        assert!(math::diff_abs(large1, large2) == 500000000000, 0);
        assert!(math::diff_abs(large2, large1) == 500000000000, 1);
    }

    #[test]
    fun test_diff_abs_max_values() {
        assert!(math::diff_abs(MAX_U64, 0) == MAX_U64, 0);
        assert!(math::diff_abs(0, MAX_U64) == MAX_U64, 1);
    }

    #[test]
    fun test_percent_change_from_basic() {
        // 10% difference: percent_change_from(100, 110) should be ~0.1 * BASE
        let result = math::percent_change_from(1000000000, 1100000000); // 100% to 110%
        let expected = 100000000; // 0.1 * BASE = 10%
        assert!(result == expected, 0);
    }

    #[test]
    fun test_percent_change_from_zero_diff() {
        assert!(math::percent_change_from(1000000000, 1000000000) == 0, 0);
    }

    #[test]
    fun test_percent_change_from_large_diff() {
        // 100% difference
        let result = math::percent_change_from(1000000000, 2000000000); // 100% to 200%
        assert!(result == BASE, 0); // Should be 100% = BASE
    }

    #[test]
    fun test_percent_change_from_precision() {
        // Test small percentage differences
        let result = math::percent_change_from(1000000000, 1001000000); // 0.1% difference
        let expected = 1000000; // 0.001 * BASE
        assert!(result == expected, 0);
    }

    #[test]
    fun test_realistic_vault_scenarios() {
        // Test realistic vault rate calculations
        let deposit_amount = 20000000; // 20 USDC
        let rate = 1050000000; // 105%
        
        // Calculate shares using mul: (amount * rate) / BASE
        let shares = math::mul(deposit_amount, rate);
        let expected_shares = 21000000; // 20 * 1.05 = 21
        assert!(shares == expected_shares, 0);
        
        // Test rate change validation (5% max change)
        let old_rate = 1000000000; // 100%
        let new_rate = 1050000000; // 105%
        let percent_change = math::percent_change_from(old_rate, new_rate);
        assert!(percent_change == 50000000, 1); // 5% change
        
        // Test with fee calculation (0.1% fee)
        let fee_rate = 1000000; // 0.1%
        let fee_amount = math::mul(deposit_amount, fee_rate);
        let expected_fee = 20000; // 20 * 0.001 = 0.02
        assert!(fee_amount == expected_fee, 2);
    }

    #[test]
    fun test_edge_case_small_amounts() {
        // Test with very small amounts (1 unit)
        let tiny_amount = 1;
        let rate = 1000000000;
        let result = math::mul(tiny_amount, rate);
        assert!(result == 1, 0); // Should still work
        
        // Test division with small amounts
        let result2 = math::div(tiny_amount, rate);
        assert!(result2 == 1, 1); // 1 / 1 = 1
    }

    #[test]
    fun test_edge_case_rate_boundaries() {
        // Test with minimum possible rate (close to 0)
        let min_rate = 1;
        let amount = 1000000000;
        let result = math::mul(amount, min_rate);
        assert!(result == 1, 0); // Very small result
        
        // Test with maximum reasonable rate
        let max_rate = 10000000000; // 1000%
        let small_amount = 1000;
        let result2 = math::mul(small_amount, max_rate);
        assert!(result2 == 10000, 1); // 1000 * 10 = 10000
    }


}