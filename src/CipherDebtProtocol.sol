// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolAccess} from "./access/ProtocolAccess.sol";
import {ICipherDebtProtocol} from "./interfaces/ICipherDebtProtocol.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {DebtAccounting} from "./libraries/DebtAccounting.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";
import {OrderHash} from "./libraries/OrderHash.sol";
import {RiskMath} from "./libraries/RiskMath.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {ReentrancyGuardLite} from "./security/ReentrancyGuardLite.sol";
import {CipherReceiptToken} from "./tokens/CipherReceiptToken.sol";

contract CipherDebtProtocol is ICipherDebtProtocol, ProtocolAccess, ReentrancyGuardLite {
    using DebtAccounting for DebtAccounting.DebtPosition;
    using FixedPointMath for uint256;
    using SafeTransferLib for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant MIN_INDEX = 1e18;
    uint256 public constant MAX_RATE_PER_SECOND = 0.0001e18;
    uint256 public constant MIN_HEALTH = 1e18;

    struct Market {
        address asset;
        address collateralAsset;
        address receiptToken;
        bool active;
        bool supplyPaused;
        bool borrowPaused;
        bool repayPaused;
        bool migrationPaused;
        bool liquidationPaused;
        uint256 borrowIndex;
        uint256 lastAccrual;
        uint256 totalDebt;
        uint256 suppliedLiquidity;
        uint256 reserveBalance;
        uint256 borrowRatePerSecond;
        uint256 collateralFactor;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 reserveFactor;
        uint256 minDebt;
        uint256 supplyCap;
        uint256 borrowCap;
    }

    struct Position {
        DebtAccounting.DebtPosition debt;
        uint256 collateralAmount;
        uint256 collateralUpdatedAt;
        uint256 migrationCount;
        uint256 liquidationCount;
        uint256 lastActionAt;
    }

    struct CreateMarketParams {
        address asset;
        address collateralAsset;
        string receiptName;
        string receiptSymbol;
        uint256 borrowRatePerSecond;
        uint256 collateralFactor;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 reserveFactor;
        uint256 minDebt;
        uint256 supplyCap;
        uint256 borrowCap;
    }

    struct RefinanceParams {
        uint256 marketId;
        uint256 repayAmount;
        uint256 additionalBorrow;
        uint256 maxResultingDebt;
        uint256 minHealthFactor;
        address receiver;
    }

    struct MarketFlags {
        bool active;
        bool supplyPaused;
        bool borrowPaused;
        bool repayPaused;
        bool migrationPaused;
        bool liquidationPaused;
    }

    IPriceOracle public oracle;
    address public treasury;
    bool public paused;

    uint256 private _marketCount;

    mapping(uint256 => Market) private _markets;
    mapping(uint256 => mapping(address => Position)) private _positions;
    mapping(address => mapping(address => bool)) public approvedMigrators;
    mapping(bytes32 => bool) public consumedOrders;

    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ProtocolPaused(bool paused);
    event MarketCreated(
        uint256 indexed marketId,
        address indexed asset,
        address indexed collateralAsset,
        address receiptToken
    );
    event MarketFlagsUpdated(uint256 indexed marketId, MarketFlags flags);
    event MarketRatesUpdated(
        uint256 indexed marketId,
        uint256 borrowRatePerSecond,
        uint256 reserveFactor
    );
    event MarketCapsUpdated(
        uint256 indexed marketId,
        uint256 supplyCap,
        uint256 borrowCap,
        uint256 minDebt
    );
    event MarketRiskUpdated(
        uint256 indexed marketId,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    );
    event InterestAccrued(
        uint256 indexed marketId,
        uint256 oldIndex,
        uint256 newIndex,
        uint256 interestAccrued,
        uint256 reserveAccrued
    );
    event Supplied(uint256 indexed marketId, address indexed supplier, uint256 amount);
    event SupplyWithdrawn(uint256 indexed marketId, address indexed supplier, uint256 amount);
    event CollateralDeposited(uint256 indexed marketId, address indexed account, uint256 amount);
    event CollateralWithdrawn(uint256 indexed marketId, address indexed account, uint256 amount);
    event Borrowed(
        uint256 indexed marketId,
        address indexed account,
        address indexed receiver,
        uint256 amount
    );
    event Repaid(
        uint256 indexed marketId,
        address indexed payer,
        address indexed borrower,
        uint256 amount
    );
    event Refinanced(
        uint256 indexed marketId,
        address indexed account,
        uint256 repaid,
        uint256 additionalBorrowed,
        uint256 resultingDebt
    );
    event MigrationPermissionUpdated(
        address indexed borrower,
        address indexed migrator,
        bool approved
    );
    event DebtMigrated(
        bytes32 indexed orderId,
        address indexed borrower,
        uint256 indexed sourceMarketId,
        uint256 destinationMarketId,
        uint256 sourceDebtReleased,
        uint256 destinationDebtBooked,
        uint256 collateralMoved
    );
    event Liquidated(
        uint256 indexed marketId,
        address indexed borrower,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event ReserveCollected(uint256 indexed marketId, address indexed receiver, uint256 amount);

    error ProtocolIsPaused();
    error MarketNotFound();
    error MarketInactive();
    error ActionPaused();
    error InvalidMarket();
    error InvalidAmount();
    error InvalidReceiver();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error InsufficientSupplyBalance();
    error DebtTooSmall();
    error DebtTooLarge();
    error PositionUnhealthy(uint256 healthFactor);
    error PositionHealthy(uint256 healthFactor);
    error UnauthorizedMigrator();
    error OrderAlreadyConsumed();
    error SnapshotOutOfRange();
    error CapExceeded();

    constructor(
        address initialOwner,
        address oracle_,
        address treasury_
    ) ProtocolAccess(initialOwner) {
        require(oracle_ != address(0), "ORACLE");
        require(treasury_ != address(0), "TREASURY");
        oracle = IPriceOracle(oracle_);
        treasury = treasury_;
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolIsPaused();
        _;
    }

    modifier validMarket(uint256 marketId) {
        _requireMarket(marketId);
        _;
    }

    function createMarket(
        CreateMarketParams calldata params
    ) external onlyRole(MARKET_ADMIN_ROLE) returns (uint256 marketId, address receiptToken) {
        _validateMarketParams(params);
        marketId = _marketCount++;
        uint8 decimals = IERC20(params.asset).decimals();
        receiptToken = address(
            new CipherReceiptToken(
                params.receiptName,
                params.receiptSymbol,
                decimals,
                address(this)
            )
        );
        Market storage market = _markets[marketId];
        market.asset = params.asset;
        market.collateralAsset = params.collateralAsset;
        market.receiptToken = receiptToken;
        market.active = true;
        market.borrowIndex = MIN_INDEX;
        market.lastAccrual = block.timestamp;
        market.borrowRatePerSecond = params.borrowRatePerSecond;
        market.collateralFactor = params.collateralFactor;
        market.liquidationThreshold = params.liquidationThreshold;
        market.liquidationBonus = params.liquidationBonus;
        market.reserveFactor = params.reserveFactor;
        market.minDebt = params.minDebt;
        market.supplyCap = params.supplyCap;
        market.borrowCap = params.borrowCap;
        emit MarketCreated(marketId, params.asset, params.collateralAsset, receiptToken);
    }

    function setOracle(address newOracle) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(newOracle != address(0), "ORACLE");
        address previous = address(oracle);
        oracle = IPriceOracle(newOracle);
        emit OracleUpdated(previous, newOracle);
    }

    function setTreasury(address newTreasury) external onlyRole(TREASURY_ROLE) {
        require(newTreasury != address(0), "TREASURY");
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function setPaused(bool newPaused) external onlyRole(PAUSER_ROLE) {
        paused = newPaused;
        emit ProtocolPaused(newPaused);
    }

    function setMarketFlags(
        uint256 marketId,
        MarketFlags calldata flags
    ) external onlyRole(MARKET_ADMIN_ROLE) validMarket(marketId) {
        Market storage market = _markets[marketId];
        market.active = flags.active;
        market.supplyPaused = flags.supplyPaused;
        market.borrowPaused = flags.borrowPaused;
        market.repayPaused = flags.repayPaused;
        market.migrationPaused = flags.migrationPaused;
        market.liquidationPaused = flags.liquidationPaused;
        emit MarketFlagsUpdated(marketId, flags);
    }

    function setMarketRates(
        uint256 marketId,
        uint256 borrowRatePerSecond,
        uint256 reserveFactor
    ) external onlyRole(MARKET_ADMIN_ROLE) validMarket(marketId) {
        require(borrowRatePerSecond <= MAX_RATE_PER_SECOND, "RATE");
        require(reserveFactor <= 0.5e18, "RESERVE_FACTOR");
        accrueMarket(marketId);
        Market storage market = _markets[marketId];
        market.borrowRatePerSecond = borrowRatePerSecond;
        market.reserveFactor = reserveFactor;
        emit MarketRatesUpdated(marketId, borrowRatePerSecond, reserveFactor);
    }

    function setMarketRisk(
        uint256 marketId,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) external onlyRole(RISK_ADMIN_ROLE) validMarket(marketId) {
        RiskMath.validateRisk(collateralFactor, liquidationThreshold, liquidationBonus);
        Market storage market = _markets[marketId];
        market.collateralFactor = collateralFactor;
        market.liquidationThreshold = liquidationThreshold;
        market.liquidationBonus = liquidationBonus;
        emit MarketRiskUpdated(marketId, collateralFactor, liquidationThreshold, liquidationBonus);
    }

    function setMarketCaps(
        uint256 marketId,
        uint256 supplyCap,
        uint256 borrowCap,
        uint256 minDebt
    ) external onlyRole(MARKET_ADMIN_ROLE) validMarket(marketId) {
        Market storage market = _markets[marketId];
        market.supplyCap = supplyCap;
        market.borrowCap = borrowCap;
        market.minDebt = minDebt;
        emit MarketCapsUpdated(marketId, supplyCap, borrowCap, minDebt);
    }

    function approveMigrator(address migrator, bool approved) external {
        require(migrator != address(0), "MIGRATOR");
        approvedMigrators[msg.sender][migrator] = approved;
        emit MigrationPermissionUpdated(msg.sender, migrator, approved);
    }

    function supply(
        uint256 marketId,
        uint256 amount
    ) external nonReentrant whenNotPaused validMarket(marketId) {
        if (amount == 0) revert InvalidAmount();
        Market storage market = _markets[marketId];
        _requireActive(market);
        if (market.supplyPaused) revert ActionPaused();
        if (market.supplyCap != 0 && market.suppliedLiquidity + amount > market.supplyCap) {
            revert CapExceeded();
        }
        IERC20(market.asset).safeTransferFrom(msg.sender, address(this), amount);
        market.suppliedLiquidity += amount;
        CipherReceiptToken(market.receiptToken).mint(msg.sender, amount);
        emit Supplied(marketId, msg.sender, amount);
    }

    function withdrawSupply(
        uint256 marketId,
        uint256 amount
    ) external nonReentrant whenNotPaused validMarket(marketId) {
        if (amount == 0) revert InvalidAmount();
        accrueMarket(marketId);
        Market storage market = _markets[marketId];
        if (amount > availableLiquidity(marketId)) revert InsufficientLiquidity();
        if (CipherReceiptToken(market.receiptToken).balanceOf(msg.sender) < amount) {
            revert InsufficientSupplyBalance();
        }
        market.suppliedLiquidity -= amount;
        CipherReceiptToken(market.receiptToken).burn(msg.sender, amount);
        IERC20(market.asset).safeTransfer(msg.sender, amount);
        emit SupplyWithdrawn(marketId, msg.sender, amount);
    }

    function depositCollateral(
        uint256 marketId,
        uint256 amount
    ) external nonReentrant whenNotPaused validMarket(marketId) {
        if (amount == 0) revert InvalidAmount();
        Market storage market = _markets[marketId];
        _requireActive(market);
        Position storage position = _positions[marketId][msg.sender];
        IERC20(market.collateralAsset).safeTransferFrom(msg.sender, address(this), amount);
        position.collateralAmount += amount;
        position.collateralUpdatedAt = block.timestamp;
        position.lastActionAt = block.timestamp;
        emit CollateralDeposited(marketId, msg.sender, amount);
    }

    function withdrawCollateral(
        uint256 marketId,
        uint256 amount
    ) external nonReentrant whenNotPaused validMarket(marketId) {
        if (amount == 0) revert InvalidAmount();
        accrueMarket(marketId);
        Market storage market = _markets[marketId];
        Position storage position = _positions[marketId][msg.sender];
        if (position.collateralAmount < amount) revert InsufficientCollateral();
        position.collateralAmount -= amount;
        position.collateralUpdatedAt = block.timestamp;
        position.lastActionAt = block.timestamp;
        uint256 health = _healthFactor(marketId, msg.sender);
        if (health < MIN_HEALTH) revert PositionUnhealthy(health);
        IERC20(market.collateralAsset).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(marketId, msg.sender, amount);
    }

    function borrow(
        uint256 marketId,
        uint256 amount,
        address receiver
    ) external nonReentrant whenNotPaused validMarket(marketId) {
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        accrueMarket(marketId);
        Market storage market = _markets[marketId];
        _requireActive(market);
        if (market.borrowPaused) revert ActionPaused();
        if (amount > availableLiquidity(marketId)) revert InsufficientLiquidity();
        if (market.borrowCap != 0 && market.totalDebt + amount > market.borrowCap)
            revert CapExceeded();
        Position storage position = _positions[marketId][msg.sender];
        DebtAccounting.DebtChange memory change = position.debt.increase(
            amount,
            market.borrowIndex
        );
        market.totalDebt += amount;
        _checkDebtFloor(market, change.nextDebt);
        uint256 health = _healthFactor(marketId, msg.sender);
        if (health < MIN_HEALTH) revert PositionUnhealthy(health);
        position.lastActionAt = block.timestamp;
        IERC20(market.asset).safeTransfer(receiver, amount);
        emit Borrowed(marketId, msg.sender, receiver, amount);
    }

    function repay(
        uint256 marketId,
        uint256 amount,
        address borrower
    ) external nonReentrant whenNotPaused validMarket(marketId) returns (uint256 paid) {
        if (amount == 0) revert InvalidAmount();
        require(borrower != address(0), "BORROWER");
        accrueMarket(marketId);
        Market storage market = _markets[marketId];
        if (market.repayPaused) revert ActionPaused();
        Position storage position = _positions[marketId][borrower];
        uint256 debt = position.debt.currentDebt(market.borrowIndex);
        paid = FixedPointMath.min(amount, debt);
        if (paid == 0) revert InvalidAmount();
        DebtAccounting.DebtChange memory change = position.debt.decrease(paid, market.borrowIndex);
        market.totalDebt -= paid;
        _checkDebtFloor(market, change.nextDebt);
        position.lastActionAt = block.timestamp;
        IERC20(market.asset).safeTransferFrom(msg.sender, address(this), paid);
        emit Repaid(marketId, msg.sender, borrower, paid);
    }

    function refinance(
        RefinanceParams calldata params
    )
        external
        nonReentrant
        whenNotPaused
        validMarket(params.marketId)
        returns (uint256 resultingDebt)
    {
        if (params.repayAmount == 0 && params.additionalBorrow == 0) revert InvalidAmount();
        address receiver = params.receiver == address(0) ? msg.sender : params.receiver;
        accrueMarket(params.marketId);
        Market storage market = _markets[params.marketId];
        _requireActive(market);
        if (market.repayPaused || market.borrowPaused) revert ActionPaused();
        Position storage position = _positions[params.marketId][msg.sender];
        uint256 currentDebt = position.debt.currentDebt(market.borrowIndex);
        uint256 paid = FixedPointMath.min(params.repayAmount, currentDebt);
        uint256 nextDebt = currentDebt - paid;
        if (params.additionalBorrow != 0) {
            if (params.additionalBorrow > availableLiquidity(params.marketId))
                revert InsufficientLiquidity();
            if (
                market.borrowCap != 0 &&
                market.totalDebt + params.additionalBorrow > market.borrowCap
            ) {
                revert CapExceeded();
            }
            nextDebt += params.additionalBorrow;
        }
        if (params.maxResultingDebt != 0 && nextDebt > params.maxResultingDebt)
            revert DebtTooLarge();
        position.debt.checkpoint(nextDebt, market.borrowIndex);
        if (paid != 0) {
            market.totalDebt -= paid;
            IERC20(market.asset).safeTransferFrom(msg.sender, address(this), paid);
            emit Repaid(params.marketId, msg.sender, msg.sender, paid);
        }
        if (params.additionalBorrow != 0) {
            market.totalDebt += params.additionalBorrow;
            IERC20(market.asset).safeTransfer(receiver, params.additionalBorrow);
            emit Borrowed(params.marketId, msg.sender, receiver, params.additionalBorrow);
        }
        _checkDebtFloor(market, nextDebt);
        uint256 minHealth = params.minHealthFactor == 0 ? MIN_HEALTH : params.minHealthFactor;
        uint256 health = _healthFactor(params.marketId, msg.sender);
        if (health < minHealth) revert PositionUnhealthy(health);
        position.lastActionAt = block.timestamp;
        resultingDebt = nextDebt;
        emit Refinanced(params.marketId, msg.sender, paid, params.additionalBorrow, nextDebt);
    }

    function migrateDebt(
        OrderHash.MigrationOrder calldata order
    )
        external
        nonReentrant
        whenNotPaused
        validMarket(order.sourceMarketId)
        validMarket(order.destinationMarketId)
        returns (uint256 destinationDebtBooked)
    {
        OrderHash.validate(order);
        if (!_canMigrate(order.borrower, msg.sender)) revert UnauthorizedMigrator();
        bytes32 orderId = OrderHash.actionId(order, address(this));
        if (consumedOrders[orderId]) revert OrderAlreadyConsumed();
        consumedOrders[orderId] = true;
        accrueMarket(order.sourceMarketId);
        accrueMarket(order.destinationMarketId);
        Market storage source = _markets[order.sourceMarketId];
        Market storage destination = _markets[order.destinationMarketId];
        _requireActive(source);
        _requireActive(destination);
        if (source.migrationPaused || destination.migrationPaused) revert ActionPaused();
        if (source.collateralAsset != destination.collateralAsset) revert InvalidMarket();
        if (order.destinationIndexSnapshot > destination.borrowIndex) revert SnapshotOutOfRange();
        Position storage sourcePosition = _positions[order.sourceMarketId][order.borrower];
        Position storage destinationPosition = _positions[order.destinationMarketId][
            order.borrower
        ];
        uint256 sourceDebt = sourcePosition.debt.currentDebt(source.borrowIndex);
        uint256 debtReleased = FixedPointMath.min(order.debtAmount, sourceDebt);
        if (debtReleased != 0) {
            sourcePosition.debt.checkpoint(sourceDebt - debtReleased, source.borrowIndex);
            source.totalDebt -= debtReleased;
            _checkDebtFloor(source, sourceDebt - debtReleased);
        }
        uint256 collateralMoved = FixedPointMath.min(
            order.collateralAmount,
            sourcePosition.collateralAmount
        );
        if (collateralMoved != 0) {
            sourcePosition.collateralAmount -= collateralMoved;
            destinationPosition.collateralAmount += collateralMoved;
            sourcePosition.collateralUpdatedAt = block.timestamp;
            destinationPosition.collateralUpdatedAt = block.timestamp;
        }
        if (debtReleased != 0) {
            destinationDebtBooked = _normalizeMigratedDebt(
                debtReleased,
                destination.borrowIndex,
                order.destinationIndexSnapshot
            );
            uint256 destinationDebt = destinationPosition.debt.currentDebt(destination.borrowIndex);
            destinationPosition.debt.checkpoint(
                destinationDebt + destinationDebtBooked,
                destination.borrowIndex
            );
            destination.totalDebt += destinationDebtBooked;
            _checkDebtFloor(destination, destinationDebt + destinationDebtBooked);
        }
        sourcePosition.migrationCount += 1;
        destinationPosition.migrationCount += 1;
        sourcePosition.lastActionAt = block.timestamp;
        destinationPosition.lastActionAt = block.timestamp;
        uint256 minHealth = order.minHealthFactor == 0 ? MIN_HEALTH : order.minHealthFactor;
        uint256 sourceHealth = _healthFactor(order.sourceMarketId, order.borrower);
        uint256 destinationHealth = _healthFactor(order.destinationMarketId, order.borrower);
        if (sourceHealth < minHealth) revert PositionUnhealthy(sourceHealth);
        if (destinationHealth < minHealth) revert PositionUnhealthy(destinationHealth);
        emit DebtMigrated(
            orderId,
            order.borrower,
            order.sourceMarketId,
            order.destinationMarketId,
            debtReleased,
            destinationDebtBooked,
            collateralMoved
        );
    }

    function liquidate(
        uint256 marketId,
        address borrower,
        uint256 repayAmount
    )
        external
        nonReentrant
        whenNotPaused
        validMarket(marketId)
        returns (uint256 paid, uint256 seized)
    {
        if (borrower == address(0)) revert InvalidReceiver();
        if (repayAmount == 0) revert InvalidAmount();
        accrueMarket(marketId);
        Market storage market = _markets[marketId];
        _requireActive(market);
        if (market.liquidationPaused) revert ActionPaused();
        uint256 health = _healthFactor(marketId, borrower);
        if (health >= MIN_HEALTH) revert PositionHealthy(health);
        Position storage position = _positions[marketId][borrower];
        uint256 debt = position.debt.currentDebt(market.borrowIndex);
        paid = FixedPointMath.min(repayAmount, debt);
        uint256 collateralPrice = _price(market.collateralAsset);
        uint256 debtPrice = _price(market.asset);
        seized = RiskMath.seizeCollateral(
            paid,
            debtPrice,
            collateralPrice,
            market.liquidationBonus
        );
        if (seized > position.collateralAmount) {
            seized = position.collateralAmount;
            paid = RiskMath.repayValueForSeizedCollateral(
                seized,
                collateralPrice,
                debtPrice,
                market.liquidationBonus
            );
        }
        if (paid == 0 || seized == 0) revert InvalidAmount();
        position.debt.checkpoint(debt - paid, market.borrowIndex);
        position.collateralAmount -= seized;
        position.liquidationCount += 1;
        position.lastActionAt = block.timestamp;
        market.totalDebt -= paid;
        _checkDebtFloor(market, debt - paid);
        IERC20(market.asset).safeTransferFrom(msg.sender, address(this), paid);
        IERC20(market.collateralAsset).safeTransfer(msg.sender, seized);
        emit Liquidated(marketId, borrower, msg.sender, paid, seized);
    }

    function collectReserve(
        uint256 marketId,
        uint256 amount,
        address receiver
    ) external nonReentrant onlyRole(TREASURY_ROLE) validMarket(marketId) {
        if (receiver == address(0)) receiver = treasury;
        Market storage market = _markets[marketId];
        uint256 collectable = FixedPointMath.min(amount, market.reserveBalance);
        if (collectable == 0) revert InvalidAmount();
        if (collectable > availableLiquidity(marketId)) revert InsufficientLiquidity();
        market.reserveBalance -= collectable;
        IERC20(market.asset).safeTransfer(receiver, collectable);
        emit ReserveCollected(marketId, receiver, collectable);
    }

    function accrueMarket(
        uint256 marketId
    ) public validMarket(marketId) returns (uint256 newIndex) {
        Market storage market = _markets[marketId];
        uint256 elapsed = block.timestamp - market.lastAccrual;
        uint256 oldIndex = market.borrowIndex;
        if (elapsed == 0) return oldIndex;
        if (market.totalDebt == 0 || market.borrowRatePerSecond == 0) {
            market.lastAccrual = block.timestamp;
            return oldIndex;
        }
        newIndex = DebtAccounting.accrueIndex(oldIndex, market.borrowRatePerSecond, elapsed);
        (uint256 interest, uint256 newTotalDebt) = DebtAccounting.accrueDebt(
            market.totalDebt,
            oldIndex,
            newIndex
        );
        uint256 reserveAccrued = FixedPointMath.mulWad(interest, market.reserveFactor);
        market.borrowIndex = newIndex;
        market.lastAccrual = block.timestamp;
        market.totalDebt = newTotalDebt;
        market.reserveBalance += reserveAccrued;
        emit InterestAccrued(marketId, oldIndex, newIndex, interest, reserveAccrued);
    }

    function marketCount() external view returns (uint256) {
        return _marketCount;
    }

    function getMarket(
        uint256 marketId
    ) public view validMarket(marketId) returns (MarketView memory view_) {
        Market storage market = _markets[marketId];
        view_ = MarketView({
            id: marketId,
            asset: market.asset,
            collateralAsset: market.collateralAsset,
            active: market.active,
            borrowIndex: _previewIndex(market),
            lastAccrual: market.lastAccrual,
            totalDebt: _previewTotalDebt(market),
            suppliedLiquidity: market.suppliedLiquidity,
            reserveBalance: market.reserveBalance,
            borrowRatePerSecond: market.borrowRatePerSecond,
            collateralFactor: market.collateralFactor,
            liquidationThreshold: market.liquidationThreshold,
            liquidationBonus: market.liquidationBonus,
            reserveFactor: market.reserveFactor,
            minDebt: market.minDebt,
            supplyCap: market.supplyCap,
            borrowCap: market.borrowCap
        });
    }

    function getPosition(
        uint256 marketId,
        address account
    ) public view validMarket(marketId) returns (PositionView memory view_) {
        Market storage market = _markets[marketId];
        Position storage position = _positions[marketId][account];
        uint256 projectedIndex = _previewIndex(market);
        uint256 debt = DebtAccounting.previewDebt(
            position.debt.principal,
            position.debt.indexSnapshot,
            projectedIndex
        );
        uint256 collateralPrice = _readPrice(market.collateralAsset);
        uint256 debtPrice = _readPrice(market.asset);
        RiskMath.Valuation memory value = RiskMath.evaluate(
            position.collateralAmount,
            debt,
            collateralPrice,
            debtPrice,
            market.collateralFactor,
            market.liquidationThreshold
        );
        view_ = PositionView({
            marketId: marketId,
            account: account,
            principal: position.debt.principal,
            indexSnapshot: position.debt.indexSnapshot,
            currentDebt: debt,
            collateralAmount: position.collateralAmount,
            collateralValue: value.collateralValue,
            debtValue: value.debtValue,
            borrowCapacity: value.borrowCapacity,
            liquidationCapacity: value.liquidationCapacity,
            healthFactor: value.healthFactor,
            liquidatable: value.liquidatable
        });
    }

    function quoteCurrentDebt(
        uint256 marketId,
        address account
    ) external view validMarket(marketId) returns (uint256) {
        Market storage market = _markets[marketId];
        Position storage position = _positions[marketId][account];
        return
            DebtAccounting.previewDebt(
                position.debt.principal,
                position.debt.indexSnapshot,
                _previewIndex(market)
            );
    }

    function quoteHealthFactor(
        uint256 marketId,
        address account
    ) external view validMarket(marketId) returns (uint256) {
        return getPosition(marketId, account).healthFactor;
    }

    function availableLiquidity(
        uint256 marketId
    ) public view validMarket(marketId) returns (uint256) {
        Market storage market = _markets[marketId];
        uint256 balance = IERC20(market.asset).balanceOf(address(this));
        if (balance <= market.reserveBalance) return 0;
        return balance - market.reserveBalance;
    }

    function supplierReceipt(
        uint256 marketId
    ) external view validMarket(marketId) returns (address) {
        return _markets[marketId].receiptToken;
    }

    function rawPosition(
        uint256 marketId,
        address account
    )
        external
        view
        validMarket(marketId)
        returns (
            uint256 principal,
            uint256 indexSnapshot,
            uint256 collateralAmount,
            uint256 migrationCount,
            uint256 liquidationCount,
            uint256 lastActionAt
        )
    {
        Position storage position = _positions[marketId][account];
        return (
            position.debt.principal,
            position.debt.indexSnapshot,
            position.collateralAmount,
            position.migrationCount,
            position.liquidationCount,
            position.lastActionAt
        );
    }

    function previewMigration(
        OrderHash.MigrationOrder calldata order
    )
        external
        view
        validMarket(order.sourceMarketId)
        validMarket(order.destinationMarketId)
        returns (
            uint256 sourceDebt,
            uint256 debtReleased,
            uint256 destinationDebt,
            uint256 bookedDebt,
            uint256 collateralMoved,
            uint256 sourceHealth,
            uint256 destinationHealth
        )
    {
        Market storage source = _markets[order.sourceMarketId];
        Market storage destination = _markets[order.destinationMarketId];
        Position storage sourcePosition = _positions[order.sourceMarketId][order.borrower];
        Position storage destinationPosition = _positions[order.destinationMarketId][
            order.borrower
        ];
        uint256 sourceIndex = _previewIndex(source);
        uint256 destinationIndex = _previewIndex(destination);
        sourceDebt = DebtAccounting.previewDebt(
            sourcePosition.debt.principal,
            sourcePosition.debt.indexSnapshot,
            sourceIndex
        );
        debtReleased = FixedPointMath.min(order.debtAmount, sourceDebt);
        destinationDebt = DebtAccounting.previewDebt(
            destinationPosition.debt.principal,
            destinationPosition.debt.indexSnapshot,
            destinationIndex
        );
        if (debtReleased != 0 && order.destinationIndexSnapshot <= destinationIndex) {
            bookedDebt = _normalizeMigratedDebt(
                debtReleased,
                destinationIndex,
                order.destinationIndexSnapshot
            );
        }
        collateralMoved = FixedPointMath.min(
            order.collateralAmount,
            sourcePosition.collateralAmount
        );
        sourceHealth = _previewHealthAfter(
            order.sourceMarketId,
            order.borrower,
            sourceDebt - debtReleased,
            sourcePosition.collateralAmount - collateralMoved
        );
        destinationHealth = _previewHealthAfter(
            order.destinationMarketId,
            order.borrower,
            destinationDebt + bookedDebt,
            destinationPosition.collateralAmount + collateralMoved
        );
    }

    function _validateMarketParams(CreateMarketParams calldata params) internal pure {
        require(params.asset != address(0), "ASSET");
        require(params.collateralAsset != address(0), "COLLATERAL");
        require(params.borrowRatePerSecond <= MAX_RATE_PER_SECOND, "RATE");
        require(params.reserveFactor <= 0.5e18, "RESERVE_FACTOR");
        RiskMath.validateRisk(
            params.collateralFactor,
            params.liquidationThreshold,
            params.liquidationBonus
        );
    }

    function _requireMarket(uint256 marketId) internal view {
        if (marketId >= _marketCount) revert MarketNotFound();
    }

    function _requireActive(Market storage market) internal view {
        if (!market.active) revert MarketInactive();
    }

    function _canMigrate(address borrower, address caller) internal view returns (bool) {
        return
            borrower == caller ||
            approvedMigrators[borrower][caller] ||
            hasRole(MIGRATOR_ROLE, caller);
    }

    function _normalizeMigratedDebt(
        uint256 amount,
        uint256 currentIndex,
        uint256 quotedIndex
    ) internal pure returns (uint256) {
        if (amount == 0) return 0;
        if (currentIndex == 0 || quotedIndex == 0) revert SnapshotOutOfRange();
        return FixedPointMath.mulWad(amount, FixedPointMath.divWad(quotedIndex, currentIndex));
    }

    function _checkDebtFloor(Market storage market, uint256 debt) internal view {
        if (DebtAccounting.wouldDust(debt, market.minDebt)) revert DebtTooSmall();
    }

    function _previewIndex(Market storage market) internal view returns (uint256) {
        if (market.totalDebt == 0 || market.borrowRatePerSecond == 0) return market.borrowIndex;
        uint256 elapsed = block.timestamp - market.lastAccrual;
        return DebtAccounting.accrueIndex(market.borrowIndex, market.borrowRatePerSecond, elapsed);
    }

    function _previewTotalDebt(Market storage market) internal view returns (uint256) {
        uint256 projectedIndex = _previewIndex(market);
        if (market.totalDebt == 0 || projectedIndex == market.borrowIndex) return market.totalDebt;
        (, uint256 total) = DebtAccounting.accrueDebt(
            market.totalDebt,
            market.borrowIndex,
            projectedIndex
        );
        return total;
    }

    function _healthFactor(uint256 marketId, address account) internal view returns (uint256) {
        Market storage market = _markets[marketId];
        Position storage position = _positions[marketId][account];
        uint256 debt = position.debt.currentDebt(market.borrowIndex);
        return _previewHealthAfter(marketId, account, debt, position.collateralAmount);
    }

    function _previewHealthAfter(
        uint256 marketId,
        address,
        uint256 debt,
        uint256 collateralAmount
    ) internal view returns (uint256) {
        Market storage market = _markets[marketId];
        uint256 collateralPrice = _price(market.collateralAsset);
        uint256 debtPrice = _price(market.asset);
        uint256 collateralValue = RiskMath.assetValue(collateralAmount, collateralPrice);
        uint256 debtValue = RiskMath.assetValue(debt, debtPrice);
        return RiskMath.healthFactor(collateralValue, debtValue, market.liquidationThreshold);
    }

    function _readPrice(address asset) internal view returns (uint256) {
        IPriceOracle.PriceData memory data = oracle.getPrice(asset);
        if (!data.valid) return 0;
        return data.priceWad;
    }

    function _price(address asset) internal view returns (uint256) {
        return oracle.priceWad(asset);
    }
}
