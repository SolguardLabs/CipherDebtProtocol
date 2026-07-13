const { expect } = require("chai");
const { ethers } = require("hardhat");

const WAD = ethers.parseEther("1");
const ZERO = 0n;
const YEAR = 365n * 24n * 60n * 60n;

function wad(value) {
    return ethers.parseEther(value);
}

function expectApprox(actual, expected, tolerance) {
    const diff = actual > expected ? actual - expected : expected - actual;
    expect(diff).to.be.lte(tolerance);
}

async function latestTimestamp() {
    const block = await ethers.provider.getBlock("latest");
    return BigInt(block.timestamp);
}

async function increaseTime(seconds) {
    await ethers.provider.send("evm_increaseTime", [Number(seconds)]);
    await ethers.provider.send("evm_mine", []);
}

describe("CipherDebtProtocol", function () {
    async function deployFixture() {
        const [owner, lender, borrower, liquidator, treasury, router] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("CipherMintableToken");
        const Oracle = await ethers.getContractFactory("CipherPriceOracle");
        const Protocol = await ethers.getContractFactory("CipherDebtProtocol");

        const collateral = await Token.deploy("Cipher Collateral", "cCOL", 18, owner.address);
        const assetA = await Token.deploy("Cipher USD Alpha", "cUSDA", 18, owner.address);
        const assetB = await Token.deploy("Cipher USD Beta", "cUSDB", 18, owner.address);
        const oracle = await Oracle.deploy(owner.address);
        const protocol = await Protocol.deploy(owner.address, oracle.target, treasury.address);

        const maxDelay = 100n * YEAR;
        for (const token of [collateral, assetA, assetB]) {
            await oracle.configureAsset(token.target, maxDelay);
        }
        await oracle.setPrice(collateral.target, wad("2"));
        await oracle.setPrice(assetA.target, wad("1"));
        await oracle.setPrice(assetB.target, wad("1"));

        const richBalance = wad("1000000");
        for (const account of [owner, lender, borrower, liquidator, router]) {
            await collateral.mint(account.address, richBalance);
            await assetA.mint(account.address, richBalance);
            await assetB.mint(account.address, richBalance);
        }

        const rate = 3_000_000_000n;
        const reserveFactor = wad("0.1");
        const collateralFactor = wad("0.65");
        const liquidationThreshold = wad("0.75");
        const liquidationBonus = wad("0.08");
        const minDebt = wad("1");
        const supplyCap = wad("1000000");
        const borrowCap = wad("750000");

        await protocol.createMarket({
            asset: assetA.target,
            collateralAsset: collateral.target,
            receiptName: "Cipher Alpha Supply",
            receiptSymbol: "csaUSDA",
            borrowRatePerSecond: rate,
            collateralFactor,
            liquidationThreshold,
            liquidationBonus,
            reserveFactor,
            minDebt,
            supplyCap,
            borrowCap,
        });

        await protocol.createMarket({
            asset: assetB.target,
            collateralAsset: collateral.target,
            receiptName: "Cipher Beta Supply",
            receiptSymbol: "csbUSDB",
            borrowRatePerSecond: rate * 2n,
            collateralFactor,
            liquidationThreshold,
            liquidationBonus,
            reserveFactor,
            minDebt,
            supplyCap,
            borrowCap,
        });

        for (const token of [assetA, assetB, collateral]) {
            for (const account of [lender, borrower, liquidator, router]) {
                await token.connect(account).approve(protocol.target, ethers.MaxUint256);
            }
        }

        await protocol.connect(lender).supply(0, wad("50000"));
        await protocol.connect(lender).supply(1, wad("50000"));

        return {
            owner,
            lender,
            borrower,
            liquidator,
            treasury,
            router,
            collateral,
            assetA,
            assetB,
            oracle,
            protocol,
        };
    }

    it("creates overcollateralized loans and accrues market interest", async function () {
        const { borrower, protocol } = await deployFixture();

        await protocol.connect(borrower).depositCollateral(0, wad("1000"));
        await protocol.connect(borrower).borrow(0, wad("900"), borrower.address);

        const positionBefore = await protocol.getPosition(0, borrower.address);
        expect(positionBefore.currentDebt).to.equal(wad("900"));
        expect(positionBefore.healthFactor).to.be.gt(WAD);

        await increaseTime(30n * 24n * 60n * 60n);
        const quotedDebt = await protocol.quoteCurrentDebt(0, borrower.address);
        expect(quotedDebt).to.be.gt(wad("900"));

        await protocol.accrueMarket(0);
        const market = await protocol.getMarket(0);
        const positionAfter = await protocol.getPosition(0, borrower.address);

        expect(market.borrowIndex).to.be.gt(WAD);
        expectApprox(positionAfter.currentDebt, quotedDebt, 10n ** 13n);
        expectApprox(market.totalDebt, quotedDebt, 10n ** 13n);
    });

    it("migrates debt and collateral between markets with a fresh quote", async function () {
        const { borrower, protocol } = await deployFixture();

        await protocol.connect(borrower).depositCollateral(0, wad("1200"));
        await protocol.connect(borrower).borrow(0, wad("1000"), borrower.address);

        const destinationMarket = await protocol.getMarket(1);
        const deadline = (await latestTimestamp()) + 3600n;

        await expect(
            protocol.connect(borrower).migrateDebt({
                borrower: borrower.address,
                sourceMarketId: 0,
                destinationMarketId: 1,
                debtAmount: wad("400"),
                collateralAmount: wad("500"),
                destinationIndexSnapshot: destinationMarket.borrowIndex,
                minHealthFactor: WAD,
                deadline,
                nonce: 1,
            }),
        ).to.emit(protocol, "DebtMigrated");

        const sourcePosition = await protocol.getPosition(0, borrower.address);
        const destinationPosition = await protocol.getPosition(1, borrower.address);

        expectApprox(sourcePosition.currentDebt, wad("600"), 10n ** 13n);
        expect(destinationPosition.currentDebt).to.equal(wad("400"));
        expect(sourcePosition.collateralAmount).to.equal(wad("700"));
        expect(destinationPosition.collateralAmount).to.equal(wad("500"));
        expect(sourcePosition.healthFactor).to.be.gt(WAD);
        expect(destinationPosition.healthFactor).to.be.gt(WAD);
    });

    it("refinances, repays and preserves solvency limits", async function () {
        const { borrower, protocol } = await deployFixture();

        await protocol.connect(borrower).depositCollateral(0, wad("1800"));
        await protocol.connect(borrower).borrow(0, wad("1000"), borrower.address);

        await expect(
            protocol.connect(borrower).refinance({
                marketId: 0,
                repayAmount: wad("150"),
                additionalBorrow: wad("75"),
                maxResultingDebt: wad("950"),
                minHealthFactor: WAD,
                receiver: borrower.address,
            }),
        ).to.emit(protocol, "Refinanced");

        let position = await protocol.getPosition(0, borrower.address);
        expectApprox(position.currentDebt, wad("925"), 10n ** 13n);
        expect(position.healthFactor).to.be.gt(WAD);

        await expect(protocol.connect(borrower).repay(0, wad("225"), borrower.address)).to.emit(
            protocol,
            "Repaid",
        );

        position = await protocol.getPosition(0, borrower.address);
        expectApprox(position.currentDebt, wad("700"), 10n ** 13n);

        await expect(protocol.connect(borrower).withdrawCollateral(0, wad("300"))).to.emit(
            protocol,
            "CollateralWithdrawn",
        );
        position = await protocol.getPosition(0, borrower.address);
        expect(position.collateralAmount).to.equal(wad("1500"));
        expect(position.healthFactor).to.be.gt(WAD);
    });

    it("liquidates unhealthy positions after collateral repricing", async function () {
        const { borrower, liquidator, oracle, collateral, protocol } = await deployFixture();

        await protocol.connect(borrower).depositCollateral(0, wad("900"));
        await protocol.connect(borrower).borrow(0, wad("1000"), borrower.address);

        await oracle.setPrice(collateral.target, wad("0.7"));
        const unhealthy = await protocol.getPosition(0, borrower.address);
        expect(unhealthy.liquidatable).to.equal(true);

        const liquidatorCollateralBefore = await collateral.balanceOf(liquidator.address);

        await expect(
            protocol.connect(liquidator).liquidate(0, borrower.address, wad("200")),
        ).to.emit(protocol, "Liquidated");

        const positionAfter = await protocol.getPosition(0, borrower.address);
        const liquidatorCollateralAfter = await collateral.balanceOf(liquidator.address);

        expect(positionAfter.currentDebt).to.be.lt(unhealthy.currentDebt);
        expect(positionAfter.collateralAmount).to.be.lt(unhealthy.collateralAmount);
        expect(liquidatorCollateralAfter).to.be.gt(liquidatorCollateralBefore);
    });

    it("keeps market controls explicit for caps, pauses and delegated migration", async function () {
        const { owner, borrower, router, protocol } = await deployFixture();

        await protocol.connect(borrower).depositCollateral(0, wad("1500"));
        await protocol.connect(borrower).borrow(0, wad("600"), borrower.address);

        await protocol.connect(owner).setMarketFlags(0, {
            active: true,
            supplyPaused: false,
            borrowPaused: true,
            repayPaused: false,
            migrationPaused: false,
            liquidationPaused: false,
        });

        await expect(
            protocol.connect(borrower).borrow(0, wad("1"), borrower.address),
        ).to.be.revertedWithCustomError(protocol, "ActionPaused");

        await protocol.connect(owner).setMarketFlags(0, {
            active: true,
            supplyPaused: false,
            borrowPaused: false,
            repayPaused: false,
            migrationPaused: false,
            liquidationPaused: false,
        });

        await protocol.connect(borrower).approveMigrator(router.address, true);
        const destinationMarket = await protocol.getMarket(1);
        const deadline = (await latestTimestamp()) + 3600n;

        await expect(
            protocol.connect(router).migrateDebt({
                borrower: borrower.address,
                sourceMarketId: 0,
                destinationMarketId: 1,
                debtAmount: wad("200"),
                collateralAmount: wad("400"),
                destinationIndexSnapshot: destinationMarket.borrowIndex,
                minHealthFactor: WAD,
                deadline,
                nonce: 77,
            }),
        ).to.emit(protocol, "DebtMigrated");
    });
});
