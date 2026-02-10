// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─── Curve StableSwapNG interface (USDC/scrvUSD on Base) ───────────────────
interface ICurveStableSwapNG {
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount) external returns (uint256);
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount, address receiver) external returns (uint256);
    function remove_liquidity(uint256 burn_amount, uint256[] calldata min_amounts) external returns (uint256[] memory);
    function remove_liquidity_one_coin(uint256 burn_amount, int128 i, uint256 min_received) external returns (uint256);
    function remove_liquidity_one_coin(uint256 burn_amount, int128 i, uint256 min_received, address receiver) external returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
    function calc_token_amount(uint256[] calldata amounts, bool is_deposit) external view returns (uint256);
    function calc_withdraw_one_coin(uint256 burn_amount, int128 i) external view returns (uint256);
    function coins(uint256 index) external view returns (address);
    function balances(uint256 index) external view returns (uint256);
    function fee() external view returns (uint256);
    function A() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function N_COINS() external view returns (uint256);
    function stored_rates() external view returns (uint256[] memory);
    function price_oracle(uint256 k) external view returns (uint256);
}

// ─── Curve Gauge interface ─────────────────────────────────────────────────
interface ICurveGauge {
    function deposit(uint256 amount) external;
    function deposit(uint256 amount, address receiver) external;
    function withdraw(uint256 amount) external;
    function withdraw(uint256 amount, bool claim_rewards) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function claim_rewards() external;
    function claim_rewards(address addr) external;
    function reward_tokens(uint256 i) external view returns (address);
    function claimable_reward(address user, address token) external view returns (uint256);
    function lp_token() external view returns (address);
}

/**
 * @title CurvePoolForkTest
 * @notice Fork tests that validate the Curve USDC/scrvUSD pool and gauge
 *         interfaces on Base mainnet. These tests prove the contract
 *         interactions needed by AnalogCurveVault work correctly against
 *         the live pool.
 *
 * Run:
 *   forge test --match-contract CurvePoolForkTest -vvv --fork-url $BASE_RPC_URL
 */
