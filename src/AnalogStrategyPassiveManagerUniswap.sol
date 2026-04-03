// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin-4/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin-4/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignedMath} from "@openzeppelin-4/contracts/utils/math/SignedMath.sol";
import {StratFeeManagerInitializable, IFeeConfig} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import {IUniswapV3Pool} from "beefy-zk/interfaces/uniswap/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "beefy-zk/utils/LiquidityAmounts.sol";
import {TickMath} from "beefy-zk/utils/TickMath.sol";
import {TickUtils, FullMath} from "beefy-zk/utils/TickUtils.sol";
import {UniV3Utils} from "beefy-zk/utils/UniV3Utils.sol";
import {IBeefyVaultConcLiq} from "beefy-zk/interfaces/beefy/IBeefyVaultConcLiq.sol";
import {IStrategyFactory} from "beefy-zk/interfaces/beefy/IStrategyFactory.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";
import {IStrategyUniswapV3} from "beefy-zk/interfaces/beefy/IStrategyUniswapV3.sol";
import {IBeefySwapper} from "beefy-zk/interfaces/beefy/IBeefySwapper.sol";
import {IQuoter} from "beefy-zk/interfaces/uniswap/IQuoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IAnalogStrategyFactory {
    function latestImplementation(string calldata strategyName) external view returns (address);
}

