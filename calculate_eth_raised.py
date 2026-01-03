#!/usr/bin/env python3
"""
Calculate total ETH raised for the quadratic bonding curve.

Formula: price(s) = INITIAL_PRICE * (1 + (s / PRICE_STEP_SIZE)^2)

Constants:
- INITIAL_PRICE = 0.0001533 ETH = 153300000000000 wei (0.0001533e18)
- PRICE_STEP_SIZE = 10,000,000 * 1e18 = 10^25 wei = 10M tokens
- MAX_SUPPLY = 1,000,000,000 * 1e18 = 10^27 wei = 1B tokens
- BONDING_CURVE_PERCENT = 70%
- Bonding curve max = 700M tokens = 700,000,000 * 1e18
"""

from decimal import Decimal, getcontext

# Set high precision
getcontext().prec = 50

# Constants
INITIAL_PRICE_ETH = Decimal("0.0001533")
INITIAL_PRICE_WEI = INITIAL_PRICE_ETH * Decimal(10)**18

PRICE_STEP_SIZE_WEI = Decimal("10000000") * Decimal(10)**18  # 10M tokens
PRICE_STEP_SIZE_TOKENS = Decimal("10000000")  # 10M tokens in human-readable form

MAX_SUPPLY_TOKENS = Decimal("1000000000")  # 1B tokens
BONDING_CURVE_PERCENT = Decimal("70")
BONDING_CURVE_MAX_TOKENS = (MAX_SUPPLY_TOKENS * BONDING_CURVE_PERCENT) / Decimal("100")  # 700M tokens

# For calculations at different percentages
PERCENT_20_TOKENS = (BONDING_CURVE_MAX_TOKENS * Decimal("20")) / Decimal("100")  # 140M tokens
PERCENT_40_TOKENS = (BONDING_CURVE_MAX_TOKENS * Decimal("40")) / Decimal("100")  # 280M tokens
PERCENT_69_TOKENS = (BONDING_CURVE_MAX_TOKENS * Decimal("69")) / Decimal("100")  # 483M tokens


def price_formula(supply_tokens):
    """
    Calculate price at given supply using quadratic formula.
    price(s) = INITIAL_PRICE * (1 + (s / PRICE_STEP_SIZE)^2)
    
    Args:
        supply_tokens: Supply in tokens (not wei, just the number)
    
    Returns:
        Price in ETH
    """
    if supply_tokens == 0:
        return INITIAL_PRICE_ETH
    
    supply_ratio = supply_tokens / PRICE_STEP_SIZE_TOKENS
    ratio_squared = supply_ratio * supply_ratio
    
    # price = INITIAL_PRICE * (1 + ratio_squared)
    price_eth = INITIAL_PRICE_ETH * (Decimal("1") + ratio_squared)
    
    return price_eth


def calculate_eth_raised_integral(final_supply_tokens, num_steps=100000):
    """
    Calculate total ETH raised by integrating the price function.
    
    Uses numerical integration: ETH = ∫[0 to S] price(s) ds
    
    Args:
        final_supply_tokens: Final supply in tokens (e.g., 700M or 483M)
        num_steps: Number of steps for numerical integration (higher = more accurate)
    
    Returns:
        Total ETH raised (in ETH, not wei)
    """
    eth_raised = Decimal("0")
    step_size = final_supply_tokens / Decimal(num_steps)
    
    for i in range(num_steps):
        # Current supply at this step
        current_supply = (Decimal(i) + Decimal("0.5")) * step_size  # Midpoint for better accuracy
        price = price_formula(current_supply)
        
        # Add the ETH needed for this small increment
        eth_raised += price * step_size
    
    return eth_raised