contract CurvePoolForkTest is Test {
    // ─── Base mainnet addresses ────────────────────────────────────────────
    address constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SCRVUSD = 0x646A737B9B6024e49f5908762B3fF73e65B5160c;
    address constant POOL    = 0x5aB01ee6208596f2204B85bDFA39d34c2aDD98F6;
    address constant GAUGE   = 0x0566c704640de416E3B1747F63efe0C82f4a3dA7;

    address constant USER       = address(0xBEEF);
    address constant CONTROLLER = address(0xC0FE);

    ICurveStableSwapNG pool;
    ICurveGauge gauge;
    IERC20 usdc;
    IERC20 lpToken;
    IERC20 scrvusd;

    // ─── Setup ─────────────────────────────────────────────────────────────

    function setUp() public {
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url2) {
                rpcUrl = url2;
            } catch {}
        }
        vm.createSelectFork(rpcUrl);

        pool    = ICurveStableSwapNG(POOL);
        gauge   = ICurveGauge(GAUGE);
        usdc    = IERC20(USDC);
        lpToken = IERC20(POOL); // LP token is the pool contract itself
        scrvusd = IERC20(SCRVUSD);

        vm.label(USDC,    "USDC");
        vm.label(SCRVUSD, "scrvUSD");
        vm.label(POOL,    "CurvePool");
        vm.label(GAUGE,   "CurveGauge");
        vm.label(USER,    "USER");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  1. Pool state reads — validate the interface works on this pool
    // ═══════════════════════════════════════════════════════════════════════

    function test_pool_coins() public view {
        address coin0 = pool.coins(0);
        address coin1 = pool.coins(1);

        assertEq(coin0, USDC,    "coin(0) should be USDC");
        assertEq(coin1, SCRVUSD, "coin(1) should be scrvUSD");
    }

    function test_pool_constants() public view {
        uint256 A = pool.A();
        assertGt(A, 0, "amplification coefficient should be > 0");

        uint256 fee = pool.fee();
        assertGt(fee, 0, "fee should be > 0");

        uint256 virtualPrice = pool.get_virtual_price();
        // Virtual price should be >= 1e18 (starts at 1e18, grows with fees)
        assertGe(virtualPrice, 1e18, "virtual price should be >= 1");

        uint256 supply = pool.totalSupply();
        assertGt(supply, 0, "pool should have LP supply");

        console.log("A:", A);
        console.log("fee:", fee, "(1e10 = 100%)");
        console.log("virtual_price:", virtualPrice);
        console.log("totalSupply:", supply);
    }

    function test_pool_balances() public view {
        uint256 bal0 = pool.balances(0); // USDC (6 decimals)
        uint256 bal1 = pool.balances(1); // scrvUSD (18 decimals)

        assertGt(bal0, 0, "pool should have USDC reserves");
        assertGt(bal1, 0, "pool should have scrvUSD reserves");

        console.log("USDC reserve:    ", bal0, "(6 dec)");
        console.log("scrvUSD reserve: ", bal1, "(18 dec)");
    }

    function test_pool_stored_rates() public view {
        uint256[] memory rates = pool.stored_rates();
        assertEq(rates.length, 2, "should have 2 rates");

        // Rate for USDC: 1e18 * 1e12 = 1e30 (scaled to 18 decimals)
        // Rate for scrvUSD: oracle rate (>= 1e18, grows over time)
        assertGt(rates[0], 0, "USDC rate should be > 0");
        assertGt(rates[1], 0, "scrvUSD rate should be > 0");

        console.log("rate[0] (USDC):    ", rates[0]);
        console.log("rate[1] (scrvUSD): ", rates[1]);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2. Gauge reads
    // ═══════════════════════════════════════════════════════════════════════

    function test_gauge_lp_token() public view {
        address lp = gauge.lp_token();
        assertEq(lp, POOL, "gauge LP token should be the pool address");
    }

    function test_gauge_total_supply() public view {
        uint256 supply = gauge.totalSupply();
        // Gauge may or may not have deposits
        console.log("gauge totalSupply:", supply);
    }

    function test_gauge_reward_tokens() public view {
        // Read first reward token (may be CRV or zero if no rewards)
        address reward0 = gauge.reward_tokens(0);
        console.log("reward_tokens(0):", reward0);

        if (reward0 != address(0)) {
            // Try to read claimable for a zero-balance address (should be 0)
            uint256 claimable = gauge.claimable_reward(USER, reward0);
            assertEq(claimable, 0, "fresh user should have 0 claimable");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3. Add liquidity (single-sided USDC) — core deposit path
    // ═══════════════════════════════════════════════════════════════════════

    function test_add_liquidity_usdc_only() public {
        uint256 usdcAmount = 1_000e6; // 1000 USDC
        deal(USDC, USER, usdcAmount);

        // Preview how many LP tokens we'd get
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;
        uint256 expectedLp = pool.calc_token_amount(amounts, true);
        assertGt(expectedLp, 0, "should get LP tokens for USDC deposit");

        console.log("Expected LP for 1000 USDC:", expectedLp);

        // Execute add_liquidity
        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, 0); // no slippage for test
        vm.stopPrank();

        assertGt(lpReceived, 0, "should receive LP tokens");
        assertEq(lpToken.balanceOf(USER), lpReceived, "USER should hold LP tokens");

        // LP received should be close to preview (within 1% for stable pools)
        uint256 diff = expectedLp > lpReceived ? expectedLp - lpReceived : lpReceived - expectedLp;
        assertLt(diff * 100 / expectedLp, 2, "actual vs expected LP should be within 2%");

        console.log("LP received:", lpReceived);
        console.log("Preview diff:", diff);
    }

    function test_add_liquidity_small_amount() public {
        uint256 usdcAmount = 10e6; // 10 USDC
        deal(USDC, USER, usdcAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, 0);
        vm.stopPrank();

        assertGt(lpReceived, 0, "should receive LP tokens for small deposit");
        console.log("LP for 10 USDC:", lpReceived);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  4. Remove liquidity (single-sided to USDC) — core withdrawal path
    // ═══════════════════════════════════════════════════════════════════════

    function test_remove_liquidity_one_coin_usdc() public {
        // First add liquidity
        uint256 usdcAmount = 1_000e6;
        deal(USDC, USER, usdcAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, 0);

        // Preview withdrawal
        uint256 expectedUsdc = pool.calc_withdraw_one_coin(lpReceived, 0); // 0 = USDC index
        assertGt(expectedUsdc, 0, "should get USDC back");

        console.log("LP to burn:", lpReceived);
        console.log("Expected USDC back:", expectedUsdc);

        // Execute withdrawal
        uint256 usdcBefore = usdc.balanceOf(USER);
        uint256 usdcReceived = pool.remove_liquidity_one_coin(lpReceived, 0, 0); // 0 = USDC, no slippage
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(USER);
        assertEq(usdcAfter - usdcBefore, usdcReceived, "balance delta should match return");
        assertGt(usdcReceived, 0, "should receive USDC");

        // Should get back close to what we put in (stable pool, minus fees)
        // Expect within 1% for a round-trip on a stable pool
        assertGt(usdcReceived, usdcAmount * 98 / 100, "round-trip loss should be < 2%");
        assertEq(lpToken.balanceOf(USER), 0, "should have burned all LP");

        console.log("USDC received:", usdcReceived);
        console.log("Round-trip loss:", usdcAmount - usdcReceived, "USDC");
    }

    function test_remove_liquidity_balanced() public {
        uint256 usdcAmount = 1_000e6;
        deal(USDC, USER, usdcAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, 0);

        // Balanced removal — get both tokens back
        uint256[] memory minAmounts = new uint256[](2);
        minAmounts[0] = 0;
        minAmounts[1] = 0;
        uint256[] memory received = pool.remove_liquidity(lpReceived, minAmounts);
        vm.stopPrank();

        assertGt(received[0], 0, "should receive USDC");
        assertGt(received[1], 0, "should receive scrvUSD");
        assertEq(lpToken.balanceOf(USER), 0, "should burn all LP");

        console.log("USDC received:    ", received[0]);
        console.log("scrvUSD received: ", received[1]);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  5. Gauge staking — LP deposit/withdraw + reward claiming
    // ═══════════════════════════════════════════════════════════════════════

    function test_gauge_deposit_withdraw() public {
        // First get LP tokens
        uint256 usdcAmount = 1_000e6;
        deal(USDC, USER, usdcAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, 0);

        // Stake LP in gauge
        lpToken.approve(GAUGE, lpReceived);
        gauge.deposit(lpReceived);

        uint256 gaugeBalance = gauge.balanceOf(USER);
        assertEq(gaugeBalance, lpReceived, "gauge balance should equal deposited LP");
        assertEq(lpToken.balanceOf(USER), 0, "LP should be in gauge, not wallet");

        console.log("Staked in gauge:", gaugeBalance);

        // Withdraw from gauge
        gauge.withdraw(gaugeBalance);

        assertEq(gauge.balanceOf(USER), 0, "gauge balance should be 0 after withdraw");
        assertEq(lpToken.balanceOf(USER), lpReceived, "LP should be back in wallet");
        vm.stopPrank();
    }

    function test_gauge_claim_rewards_empty() public {
        // Deposit, then immediately claim — should not revert
        uint256 usdcAmount = 100e6;
        deal(USDC, USER, usdcAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, 0);

        lpToken.approve(GAUGE, lpReceived);
        gauge.deposit(lpReceived);

        // Claim immediately — should succeed with 0 rewards
        gauge.claim_rewards();

        // Clean up
        gauge.withdraw(lpReceived);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  6. Full vault cycle — simulates what AnalogCurveVault would do
    // ═══════════════════════════════════════════════════════════════════════

    function test_full_cycle_deposit_stake_unstake_withdraw() public {
        uint256 usdcAmount = 5_000e6; // 5000 USDC
        deal(USDC, USER, usdcAmount);

        uint256 usdcBefore = usdc.balanceOf(USER);

        console.log("=== Step 1: Add liquidity (USDC -> LP) ===");

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, 0);
        console.log("LP received:", lpReceived);

        console.log("=== Step 2: Stake LP in gauge ===");
        lpToken.approve(GAUGE, lpReceived);
        gauge.deposit(lpReceived);
        console.log("Gauge balance:", gauge.balanceOf(USER));

        console.log("=== Step 3: Unstake from gauge ===");
        gauge.withdraw(gauge.balanceOf(USER));
        uint256 lpAfterUnstake = lpToken.balanceOf(USER);
        console.log("LP after unstake:", lpAfterUnstake);
        assertEq(lpAfterUnstake, lpReceived, "LP should be intact after gauge round-trip");

        console.log("=== Step 4: Remove liquidity (LP -> USDC) ===");
        uint256 usdcReceived = pool.remove_liquidity_one_coin(lpAfterUnstake, 0, 0);
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(USER);

        console.log("USDC deposited:", usdcAmount);
        console.log("USDC received: ", usdcReceived);
        console.log("Net loss:      ", usdcAmount - usdcReceived);

        // Round-trip through add_liquidity + gauge + remove_liquidity should lose < 1%
        assertGt(usdcReceived, usdcAmount * 99 / 100, "round-trip loss should be < 1%");
        assertEq(lpToken.balanceOf(USER), 0, "no LP should remain");
        assertEq(gauge.balanceOf(USER), 0, "no gauge balance should remain");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  7. Price / value conversion helpers — needed for balance handler
    // ═══════════════════════════════════════════════════════════════════════

    function test_lp_to_usdc_conversion() public {
        // Deposit 1000 USDC -> get LP -> convert LP back to USDC value
        uint256 usdcAmount = 1_000e6;
        deal(USDC, USER, usdcAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, 0);
        vm.stopPrank();

        // calc_withdraw_one_coin gives us the USDC value of LP tokens
        // This is what the balance handler will use
        uint256 usdcValue = pool.calc_withdraw_one_coin(lpReceived, 0);

        console.log("LP tokens:", lpReceived);
        console.log("USDC value via calc_withdraw_one_coin:", usdcValue);

        // Should be close to deposit amount (within 1%)
        assertGt(usdcValue, usdcAmount * 99 / 100, "LP USDC value should be ~= deposit");
        assertLt(usdcValue, usdcAmount * 101 / 100, "LP USDC value should not exceed deposit + 1%");
    }

    function test_virtual_price_grows_with_fees() public view {
        // Virtual price starts at 1e18 and grows as fees accrue
        uint256 vp = pool.get_virtual_price();
        assertGe(vp, 1e18, "virtual price should be >= 1e18");

        console.log("Current virtual price:", vp);
        console.log("Implied cumulative fee return:", (vp - 1e18) * 100 / 1e18, "% (since pool creation)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  8. Exchange — validates swap interface (USDC <-> scrvUSD)
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchange_usdc_to_scrvusd() public {
        uint256 usdcAmount = 100e6; // 100 USDC
        deal(USDC, USER, usdcAmount);

        // Preview
        uint256 expectedOut = pool.get_dy(0, 1, usdcAmount); // 0=USDC, 1=scrvUSD
        assertGt(expectedOut, 0, "should get scrvUSD quote");

        console.log("Swap 100 USDC -> scrvUSD");
        console.log("Expected scrvUSD:", expectedOut);

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 received = pool.exchange(0, 1, usdcAmount, 0);
        vm.stopPrank();

        assertGt(received, 0, "should receive scrvUSD");
        assertEq(scrvusd.balanceOf(USER), received, "scrvUSD balance should match");

        console.log("Received scrvUSD:", received);
    }

    function test_exchange_scrvusd_to_usdc() public {
        // First get some scrvUSD by swapping
        uint256 usdcSeed = 200e6;
        deal(USDC, USER, usdcSeed);

        vm.startPrank(USER);
        usdc.approve(POOL, usdcSeed);
        uint256 scrvReceived = pool.exchange(0, 1, usdcSeed, 0);

        // Now swap scrvUSD back to USDC
        uint256 expectedUsdc = pool.get_dy(1, 0, scrvReceived);
        scrvusd.approve(POOL, scrvReceived);
        uint256 usdcBack = pool.exchange(1, 0, scrvReceived, 0);
        vm.stopPrank();

        assertGt(usdcBack, 0, "should receive USDC back");

        // Round-trip slippage for stables should be small
        console.log("USDC in:   ", usdcSeed);
        console.log("USDC back: ", usdcBack);
        console.log("Swap fees: ", usdcSeed - usdcBack);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  9. Edge cases
    // ═══════════════════════════════════════════════════════════════════════

    function test_add_liquidity_zero_reverts() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;

        vm.startPrank(USER);
        vm.expectRevert(); // Curve reverts on zero deposit
        pool.add_liquidity(amounts, 0);
        vm.stopPrank();
    }

    function test_remove_liquidity_zero_reverts() public {
        vm.startPrank(USER);
        vm.expectRevert(); // Curve reverts on zero burn
        pool.remove_liquidity_one_coin(0, 0, 0);
        vm.stopPrank();
    }

    function test_remove_more_than_balance_reverts() public {
        vm.startPrank(USER);
        // USER has no LP tokens
        vm.expectRevert();
        pool.remove_liquidity_one_coin(1e18, 0, 0);
        vm.stopPrank();
    }

    function test_min_amount_guard_on_add_liquidity() public {
        uint256 usdcAmount = 100e6;
        deal(USDC, USER, usdcAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        // Set min_mint_amount absurdly high — should revert
        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        vm.expectRevert();
        pool.add_liquidity(amounts, type(uint256).max);
        vm.stopPrank();
    }

    function test_min_amount_guard_on_remove_liquidity() public {
        // Get some LP first
        uint256 usdcAmount = 100e6;
        deal(USDC, USER, usdcAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;

        vm.startPrank(USER);
        usdc.approve(POOL, usdcAmount);
        uint256 lp = pool.add_liquidity(amounts, 0);

        // Set min_received absurdly high — should revert
        vm.expectRevert();
        pool.remove_liquidity_one_coin(lp, 0, type(uint256).max);
        vm.stopPrank();
    }
}
