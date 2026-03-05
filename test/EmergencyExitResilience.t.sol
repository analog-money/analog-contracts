// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseVault} from "../src/BaseVault.sol";
import {IHedgedVault} from "../src/interfaces/IHedgedVault.sol";

/**
 * @title MockVault
 * @notice Concrete BaseVault where AMM withdraw and swap behavior can be configured to revert
 */
contract MockVault is BaseVault {
    using SafeERC20 for IERC20;

    bool public shouldRevertWithdraw;
    bool public shouldRevertSwap;
    address public otherToken;

    constructor(address _usdc) BaseVault(_usdc) {}

    function initializeVault(address _owner, address _controller) external initializer {
        initialize(_owner, _controller);
    }

    function setShouldRevertWithdraw(bool _revert) external {
        shouldRevertWithdraw = _revert;
    }

    function setShouldRevertSwap(bool _revert) external {
        shouldRevertSwap = _revert;
    }

    function setOtherToken(address _token) external {
        otherToken = _token;
    }

    // === Abstract implementations ===

    function getVaultEquity() public view override returns (uint256) {
        return IERC20(USDC).balanceOf(address(this));
    }

    function balances() external view override returns (uint256 amount0, uint256 amount1) {
        amount0 = IERC20(USDC).balanceOf(address(this));
        amount1 = 0;
    }

    function _deployToAMM(uint256) internal pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function _withdrawFromAMM(uint256) internal pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function _withdrawAllFromAMM() internal view override {
        if (shouldRevertWithdraw) revert("AMM_WITHDRAW_FAILED");
    }

    function _swapAllToUSDC() internal view override {
        if (shouldRevertSwap) revert("SWAP_FAILED");
    }

    function _calculateAMMDelta() internal pure override returns (uint256) {
        return 0;
    }

    function _rebalanceAMM() internal pure override {}

    function _harvestFees() internal pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function _getAMMPositionValue() internal pure override returns (uint256) {
        return 0;
    }

    function _getUnclaimedFees() internal pure override returns (uint256) {
        return 0;
    }
}

/**
 * @title MockERC20
 * @notice Minimal ERC20 for testing rescueTokens
 */
contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/**
 * @title EmergencyExitResilienceTest
 * @notice Tests that emergencyExit cannot be bricked by reverting AMM/swap calls
 *
 * To run:
 *   forge test --match-contract EmergencyExitResilienceTest -vvv
 */
contract EmergencyExitResilienceTest is Test {
    MockVault public vaultImpl;
    MockVault public vault;
    MockERC20 public usdc;
    MockERC20 public weth;

    address constant OWNER = address(0xAAAA);
    address constant CONTROLLER = address(0xBBBB);

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20();
        weth = new MockERC20();

        // Deploy vault implementation
        vaultImpl = new MockVault(address(usdc));

        // Deploy vault behind UUPS proxy
        bytes memory initData = abi.encodeWithSelector(
            MockVault.initializeVault.selector,
            OWNER,
            CONTROLLER
        );
        vault = MockVault(payable(address(new ERC1967Proxy(address(vaultImpl), initData))));

        // Seed vault with some USDC
        usdc.mint(address(vault), 1000e6);
    }

    function test_emergencyExit_succeeds_when_swap_reverts() public {
        // Configure: withdraw works, swap reverts
        vault.setShouldRevertSwap(true);

        vm.prank(OWNER);
        vault.emergencyExit();

        // Verify state
        assertTrue(vault.emergencyExitTriggered(), "Emergency flag should be set");
        assertTrue(vault.paused(), "Vault should be paused");
        assertEq(vault.totalShares(), 0, "Shares should be zeroed");

        // USDC was transferred to owner (swap failed but USDC was already in vault)
        assertEq(usdc.balanceOf(OWNER), 1000e6, "Owner should receive USDC");
    }

    function test_emergencyExit_succeeds_when_everything_reverts() public {
        // Configure: both withdraw and swap revert
        vault.setShouldRevertWithdraw(true);
        vault.setShouldRevertSwap(true);

        vm.prank(OWNER);
        vault.emergencyExit();

        // Verify state — emergency exit completes even though both steps failed
        assertTrue(vault.emergencyExitTriggered(), "Emergency flag should be set");
        assertTrue(vault.paused(), "Vault should be paused");
        assertEq(vault.totalShares(), 0, "Shares should be zeroed");

        // USDC that was idle in vault still gets transferred to owner
        assertEq(usdc.balanceOf(OWNER), 1000e6, "Owner should receive idle USDC");
    }

    function test_emergencyExit_succeeds_when_withdraw_reverts() public {
        // Configure: withdraw reverts, swap works
        vault.setShouldRevertWithdraw(true);

        vm.prank(OWNER);
        vault.emergencyExit();

        assertTrue(vault.emergencyExitTriggered(), "Emergency flag should be set");
        assertTrue(vault.paused(), "Vault should be paused");
        assertEq(usdc.balanceOf(OWNER), 1000e6, "Owner should receive USDC");
    }

    function test_emergencyExit_normal_path_still_works() public {
        // Both steps succeed (default behavior)
        vm.prank(OWNER);
        vault.emergencyExit();

        assertTrue(vault.emergencyExitTriggered(), "Emergency flag should be set");
        assertTrue(vault.paused(), "Vault should be paused");
        assertEq(usdc.balanceOf(OWNER), 1000e6, "Owner should receive USDC");
    }

    function test_rescueTokens_extracts_stuck_tokens() public {
        // Simulate: emergency exit with stuck WETH
        vault.setShouldRevertSwap(true);
        weth.mint(address(vault), 5e18);

        vm.prank(OWNER);
        vault.emergencyExit();

        // WETH is still stuck in vault (swap failed)
        assertEq(weth.balanceOf(address(vault)), 5e18, "WETH should be stuck");

        // Rescue WETH
        vm.prank(OWNER);
        vault.rescueTokens(address(weth), OWNER);

        assertEq(weth.balanceOf(OWNER), 5e18, "Owner should receive rescued WETH");
        assertEq(weth.balanceOf(address(vault)), 0, "Vault should have no WETH");
    }

    function test_rescueTokens_reverts_before_emergency() public {
        weth.mint(address(vault), 5e18);

        // Should revert — emergency exit hasn't been triggered
        vm.prank(OWNER);
        vm.expectRevert(IHedgedVault.InvalidOperation.selector);
        vault.rescueTokens(address(weth), OWNER);
    }

    function test_rescueTokens_reverts_with_zero_address() public {
        // Trigger emergency first
        vm.prank(OWNER);
        vault.emergencyExit();

        // Should revert — to is address(0)
        vm.prank(OWNER);
        vm.expectRevert(IHedgedVault.InvalidAddress.selector);
        vault.rescueTokens(address(weth), address(0));
    }

    function test_rescueTokens_noop_for_zero_balance() public {
        // Trigger emergency first
        vm.prank(OWNER);
        vault.emergencyExit();

        // Should not revert, just no-op
        vm.prank(OWNER);
        vault.rescueTokens(address(weth), OWNER);

        assertEq(weth.balanceOf(OWNER), 0, "No tokens to rescue");
    }

    function test_doEmergencyWithdrawFromAMM_rejects_external_caller() public {
        vm.prank(OWNER);
        vm.expectRevert(IHedgedVault.OnlySelf.selector);
        vault.doEmergencyWithdrawFromAMM();
    }

    function test_doEmergencySwapAllToUSDC_rejects_external_caller() public {
        vm.prank(OWNER);
        vm.expectRevert(IHedgedVault.OnlySelf.selector);
        vault.doEmergencySwapAllToUSDC();
    }
}