def calculate_eth_raised_analytical(final_supply_tokens):
    """
    Calculate total ETH raised using analytical integration.
    
    ETH = ∫[0 to S] INITIAL_PRICE * (1 + (s / PRICE_STEP_SIZE)^2) ds
    ETH = INITIAL_PRICE * [s + s^3 / (3 * PRICE_STEP_SIZE^2)] from 0 to S
    ETH = INITIAL_PRICE * (S + S^3 / (3 * PRICE_STEP_SIZE^2))
    
    Args:
        final_supply_tokens: Final supply in tokens
    
    Returns:
        Total ETH raised (in ETH, not wei)
    """
    S = final_supply_tokens
    
    # Calculate S^3
    S_cubed = S * S * S
    
    # Calculate denominator: 3 * PRICE_STEP_SIZE^2
    step_size_squared = PRICE_STEP_SIZE_TOKENS * PRICE_STEP_SIZE_TOKENS
    denominator = Decimal("3") * step_size_squared
    
    # Calculate integral: S + S^3 / (3 * PRICE_STEP_SIZE^2)
    integral_value = S + (S_cubed / denominator)
    
    # Multiply by initial price
    eth_raised = INITIAL_PRICE_ETH * integral_value
    
    return eth_raised


def format_eth(eth_amount):
    """Format ETH amount with appropriate precision."""
    return f"{eth_amount:,.6f} ETH"


