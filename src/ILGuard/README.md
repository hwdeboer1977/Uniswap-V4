# ILGuard: A Dynamic Yield Compensation Hook for Liquidity Providers

## Overview

**ILGuard** is a custom Uniswap V4 hook designed to compensate liquidity providers (LPs) for impermanent loss (IL). By rewarding LPs with yield tokens based on the magnitude of their IL, ILGuard incentivizes long-term liquidity provision and mitigates the financial risks associated with volatile markets.

This system ensures fairness by dynamically calculating rewards proportional to IL while capping emissions to prevent overcompensation during extreme market conditions.

## Whitepaper

A detailed whitepaper (expected March 2025) will explain the theoretical framework, tokenomics, and implementation details of ILGuard. The whitepaper will also outline the next steps on the roadmap, including:

- Dynamic compensation caps tailored to market conditions.
- Tiered rewards systems for incentivizing long-term liquidity provision.
- Governance integration to decentralize parameter adjustments.
- Cross-protocol collaborations to expand incentives and utility.
- Multichain support for liquidity pools on emerging blockchain networks.

Stay tuned for updates, and be part of the journey as ILGuard evolves to better serve liquidity providers!

---

## Key Features

1. **Impermanent Loss Compensation**:

   - Tracks impermanent loss (IL) for each LP in real-time.
   - Compensates LPs with yield tokens if they incur IL.

2. **Linear Compensation with Cap**:

   - Rewards are proportional to the magnitude of IL.
   - Includes a maximum cap to ensure predictable token emissions during high volatility.

3. **Active Range Detection**:

   - Rewards are only distributed to LPs whose positions are within the active price range.
   - Out-of-range positions are excluded from compensation after a short grace period.

4. **Fair and Sustainable**:
   - Protects LPs without overcompensating for normal market fluctuations.
   - Incentivizes active liquidity management and risk-taking.

---

## How It Works


### 1. **Impermanent Loss Calculation**

ILGuard calculates IL by comparing the current value of the liquidity provider's position to the value at the time the liquidity was initially provided:

$$IL = (Initial \ value \ LP) - (Current \ value \ LP)$$

### 2. **Compensation Formula**

Compensation (C) is distributed using a linear formula, with a cap to control emissions:

```math
\text{C} = \min(IL \times k, \text{C\_max})
```

Where:

- `C`: Compensation distributed as yield tokens.
- `IL`: Impermanent Loss, calculated as the difference between the initial value of the LP's position and its current value.
- `k`: A scaling factor to convert IL (in USD) into yield tokens.
- `C_max`: The maximum number of yield tokens distributed per LP.

### 3. **Active Range Detection**

ILGuard only compensates LPs whose price range is active:

- Active range:
  ```math
  P_{\text{min}} \leq P_{\text{current}} \leq P_{\text{max}}
  ```
- LPs out of range are excluded after a short grace period.

---

## Future Developments

We're just getting started! Here are some exciting features and enhancements planned for ILGuard:

1. **Dynamic Caps**:

   - Introduce market-aware dynamic compensation caps that adjust based on volatility and overall protocol usage.

2. **Tiered Rewards System**:

   - Implement a tier-based system to reward LPs based on the duration of their liquidity provision and the magnitude of impermanent loss.

3. **Governance Integration**:

   - Enable governance voting to allow token holders to adjust parameters like the scaling factor (`k`) and maximum compensation (`C_max`).

4. **Cross-Protocol Incentives**:

   - Partner with other DeFi protocols to distribute their tokens as additional rewards, enhancing liquidity incentives.

5. **Whitepaper Release**:

   - Publish a detailed whitepaper covering the theoretical framework, mathematical models, and tokenomics of ILGuard.

6. **Multichain Support**:
   - Expand ILGuard functionality to support liquidity pools across multiple blockchain networks.

More to come! Stay tuned for updates, or feel free to reach out if you’d like to contribute to the project!

## Parameters

### Configuration Variables

| Parameter         | Description                                                    | Default Value |
| ----------------- | -------------------------------------------------------------- | ------------- |
| `k`               | Scaling factor for IL-to-yield token conversion                | 1             |
| `MaxCompensation` | Maximum yield tokens per LP                                    | 1000          |
| `GracePeriod`     | Time (in seconds) LPs can remain out of range and earn rewards | 86400 (1 day) |

---

## Installation and Usage

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/ILGuard.git
   ```