/// @title Analog Passive Position Manager — Uniswap V3
/// @author Forked from Beefy (weso). Modified by Analog.
/// @notice UUPS-upgradeable concentrated liquidity strategy for Uniswap V3 pools.
/// @dev Fork of beefy-zk StrategyPassiveManagerUniswap with two changes:
///      1. moveTicks() gated by onlyOwner (owner = vault) so rebalance is routed
///         through vault.rebalanceAMM().
///      2. UUPS upgradeability via factory-signaled implementations.
contract AnalogStrategyPassiveManagerUniswap is StratFeeManagerInitializable, IStrategyConcLiq, IStrategyUniswapV3, UUPSUpgradeable {
    using SafeERC20 for IERC20Metadata;
    using TickMath for int24;

    uint256 private constant PRECISION = 1e36;
    uint256 private constant SQRT_PRECISION = 1e18;

    int56 private constant MIN_TICK = -887272;
    int56 private constant MAX_TICK = 887272;

    address public pool;
    address public quoter;
    address public lpToken0;
    address public lpToken1;

    uint256 public fees0;
    uint256 public fees1;

    bytes public lpToken0ToNativePath;
    bytes public lpToken1ToNativePath;

    struct Position {
        int24 tickLower;
        int24 tickUpper;
    }

    Position public positionMain;
    Position public positionAlt;

    int24 public positionWidth;
    int56 public maxTickDeviation;
    uint32 public twapInterval;

    bool private minting;
    bool private initTicks;
    uint256 private lastDeposit;

    error NotAuthorized();
    error NotPool();
    error InvalidEntry();
    error NotVault();
    error InvalidInput();
    error InvalidOutput();
    error NotCalm();
    error TooMuchSlippage();
    error InvalidTicks();

    event TVL(uint256 bal0, uint256 bal1);
    event Harvest(uint256 fee0, uint256 fee1);
    event SetPositionWidth(int24 oldWidth, int24 width);
    event SetDeviation(int56 maxTickDeviation);
    event SetTwapInterval(uint32 oldInterval, uint32 interval);
    event SetLpToken0ToNativePath(bytes path);
    event SetLpToken1ToNativePath(bytes path);
    event SetQuoter(address quoter);
    event ChargedFees(uint256 callFeeAmount, uint256 beefyFeeAmount, uint256 strategistFeeAmount);
    event ClaimedFees(uint256 feeMain0, uint256 feeMain1, uint256 feeAlt0, uint256 feeAlt1);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyCalmPeriods() {
        _onlyCalmPeriods();
        _;
    }

    function _onlyCalmPeriods() private view {
        if (!isCalm()) revert NotCalm();
    }

    function isCalm() public view returns (bool) {
        int24 tick = currentTick();
        int56 twapTick = twap();

        int56 minCalmTick = int56(SignedMath.max(twapTick - maxTickDeviation, MIN_TICK));
        int56 maxCalmTick = int56(SignedMath.min(twapTick + maxTickDeviation, MAX_TICK));

        if (minCalmTick > tick || maxCalmTick < tick) return false;
        else return true;
    }

    function initialize(
        address _pool,
        address _quoter,
        int24 _positionWidth,
        bytes calldata _lpToken0ToNativePath,
        bytes calldata _lpToken1ToNativePath,
        CommonAddresses calldata _commonAddresses
    ) external initializer {
        __StratFeeManager_init(_commonAddresses);

        pool = _pool;
        quoter = _quoter;
        lpToken0 = IUniswapV3Pool(_pool).token0();
        lpToken1 = IUniswapV3Pool(_pool).token1();

        positionWidth = _positionWidth;

        setLpToken0ToNativePath(_lpToken0ToNativePath);
        setLpToken1ToNativePath(_lpToken1ToNativePath);

        twapInterval = 120;

        _giveAllowances();
    }

    function _onlyVault() private view {
        if (msg.sender != vault) revert NotVault();
    }

    function beforeAction() external {
        _onlyVault();
        _claimEarnings();
        _removeLiquidity();
    }

    function deposit() external onlyCalmPeriods {
        _onlyVault();

        if (!initTicks) {
            _setTicks();
            initTicks = true;
        }

        _addLiquidity();

        (uint256 bal0, uint256 bal1) = balances();

        lastDeposit = block.timestamp;

        emit TVL(bal0, bal1);
    }

    function withdraw(uint256 _amount0, uint256 _amount1) external {
        _onlyVault();

        if (block.timestamp == lastDeposit) _onlyCalmPeriods();

        if (_amount0 > 0) IERC20Metadata(lpToken0).safeTransfer(vault, _amount0);
        if (_amount1 > 0) IERC20Metadata(lpToken1).safeTransfer(vault, _amount1);

        if (!_isPaused()) _addLiquidity();

        (uint256 bal0, uint256 bal1) = balances();

        emit TVL(bal0, bal1);
    }

    function _addLiquidity() private onlyCalmPeriods {
        _whenStrategyNotPaused();

        (uint256 bal0, uint256 bal1) = balancesOfThis();

        uint160 sqrtprice = sqrtPrice();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtprice,
            TickMath.getSqrtRatioAtTick(positionMain.tickLower),
            TickMath.getSqrtRatioAtTick(positionMain.tickUpper),
            bal0,
            bal1
        );

        bool amountsOk = _checkAmounts(liquidity, positionMain.tickLower, positionMain.tickUpper);

        if (liquidity > 0 && amountsOk) {
            minting = true;
            IUniswapV3Pool(pool).mint(address(this), positionMain.tickLower, positionMain.tickUpper, liquidity, "Beefy Main");
        } else _onlyCalmPeriods();

        (bal0, bal1) = balancesOfThis();

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtprice,
            TickMath.getSqrtRatioAtTick(positionAlt.tickLower),
            TickMath.getSqrtRatioAtTick(positionAlt.tickUpper),
            bal0,
            bal1
        );

        if (liquidity > 0) {
            minting = true;
            IUniswapV3Pool(pool).mint(address(this), positionAlt.tickLower, positionAlt.tickUpper, liquidity, "Beefy Alt");
        }
    }

    function _removeLiquidity() private {
        (bytes32 keyMain, bytes32 keyAlt) = getKeys();

        (uint128 liquidity,,,,) = IUniswapV3Pool(pool).positions(keyMain);
        (uint128 liquidityAlt,,,,) = IUniswapV3Pool(pool).positions(keyAlt);

        if (liquidity > 0) {
            IUniswapV3Pool(pool).burn(positionMain.tickLower, positionMain.tickUpper, liquidity);
            IUniswapV3Pool(pool).collect(address(this), positionMain.tickLower, positionMain.tickUpper, type(uint128).max, type(uint128).max);
        }

        if (liquidityAlt > 0) {
            IUniswapV3Pool(pool).burn(positionAlt.tickLower, positionAlt.tickUpper, liquidityAlt);
            IUniswapV3Pool(pool).collect(address(this), positionAlt.tickLower, positionAlt.tickUpper, type(uint128).max, type(uint128).max);
        }
    }

    function _checkAmounts(uint128 _liquidity, int24 _tickLower, int24 _tickUpper) private view returns (bool) {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPrice(),
            TickMath.getSqrtRatioAtTick(_tickLower),
            TickMath.getSqrtRatioAtTick(_tickUpper),
            _liquidity
        );

        if (amount0 == 0 || amount1 == 0) return false;
        else return true;
    }

    function harvest(address _callFeeRecipient) external {
        _harvest(_callFeeRecipient);
    }

    function harvest() external {
        _harvest(tx.origin);
    }

    function _harvest(address _callFeeRecipient) private onlyCalmPeriods {
        _claimEarnings();
        _removeLiquidity();

        (uint256 fee0, uint256 fee1) = _chargeFees(_callFeeRecipient, fees0, fees1);

        _addLiquidity();

        fees0 = 0;
        fees1 = 0;

        (uint256 currentLock0, uint256 currentLock1) = lockedProfit();
        totalLocked0 = fee0 + currentLock0;
        totalLocked1 = fee1 + currentLock1;

        lastHarvest = block.timestamp;

        emit Harvest(fee0, fee1);
    }

    /// @notice Rebalance the position. Gated by onlyOwner (owner = vault) so rebalance
    ///         is routed through vault.rebalanceAMM(), giving the vault control over
    ///         when its strategy repositions.
    function moveTicks() external onlyCalmPeriods onlyOwner {
        _claimEarnings();
        _removeLiquidity();
        _setTicks();
        _addLiquidity();

        (uint256 bal0, uint256 bal1) = balances();
        emit TVL(bal0, bal1);
    }

    function claimEarnings() external returns (uint256 fee0, uint256 fee1, uint256 feeAlt0, uint256 feeAlt1) {
        (fee0, fee1, feeAlt0, feeAlt1) = _claimEarnings();
    }

    function _claimEarnings() private returns (uint256 fee0, uint256 fee1, uint256 feeAlt0, uint256 feeAlt1) {
        (bytes32 keyMain, bytes32 keyAlt) = getKeys();
        (uint128 liquidity,,,,) = IUniswapV3Pool(pool).positions(keyMain);
        (uint128 liquidityAlt,,,,) = IUniswapV3Pool(pool).positions(keyAlt);

        if (liquidity > 0) IUniswapV3Pool(pool).burn(positionMain.tickLower, positionMain.tickUpper, 0);
        if (liquidityAlt > 0) IUniswapV3Pool(pool).burn(positionAlt.tickLower, positionAlt.tickUpper, 0);

        (fee0, fee1) = IUniswapV3Pool(pool).collect(address(this), positionMain.tickLower, positionMain.tickUpper, type(uint128).max, type(uint128).max);
        (feeAlt0, feeAlt1) = IUniswapV3Pool(pool).collect(address(this), positionAlt.tickLower, positionAlt.tickUpper, type(uint128).max, type(uint128).max);

        fees0 = fees0 + fee0 + feeAlt0;
        fees1 = fees1 + fee1 + feeAlt1;

        emit ClaimedFees(fee0, fee1, feeAlt0, feeAlt1);
    }

    function _chargeFees(address _callFeeRecipient, uint256 _amount0, uint256 _amount1) private returns (uint256 _amountLeft0, uint256 _amountLeft1) {
        IFeeConfig.FeeCategory memory fees = getFees();

        uint256 nativeEarned;
        if (_amount0 > 0) {
            uint256 amountToSwap0 = _amount0 * fees.total / DIVISOR;
            _amountLeft0 = _amount0 - amountToSwap0;

            uint256 out0;
            if (lpToken0 != native) out0 = IBeefySwapper(unirouter).swap(lpToken0, native, amountToSwap0);

            if (lpToken0 == native) nativeEarned += amountToSwap0;
            else nativeEarned += out0;
        }

        if (_amount1 > 0) {
            uint256 amountToSwap1 = _amount1 * fees.total / DIVISOR;
            _amountLeft1 = _amount1 - amountToSwap1;

            uint256 out1;
            if (lpToken1 != native) out1 = IBeefySwapper(unirouter).swap(lpToken1, native, amountToSwap1);

            if (lpToken1 == native) nativeEarned += amountToSwap1;
            else nativeEarned += out1;
        }

        uint256 callFeeAmount = nativeEarned * fees.call / DIVISOR;
        IERC20Metadata(native).safeTransfer(_callFeeRecipient, callFeeAmount);

        uint256 strategistFeeAmount = nativeEarned * fees.strategist / DIVISOR;
        IERC20Metadata(native).safeTransfer(strategist, strategistFeeAmount);

        uint256 beefyFeeAmount = nativeEarned - callFeeAmount - strategistFeeAmount;
        IERC20Metadata(native).safeTransfer(beefyFeeRecipient(), beefyFeeAmount);

        emit ChargedFees(callFeeAmount, beefyFeeAmount, strategistFeeAmount);
    }

    function balances() public view returns (uint256 token0Bal, uint256 token1Bal) {
        (uint256 thisBal0, uint256 thisBal1) = balancesOfThis();
        (uint256 poolBal0, uint256 poolBal1,,,,) = balancesOfPool();
        (uint256 locked0, uint256 locked1) = lockedProfit();

        uint256 total0 = thisBal0 + poolBal0 - locked0;
        uint256 total1 = thisBal1 + poolBal1 - locked1;
        uint256 unharvestedFees0 = fees0;
        uint256 unharvestedFees1 = fees1;

        if (unharvestedFees0 > total0) unharvestedFees0 = total0;
        if (unharvestedFees1 > total1) unharvestedFees1 = total1;

        return (total0 - unharvestedFees0, total1 - unharvestedFees1);
    }

    function balancesOfThis() public view returns (uint256 token0Bal, uint256 token1Bal) {
        return (IERC20Metadata(lpToken0).balanceOf(address(this)), IERC20Metadata(lpToken1).balanceOf(address(this)));
    }

    function balancesOfPool() public view returns (uint256 token0Bal, uint256 token1Bal, uint256 mainAmount0, uint256 mainAmount1, uint256 altAmount0, uint256 altAmount1) {
        (bytes32 keyMain, bytes32 keyAlt) = getKeys();
        uint160 sqrtPriceX96 = sqrtPrice();
        (uint128 liquidity,,,uint256 owed0, uint256 owed1) = IUniswapV3Pool(pool).positions(keyMain);
        (uint128 altLiquidity,,,uint256 altOwed0, uint256 altOwed1) = IUniswapV3Pool(pool).positions(keyAlt);

        (mainAmount0, mainAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(positionMain.tickLower),
            TickMath.getSqrtRatioAtTick(positionMain.tickUpper),
            liquidity
        );

        (altAmount0, altAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(positionAlt.tickLower),
            TickMath.getSqrtRatioAtTick(positionAlt.tickUpper),
            altLiquidity
        );

        mainAmount0 += owed0;
        mainAmount1 += owed1;

        altAmount0 += altOwed0;
        altAmount1 += altOwed1;

        token0Bal = mainAmount0 + altAmount0;
        token1Bal = mainAmount1 + altAmount1;
    }

    function lockedProfit() public override view returns (uint256 locked0, uint256 locked1) {
        (uint256 balThis0, uint256 balThis1) = balancesOfThis();
        (uint256 balPool0, uint256 balPool1,,,,) = balancesOfPool();
        uint256 totalBal0 = balThis0 + balPool0;
        uint256 totalBal1 = balThis1 + balPool1;

        uint256 elapsed = block.timestamp - lastHarvest;
        uint256 remaining = elapsed < DURATION ? DURATION - elapsed : 0;

        if (totalBal0 > totalLocked0) locked0 = totalLocked0 * remaining / DURATION;
        else locked0 = totalBal0 * remaining / DURATION;

        if (totalBal1 > totalLocked1) locked1 = totalLocked1 * remaining / DURATION;
        else locked1 = totalBal1 * remaining / DURATION;
    }

    function range() external view returns (uint256 lowerPrice, uint256 upperPrice) {
        lowerPrice = FullMath.mulDiv(uint256(TickMath.getSqrtRatioAtTick(positionMain.tickLower)), SQRT_PRECISION, (2 ** 96)) ** 2;
        upperPrice = FullMath.mulDiv(uint256(TickMath.getSqrtRatioAtTick(positionMain.tickUpper)), SQRT_PRECISION, (2 ** 96)) ** 2;
    }

    function getKeys() public view returns (bytes32 keyMain, bytes32 keyAlt) {
        keyMain = keccak256(abi.encodePacked(address(this), positionMain.tickLower, positionMain.tickUpper));
        keyAlt = keccak256(abi.encodePacked(address(this), positionAlt.tickLower, positionAlt.tickUpper));
    }

    function currentTick() public view returns (int24 tick) {
        (,tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function price() public view returns (uint256 _price) {
        uint160 sqrtPriceX96 = sqrtPrice();
        _price = FullMath.mulDiv(uint256(sqrtPriceX96), SQRT_PRECISION, (2 ** 96)) ** 2;
    }

    function sqrtPrice() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function swapFee() external override view returns (uint256 fee) {
        fee = uint256(IUniswapV3Pool(pool).fee()) * SQRT_PRECISION / 1e6;
    }

    function _tickDistance() private view returns (int24) {
        return IUniswapV3Pool(pool).tickSpacing();
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes memory /*data*/) external {
        if (msg.sender != pool) revert NotPool();
        if (!minting) revert InvalidEntry();

        if (amount0 > 0) IERC20Metadata(lpToken0).safeTransfer(pool, amount0);
        if (amount1 > 0) IERC20Metadata(lpToken1).safeTransfer(pool, amount1);
        minting = false;
    }

    function _setTicks() private onlyCalmPeriods {
        int24 tick = currentTick();
        int24 distance = _tickDistance();
        int24 width = positionWidth * distance;

        _setMainTick(tick, distance, width);
        _setAltTick(tick, distance, width);

        lastPositionAdjustment = block.timestamp;
    }

    function _setMainTick(int24 tick, int24 distance, int24 width) private {
        (positionMain.tickLower, positionMain.tickUpper) = TickUtils.baseTicks(
            tick,
            width,
            distance
        );
    }

    function _setAltTick(int24 tick, int24 distance, int24 width) private {
        (uint256 bal0, uint256 bal1) = balancesOfThis();

        uint256 amount0;

        if (bal0 > 0) {
            amount0 = bal0 * price() / PRECISION;
        }

        if (amount0 < bal1) {
            (positionAlt.tickLower, ) = TickUtils.baseTicks(
                tick,
                width,
                distance
            );

            (positionAlt.tickUpper, ) = TickUtils.baseTicks(
                tick,
                distance,
                distance
            );
        } else if (bal1 < amount0) {
            (, positionAlt.tickLower) = TickUtils.baseTicks(
                tick,
                distance,
                distance
            );

            (, positionAlt.tickUpper) = TickUtils.baseTicks(
                tick,
                width,
                distance
            );
        }

        if (positionMain.tickLower == positionAlt.tickLower && positionMain.tickUpper == positionAlt.tickUpper) revert InvalidTicks();
    }

    function setLpToken0ToNativePath(bytes calldata _path) public onlyOwner {
        if (_path.length > 0) {
            (address[] memory _route) = UniV3Utils.pathToRoute(_path);
            if (_route[0] != lpToken0) revert InvalidInput();
            if (_route[_route.length - 1] != native) revert InvalidOutput();
            lpToken0ToNativePath = _path;
            emit SetLpToken0ToNativePath(_path);
        }
    }

    function setLpToken1ToNativePath(bytes calldata _path) public onlyOwner {
        if (_path.length > 0) {
            (address[] memory _route) = UniV3Utils.pathToRoute(_path);
            if (_route[0] != lpToken1) revert InvalidInput();
            if (_route[_route.length - 1] != native) revert InvalidOutput();
            lpToken1ToNativePath = _path;
            emit SetLpToken1ToNativePath(_path);
        }
    }

    function setDeviation(int56 _maxDeviation) external onlyOwner {
        emit SetDeviation(_maxDeviation);

        if (_maxDeviation >= _tickDistance() * 4) revert InvalidInput();

        maxTickDeviation = _maxDeviation;
    }

    function lpToken0ToNative() external view returns (address[] memory) {
        if (lpToken0ToNativePath.length == 0) return new address[](0);
        return UniV3Utils.pathToRoute(lpToken0ToNativePath);
    }

    function lpToken1ToNative() external view returns (address[] memory) {
        if (lpToken1ToNativePath.length == 0) return new address[](0);
        return UniV3Utils.pathToRoute(lpToken1ToNativePath);
    }

    function lpToken0ToNativePrice() external returns (uint256) {
        uint amount = 10**IERC20Metadata(lpToken0).decimals() / 10;
        if (lpToken0 == native) return amount * 10;
        return IQuoter(quoter).quoteExactInput(lpToken0ToNativePath, amount) * 10;
    }

    function lpToken1ToNativePrice() external returns (uint256) {
        uint amount = 10**IERC20Metadata(lpToken1).decimals() / 10;
        if (lpToken1 == native) return amount * 10;
        return IQuoter(quoter).quoteExactInput(lpToken1ToNativePath, amount) * 10;
    }

    function twap() public view returns (int56 twapTick) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = uint32(twapInterval);
        secondsAgo[1] = 0;

        (int56[] memory tickCuml,) = IUniswapV3Pool(pool).observe(secondsAgo);
        twapTick = (tickCuml[1] - tickCuml[0]) / int32(twapInterval);
    }

    function setTwapInterval(uint32 _interval) external onlyOwner {
        emit SetTwapInterval(twapInterval, _interval);

        if (_interval < 60) revert InvalidInput();

        twapInterval = _interval;
    }

    function setPositionWidth(int24 _width) external onlyOwner {
        emit SetPositionWidth(positionWidth, _width);
        _claimEarnings();
        _removeLiquidity();
        positionWidth = _width;
        _setTicks();
        _addLiquidity();
    }

    function setUnirouter(address _unirouter) external override onlyOwner {
        _removeAllowances();
        unirouter = _unirouter;
        _giveAllowances();
        emit SetUnirouter(_unirouter);
    }

    function retireVault() external onlyOwner {
        if (IBeefyVaultConcLiq(vault).totalSupply() != 10**3) revert NotAuthorized();
        panic(0,0);
        address feeRecipient = beefyFeeRecipient();
        (uint bal0, uint bal1) = balancesOfThis();
        if (bal0 > 0) IERC20Metadata(lpToken0).safeTransfer(feeRecipient, IERC20Metadata(lpToken0).balanceOf(address(this)));
        if (bal1 > 0) IERC20Metadata(lpToken1).safeTransfer(feeRecipient, IERC20Metadata(lpToken1).balanceOf(address(this)));
        _transferOwnership(address(0));
    }

    function panic(uint256 _minAmount0, uint256 _minAmount1) public onlyManager {
        _claimEarnings();
        _removeLiquidity();
        _removeAllowances();
        _pause();

        (uint256 bal0, uint256 bal1) = balances();
        if (bal0 < _minAmount0 || bal1 < _minAmount1) revert TooMuchSlippage();
    }

    function unpause() external onlyManager {
        if (owner() == address(0)) revert NotAuthorized();
        _giveAllowances();
        _unpause();
        _setTicks();
        _addLiquidity();
    }

    function _giveAllowances() private {
        IERC20Metadata(lpToken0).forceApprove(unirouter, type(uint256).max);
        IERC20Metadata(lpToken1).forceApprove(unirouter, type(uint256).max);
    }

    function _removeAllowances() private {
        IERC20Metadata(lpToken0).forceApprove(unirouter, 0);
        IERC20Metadata(lpToken1).forceApprove(unirouter, 0);
    }

    // ─── UUPS Upgradeability ────────────────────────────────────────────

    function _authorizeUpgrade(address newImplementation) internal view override {
        if (msg.sender != owner()) revert NotAuthorized();
        address factoryLatest = IAnalogStrategyFactory(address(factory)).latestImplementation("AnalogStrategyPassiveManagerUniswap");
        require(newImplementation == factoryLatest, "Invalid implementation");
    }

    function upgradeToLatest() external onlyOwner {
        address latest = IAnalogStrategyFactory(address(factory)).latestImplementation("AnalogStrategyPassiveManagerUniswap");
        require(latest != address(0), "No implementation signaled");
        _upgradeToAndCall(latest, new bytes(0), false);
    }
}