if __name__ == "__main__":
    print("=" * 80)
    print("BONDING CURVE ETH CALCULATION")
    print("=" * 80)
    print()
    print(f"Initial Price: {INITIAL_PRICE_ETH} ETH")
    print(f"Price Step Size: {PRICE_STEP_SIZE_TOKENS:,.0f} tokens")
    print(f"Bonding Curve Max: {BONDING_CURVE_MAX_TOKENS:,.0f} tokens (70% of 1B)")
    print()
    
    # Calculate for 20% (140M tokens)
    print("-" * 80)
    print("CASE 1: 140M tokens sold (20% of bonding curve)")
    print("-" * 80)
    
    eth_20_analytical = calculate_eth_raised_analytical(PERCENT_20_TOKENS)
    
    print(f"Using analytical integration:")
    print(f"  Total ETH raised: {format_eth(eth_20_analytical)}")
    print()
    
    final_price_20 = price_formula(PERCENT_20_TOKENS)
    print(f"Final price at 140M tokens: {format_eth(final_price_20)} per token")
    print()
    
    # Calculate for 40% (280M tokens)
    print("-" * 80)
    print("CASE 2: 280M tokens sold (40% of bonding curve)")
    print("-" * 80)
    
    eth_40_analytical = calculate_eth_raised_analytical(PERCENT_40_TOKENS)
    
    print(f"Using analytical integration:")
    print(f"  Total ETH raised: {format_eth(eth_40_analytical)}")
    print()
    
    final_price_40 = price_formula(PERCENT_40_TOKENS)
    print(f"Final price at 280M tokens: {format_eth(final_price_40)} per token")
    print()
    
    # Calculate for 69% (483M tokens)
    print("-" * 80)
    print("CASE 3: 483M tokens sold (69% of bonding curve)")
    print("-" * 80)
    
    eth_69_analytical = calculate_eth_raised_analytical(PERCENT_69_TOKENS)
    
    print(f"Using analytical integration:")
    print(f"  Total ETH raised: {format_eth(eth_69_analytical)}")
    print()
    
    final_price_69 = price_formula(PERCENT_69_TOKENS)
    print(f"Final price at 483M tokens: {format_eth(final_price_69)} per token")
    print()
    
    # Calculate for 100% (700M tokens)
    print("-" * 80)
    print("CASE 4: All 700M tokens sold (100% of bonding curve)")
    print("-" * 80)
    
    eth_100_analytical = calculate_eth_raised_analytical(BONDING_CURVE_MAX_TOKENS)
    eth_100_numerical = calculate_eth_raised_integral(BONDING_CURVE_MAX_TOKENS, num_steps=100000)
    
    print(f"Using analytical integration:")
    print(f"  Total ETH raised: {format_eth(eth_100_analytical)}")
    print()
    print(f"Using numerical integration (100,000 steps):")
    print(f"  Total ETH raised: {format_eth(eth_100_numerical)}")
    print()
    
    # Verify with final price
    final_price_100 = price_formula(BONDING_CURVE_MAX_TOKENS)
    print(f"Final price at 700M tokens: {format_eth(final_price_100)} per token")
    print()
    
    # Account for 2% fee
    # Users send ETH, 2% goes to treasury, 98% stays in contract
    FEE_PERCENT = Decimal("2")
    
    print("-" * 80)
    print("BREAKDOWN (Accounting for 2% fee)")
    print("-" * 80)
    print()
    
    print("For 20% (140M tokens):")
    total_eth_sent_20 = eth_20_analytical
    eth_in_contract_20 = total_eth_sent_20 * (Decimal("100") - FEE_PERCENT) / Decimal("100")
    eth_to_treasury_20 = total_eth_sent_20 * FEE_PERCENT / Decimal("100")
    print(f"  Total ETH sent by users:     {format_eth(total_eth_sent_20)}")
    print(f"  ETH accumulated in contract: {format_eth(eth_in_contract_20)} (98%)")
    print(f"  ETH sent to treasury (fees): {format_eth(eth_to_treasury_20)} (2%)")
    print()
    
    print("For 40% (280M tokens):")
    total_eth_sent_40 = eth_40_analytical
    eth_in_contract_40 = total_eth_sent_40 * (Decimal("100") - FEE_PERCENT) / Decimal("100")
    eth_to_treasury_40 = total_eth_sent_40 * FEE_PERCENT / Decimal("100")
    print(f"  Total ETH sent by users:     {format_eth(total_eth_sent_40)}")
    print(f"  ETH accumulated in contract: {format_eth(eth_in_contract_40)} (98%)")
    print(f"  ETH sent to treasury (fees): {format_eth(eth_to_treasury_40)} (2%)")
    print()
    
    print("For 69% (483M tokens):")
    total_eth_sent_69 = eth_69_analytical
    eth_in_contract_69 = total_eth_sent_69 * (Decimal("100") - FEE_PERCENT) / Decimal("100")
    eth_to_treasury_69 = total_eth_sent_69 * FEE_PERCENT / Decimal("100")
    print(f"  Total ETH sent by users:     {format_eth(total_eth_sent_69)}")
    print(f"  ETH accumulated in contract: {format_eth(eth_in_contract_69)} (98%)")
    print(f"  ETH sent to treasury (fees): {format_eth(eth_to_treasury_69)} (2%)")
    print()
    
    print("For 100% (700M tokens):")
    total_eth_sent_100 = eth_100_analytical
    eth_in_contract_100 = total_eth_sent_100 * (Decimal("100") - FEE_PERCENT) / Decimal("100")
    eth_to_treasury_100 = total_eth_sent_100 * FEE_PERCENT / Decimal("100")
    print(f"  Total ETH sent by users:     {format_eth(total_eth_sent_100)}")
    print(f"  ETH accumulated in contract: {format_eth(eth_in_contract_100)} (98%)")
    print(f"  ETH sent to treasury (fees): {format_eth(eth_to_treasury_100)} (2%)")
    print()
    
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)
    print("Total ETH sent by users (gross):")
    print(f"  At 20% (140M tokens):  {format_eth(eth_20_analytical)}")
    print(f"  At 40% (280M tokens):  {format_eth(eth_40_analytical)}")
    print(f"  At 69% (483M tokens):  {format_eth(eth_69_analytical)}")
    print(f"  At 100% (700M tokens): {format_eth(eth_100_analytical)}")
    print()
    print("ETH accumulated in contract (net, after 2% fee):")
    print(f"  At 20% (140M tokens):  {format_eth(eth_in_contract_20)}")
    print(f"  At 40% (280M tokens):  {format_eth(eth_in_contract_40)}")
    print(f"  At 69% (483M tokens):  {format_eth(eth_in_contract_69)}")
    print(f"  At 100% (700M tokens): {format_eth(eth_in_contract_100)}")
    print("=" * 80)

