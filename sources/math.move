/*
  Copyright (c) 2025 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code 
  requires prior written permission from the Ember Protocol Inc.
*/

module ember_vaults::math {
    use std::u64;
    // === Errors ===

    const EOverflow: u64 = 3000;
    const EDivisionByZero: u64 = 3001;

    // === Constants ===

    const BASE: u64 = 1_000_000_000;

    // === Public Functions ===

    /// Multiplies two u64 values and returns the result.
    /// 
    /// Parameters:
    /// - a: The first u64 value to multiply.
    /// - b: The second u64 value to multiply.
    /// 
    /// Returns:
    /// - The result of the multiplication.
    /// 
    /// Aborts with:
    /// - EOverflow: If the multiplication result overflows u64.
    public fun mul(a: u64, b: u64): u64 {
        let result = ((a as u128) * (b as u128)) / (BASE as u128);
        safely_cast_to_u64(result)
    }

    /// Divides two u64 values and returns the result.
    /// 
    /// Parameters:
    /// - a: The dividend.
    /// - b: The divisor.
    /// 
    /// Returns:
    /// - The result of the division.
    /// 
    /// Aborts with:
    /// - EDivisionByZero: If the divisor is zero.
    public fun div(a: u64, b: u64): u64 {
        assert!(b > 0, EDivisionByZero); // Division by zero check
        let result = ((a as u128) * (BASE as u128)) / (b as u128);
        safely_cast_to_u64(result)
    }

    /// Calculates the absolute difference between two u64 values.
    /// 
    /// Parameters:
    /// - a: The first u64 value.
    /// - b: The second u64 value.
    /// 
    /// Returns:
    /// - The absolute difference between the two values.
    public fun diff_abs(a: u64, b: u64): u64 {
        if (a > b) { a - b } else { b - a }
    }

    /// Calculates the percentage difference between two u64 values.
    /// 
    /// Parameters:
    /// - a: The first u64 value.
    /// - b: The second u64 value.
    /// 
    /// Returns:
    /// - The percentage difference between the two values.
    public fun percent_change_from(a: u64, b: u64): u64 {
        div(diff_abs(a, b), a)
    }

    /// Divides two u64 values and rounds up to the nearest integer.
    /// 
    /// Parameters:
    /// - a: The dividend.
    /// - b: The divisor.
    /// 
    /// Returns:
    /// - The result of the division rounded up.
    /// 
    /// Aborts with:
    /// - EDivisionByZero: If the divisor is zero.
    /// 
    /// @dev Uses the efficient ceiling formula: ceil(a/b) = (a + b - 1) / b
    public fun div_ceil(a: u64, b: u64): u64 {
        assert!(b > 0, EDivisionByZero); // Division by zero check
        
        // Compute numerator once: a * BASE
        let numerator = (a as u128) * (BASE as u128);
        
        // Use ceiling formula: (numerator + b - 1) / b
        // This is equivalent to checking for remainder and adding 1, but more efficient
        let result = (numerator + (b as u128) - 1) / (b as u128);
        
        safely_cast_to_u64(result)
    }

    /// Safely casts a u128 value to u64.
    /// 
    /// Parameters:
    /// - result: The u128 value to cast.
    /// 
    /// Returns:
    /// - The u64 value.
    /// 
    public fun safe_cast_to_u64(result: u128): u64 {
        safely_cast_to_u64(result)
    }

    /// Safely casts a u128 value to u64.
    /// 
    /// Parameters:
    /// - result: The u128 value to cast.
    /// 
    /// Returns:
    /// - The u64 value.
    /// 
    /// Aborts with:
    /// - EOverflow: If the value is greater than u64::MAX.
    fun safely_cast_to_u64(result: u128): u64 {
        assert!(result <= (u64::max_value!() as u128), EOverflow); // u64::MAX overflow check
        result as u64
    }
}

