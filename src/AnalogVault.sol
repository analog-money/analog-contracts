// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BeefyVaultConcLiq} from "beefy-zk/vault/BeefyVaultConcLiq.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    SafeERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// VaultMath removed - calculation moved off-chain to reduce contract size
import {SwapExecutor, SwapCall} from "./libraries/SwapExecutor.sol";
import {ConfigChangeExecutor} from "./libraries/ConfigChangeExecutor.sol";

interface IStrategyConfig {
    function setPositionWidth(int24 _width) external;
    function setDeviation(int56 _maxDeviation) external;
    function setTwapInterval(uint32 _interval) external;
}

interface IAnalogVaultFactory {
    function latestImplementation() external view returns (address);
    function strategyFactory() external view returns (address);
}

interface IStrategyFactory {
    function latestImplementation(string calldata name) external view returns (address);
}

interface IUUPS {
    function upgradeToLatest() external;
    function getImplementation() external view returns (address);
}

contract AnalogVault is BeefyVaultConcLiq, UUPSUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20 for IERC20;

    address private constant ROUTER =
        0x111111125421cA6dc452d289314280a0f8842A65;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address public usdc;
    address public factory;
    address public controller;

    enum ConfigChangeType {
        None,
        PositionWidth,
        Deviation,
        TwapInterval
    }

    struct PendingOps {
        uint128 depositUsdc;
        uint128 withdrawUsdc;
        uint128 swapToken0;
        uint128 swapToken1;
        uint128 deployAmount0;
        uint128 deployAmount1;
        address swapRecipient;
        ConfigChangeType configType;
        int256 configValue;
        uint8 flags; // bit 0: deposit, bit 1: withdraw, bit 2: swap, bit 3: config, bit 4: deploy
    }

    PendingOps public pending;
    event DepositReg(uint256 usdcAmount);
    event DepositExec(uint256 amount0, uint256 amount1);
    event DepositCancel();
    event WithdrawReg(uint256 usdcAmount, address indexed recipient);
    event WithdrawExec(
        uint256 token0Amount,
        uint256 token1Amount,
        address indexed recipient
    );
    event WithdrawCancel();
    event SwapExec(uint256 usdcAmount, address indexed recipient);
    event SwapCancel();
    event DeployReg(uint256 amount0, uint256 amount1);
    event DeployExec(uint256 amount0, uint256 amount1);
    event DeployCancel();
    event CtrlUpdated(address indexed newController);
    event ConfigQueued(ConfigChangeType indexed changeType, int256 value);
    event ConfigExec(ConfigChangeType indexed changeType, int256 value);


    error OnlyOwner();
    error OnlyCtrl();
    error OnlyFact();
    error NotCalm();
    error Invalid();
    error SwapFail();
    error Insufficient();
    error NoDeposit();
    error NoWithdraw();
    error NoSwap();
    error NoDeploy();
    error DepositPending();
    error WithdrawPending();
    error SwapPending();
    error DeployPending();
    error NoConfig();
    error ConfigPending();
    error InvalidImpl();
    modifier onlyController() {
        if (msg.sender != controller) revert OnlyCtrl();
        _;
    }
    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFact();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _strategy,
        string calldata _name,
        string calldata _symbol,
        address _controller,
        address _owner
    ) external initializer {
        factory = msg.sender;
        usdc = USDC;
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        strategy = IStrategyConcLiq(_strategy);
        _transferOwnership(_owner);
        controller = _controller;
        
        
        emit CtrlUpdated(_controller);
    }

    function deposit(uint256 usdcAmount) external onlyOwner nonReentrant {
        if (
            usdcAmount == 0 ||
            IERC20(usdc).balanceOf(msg.sender) < usdcAmount ||
            pending.flags & 1 != 0
        ) revert Insufficient();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);
        pending.depositUsdc = uint128(usdcAmount);
        pending.flags |= 1;
        emit DepositReg(usdcAmount);
    }

    function swapAndDeploy(
        SwapCall[] calldata calls,
        uint256 amount0,
        uint256 amount1
    ) external onlyController nonReentrant {
        if (pending.flags & 1 == 0) revert NoDeposit();
        uint256 usdcAmount = pending.depositUsdc;
        pending.depositUsdc = 0;
        pending.flags &= ~uint8(1);
        if (IERC20(usdc).balanceOf(address(this)) < usdcAmount)
            revert Insufficient();
        if (calls.length > 0) SwapExecutor.executeSwaps(calls, ROUTER);
        (address token0, address token1) = wants();
        uint256 amt0 = amount0 == 0
            ? IERC20(token0).balanceOf(address(this))
            : amount0;
        uint256 amt1 = amount1 == 0
            ? IERC20(token1).balanceOf(address(this))
            : amount1;
        if (amt0 > 0 || amt1 > 0) {
            if (this.isCalm()) {
                _deployToStrategy(token0, token1, amt0, amt1);
                emit DepositExec(amt0, amt1);
            } else {
                pending.deployAmount0 = uint128(amt0);
                pending.deployAmount1 = uint128(amt1);
                pending.flags |= 16;
                emit DeployReg(amt0, amt1);
            }
        }
    }

    function withdraw(uint256 usdcAmount) external onlyOwner nonReentrant {
        if (usdcAmount == 0) revert Insufficient();
        uint8 f = pending.flags;
        if (f & 1 != 0) revert DepositPending();
        if (f & 2 != 0) revert WithdrawPending();
        if (f & 16 != 0) revert DeployPending();
        pending.withdrawUsdc = uint128(usdcAmount);
        pending.flags = f | 2;
        emit WithdrawReg(usdcAmount, owner());
    }

    function executeWithdrawal() external onlyController nonReentrant {
        if (pending.flags & 2 == 0) revert NoWithdraw();
        pending.withdrawUsdc = 0;
        pending.flags &= ~uint8(2);
        strategy.beforeAction();
        (uint256 _bal0, uint256 _bal1) = balances();
        (address token0, address token1) = wants();
        uint256 bal0Before = IERC20(token0).balanceOf(address(this));
        uint256 bal1Before = IERC20(token1).balanceOf(address(this));
        
        // Only call strategy.withdraw if there are balances to withdraw
        // This prevents reverts when strategy has zero balance
        if (_bal0 > 0 || _bal1 > 0) {
            // Use try-catch to handle any underlying strategy errors gracefully
            try strategy.withdraw(_bal0, _bal1) {} catch (bytes memory) {
                // If strategy.withdraw fails, we still check for tokens that may have been
                // transferred to the vault directly (e.g., from previous failed operations)
                // Continue execution to check vault balances
            }
        }
        
        uint256 delta0 = IERC20(token0).balanceOf(address(this)) - bal0Before;
        uint256 delta1 = IERC20(token1).balanceOf(address(this)) - bal1Before;
        if (delta0 > 0 || delta1 > 0) {
            pending.swapToken0 = uint128(delta0);
            pending.swapToken1 = uint128(delta1);
            pending.swapRecipient = owner();
            pending.flags |= 4;
        }
        uint256 rem0 = _bal0 - delta0;
        uint256 rem1 = _bal1 - delta1;
        if ((rem0 > 0 || rem1 > 0) && this.isCalm()) {
            _deployToStrategy(token0, token1, rem0, rem1);
        }
        emit WithdrawExec(delta0, delta1, owner());
    }

    function executeSwap(
        SwapCall[] calldata calls,
        uint256 minAmountOut
    ) external onlyController nonReentrant {
        if (pending.flags & 4 == 0) revert NoSwap();
        
        address recipient = pending.swapRecipient;
        
        // Clear pending swap state
        pending.swapToken0 = 0;
        pending.swapToken1 = 0;
        pending.swapRecipient = address(0);
        pending.flags &= ~uint8(4);

        // Approvals done once in initialize()
        SwapExecutor.executeSwaps(calls, ROUTER);

        uint256 totalUsdcAvailable = IERC20(usdc).balanceOf(address(this));
        
        // We must have at least minAmountOut (which is the backend's quoted amount minus slippage)
        if (totalUsdcAvailable < minAmountOut) revert Insufficient();

        if (totalUsdcAvailable > 0) {
            IERC20(usdc).safeTransfer(recipient, totalUsdcAvailable);
            emit SwapExec(totalUsdcAvailable, recipient);
        }
    }

    function executeDeploy() external onlyController nonReentrant {
        if (pending.flags & 16 == 0) revert NoDeploy();
        if (!this.isCalm()) revert NotCalm();
        uint128 amt0 = pending.deployAmount0;
        uint128 amt1 = pending.deployAmount1;
        pending.deployAmount0 = 0;
        pending.deployAmount1 = 0;
        pending.flags &= ~uint8(16);
        if (amt0 > 0 || amt1 > 0) {
            (address token0, address token1) = wants();
            _deployToStrategy(token0, token1, amt0, amt1);
            emit DeployExec(amt0, amt1);
        }
    }

    function _deployToStrategy(
        address token0,
        address token1,
        uint256 amt0,
        uint256 amt1
    ) internal {
        strategy.beforeAction();
        if (amt0 > 0)
            IERC20Upgradeable(token0).safeTransfer(address(strategy), amt0);
        if (amt1 > 0)
            IERC20Upgradeable(token1).safeTransfer(address(strategy), amt1);
        strategy.deposit();
    }

    function cancel(uint8 typ) external onlyOwner {
        if (typ == 1) {
            if (pending.flags & 1 == 0) revert NoDeposit();
            pending.depositUsdc = 0;
            pending.flags &= ~uint8(1);
            emit DepositCancel();
        } else if (typ == 2) {
            if (pending.flags & 2 == 0) revert NoWithdraw();
            pending.withdrawUsdc = 0;
            pending.flags &= ~uint8(2);
            emit WithdrawCancel();
        } else if (typ == 4) {
            if (pending.flags & 4 == 0) revert NoSwap();
            pending.swapToken0 = 0;
            pending.swapToken1 = 0;
            pending.swapRecipient = address(0);
            pending.flags &= ~uint8(4);
            emit SwapCancel();
        } else if (typ == 16) {
            if (pending.flags & 16 == 0) revert NoDeploy();
            pending.deployAmount0 = 0;
            pending.deployAmount1 = 0;
            pending.flags &= ~uint8(16);
            emit DeployCancel();
        } else {
            revert Invalid();
        }
    }

    function swapTokensToUSDC(
        SwapCall[] calldata calls,
        uint256 amount0,
        uint256 amount1
    ) external onlyController nonReentrant {
        if (pending.flags & 3 != 0) revert DepositPending(); // bits 0, 1
        (address token0, address token1) = wants();
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 amt0 = amount0 > 0 ? amount0 : bal0;
        uint256 amt1 = amount1 > 0 ? amount1 : bal1;
        if ((amt0 == 0 && amt1 == 0) || amt0 > bal0 || amt1 > bal1)
            revert Insufficient();
        address ownerAddr = owner();
        uint256 total = 0;
        if (token0 == usdc && amt0 > 0) {
            total = amt0;
            IERC20(usdc).safeTransfer(ownerAddr, amt0);
        }
        if (token1 == usdc && amt1 > 0) {
            total += amt1;
            IERC20(usdc).safeTransfer(ownerAddr, amt1);
        }
        uint256 before = IERC20(usdc).balanceOf(address(this));
        SwapExecutor.executeSwaps(calls, ROUTER);
        uint256 received = IERC20(usdc).balanceOf(address(this)) - before;
        if (received > 0) {
            total += received;
            IERC20(usdc).safeTransfer(ownerAddr, received);
        }
        if (total > 0) emit SwapExec(total, ownerAddr);
    }

    function queueConfigChange(
        ConfigChangeType changeType,
        int256 value
    ) external onlyOwner {
        if (changeType == ConfigChangeType.None) revert Invalid();
        if (pending.flags & 8 != 0) revert ConfigPending();
        pending.configType = changeType;
        pending.configValue = value;
        pending.flags |= 8;
        emit ConfigQueued(changeType, value);
    }

    function executeConfigChange() external onlyController nonReentrant {
        if (pending.flags & 8 == 0) revert NoConfig();
        if (!this.isCalm()) revert NotCalm();
        ConfigChangeType typ = pending.configType;
        int256 val = pending.configValue;
        pending.configType = ConfigChangeType.None;
        pending.configValue = 0;
        pending.flags &= ~uint8(8);
        IStrategyConfig cfg = IStrategyConfig(address(strategy));
        if (typ == ConfigChangeType.PositionWidth)
            cfg.setPositionWidth(int24(val));
        else if (typ == ConfigChangeType.Deviation)
            cfg.setDeviation(int56(val));
        else if (typ == ConfigChangeType.TwapInterval)
            cfg.setTwapInterval(uint32(uint256(val)));
        emit ConfigExec(typ, val);
    }

    function getPendingStates()
        external
        view
        returns (
            uint256 depositAmount,
            bool depositPending,
            uint256 withdrawalAmount,
            bool withdrawalPending,
            uint256 swapToken0,
            uint256 swapToken1,
            address swapRecipient,
            bool swapPending,
            uint256 deployAmount0,
            uint256 deployAmount1,
            bool deployPending,
            ConfigChangeType configType,
            int256 configValue,
            bool configPending
        )
    {
        return (
            pending.depositUsdc,
            pending.flags & 1 != 0,
            pending.withdrawUsdc,
            pending.flags & 2 != 0,
            pending.swapToken0,
            pending.swapToken1,
            pending.swapRecipient,
            pending.flags & 4 != 0,
            pending.deployAmount0,
            pending.deployAmount1,
            pending.flags & 16 != 0,
            pending.configType,
            pending.configValue,
            pending.flags & 8 != 0
        );
    }

    function setController(address _controller) external {
        if (msg.sender != owner()) revert OnlyOwner();
        controller = _controller;
        emit CtrlUpdated(_controller);
    }

    function approveSwaps() external {
        if (msg.sender != controller && msg.sender != owner())
            revert OnlyCtrl();
        (address token0, address token1) = wants();
        IERC20(USDC).safeApprove(ROUTER, 0);
        IERC20(token0).safeApprove(ROUTER, 0);
        IERC20(token1).safeApprove(ROUTER, 0);
        IERC20(USDC).safeApprove(ROUTER, type(uint256).max);
        IERC20(token0).safeApprove(ROUTER, type(uint256).max);
        IERC20(token1).safeApprove(ROUTER, type(uint256).max);
    }

    receive() external payable {}

    function _authorizeUpgrade(address impl) internal view override {
        address latest = IAnalogVaultFactory(factory).latestImplementation();
        if (impl != latest || impl == address(0)) revert InvalidImpl();
    }

    function upgradeToLatest() external onlyOwner {
        IAnalogVaultFactory fact = IAnalogVaultFactory(factory);
        
        // 1. Upgrade self
        address latestVault = fact.latestImplementation();
        if (latestVault != address(0) && latestVault != _getImplementation()) {
            delete pending;
            _upgradeToAndCall(latestVault, new bytes(0), false);
        }
        
        // 2. Upgrade strategy
        address stratFactoryAddress = fact.strategyFactory();
        if (stratFactoryAddress != address(0)) {
            address latestStrat = IStrategyFactory(stratFactoryAddress).latestImplementation("StrategyPassiveManagerUniswap");
            if (latestStrat != address(0)) {
                // Check if strategy is upgradeable by attempting to call getImplementation or upgradeToLatest
                try IUUPS(address(strategy)).upgradeToLatest() {} catch {}
            }
        }
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

}
