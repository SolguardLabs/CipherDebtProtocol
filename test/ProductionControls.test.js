const { expect } = require("chai");
const { ethers } = require("hardhat");

const WAD = ethers.parseEther("1");

function wad(value) {
    return ethers.parseEther(value);
}

async function now() {
    return BigInt((await ethers.provider.getBlock("latest")).timestamp);
}

async function moveTo(timestamp) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [Number(timestamp)]);
    await ethers.provider.send("evm_mine", []);
}

describe("Cipher production controls", function () {
    const policy = {
        targetCoverageWad: wad("1.15"),
        operationalBuffer: wad("100"),
        minimumLiquidLiquidity: wad("500"),
        maximumMarketShareWad: wad("0.70"),
        maximumHhiWad: wad("0.60"),
    };

    function market(marketId, overrides = {}) {
        return {
            marketId,
            suppliedLiquidity: wad("10000"),
            totalDebt: wad("6000"),
            reserveBalance: wad("300"),
            collateralValue: wad("7000"),
            debtValue: wad("6000"),
            liquidationThresholdWad: wad("0.75"),
            collateralShockWad: wad("0.20"),
            debtShockWad: wad("0.10"),
            liquidationCostWad: wad("0.08"),
            liquidityHaircutWad: wad("0.25"),
            maturitySeconds: 90n * 24n * 60n * 60n,
            ...overrides,
        };
    }

    async function deployGovernance() {
        const [governorA, governorB, guardian, executorAccount] = await ethers.getSigners();
        const Governance = await ethers.getContractFactory("CipherGovernanceExecutor");
        const governance = await Governance.deploy(
            ethers.id("cipher-debt-mainnet"),
            [governorA.address, governorB.address],
            guardian.address,
            2,
            10,
            120,
        );
        return { governance, governorA, governorB, guardian, executorAccount };
    }

    async function scheduleSelfCall(
        governance,
        governor,
        data,
        salt,
        predecessor = ethers.ZeroHash,
    ) {
        const eta = (await now()) + 12n;
        const id = await governance
            .connect(governor)
            .schedule.staticCall(governance.target, 0, data, predecessor, salt, eta);
        await governance
            .connect(governor)
            .schedule(governance.target, 0, data, predecessor, salt, eta);
        return { id, eta, data };
    }

    it("calculates stressed capital with liquidation and liquidity haircuts", async function () {
        const Engine = await ethers.getContractFactory("CipherCapitalEngine");
        const engine = await Engine.deploy();
        const result = await engine.assessMarket(market(7), policy);

        expect(result.marketId).to.equal(7n);
        expect(result.stressedCollateralValue).to.equal(wad("5600"));
        expect(result.stressedDebtValue).to.equal(wad("6600"));
        expect(result.liquidationProceeds).to.equal(wad("3864"));
        expect(result.liquidLiquidity).to.equal(wad("2775"));
        expect(result.utilizationWad).to.equal(wad("0.6"));
        expect(result.requiredCapital).to.equal(wad("7690"));
        expect(result.deficit).to.equal(wad("751"));
        expect(result.covered).to.equal(false);
    });

    it("aggregates concentration, HHI and debt-weighted maturity", async function () {
        const Engine = await ethers.getContractFactory("CipherCapitalEngine");
        const engine = await Engine.deploy();
        const result = await engine.assessPortfolio(
            [
                market(11, { debtValue: wad("4000"), totalDebt: wad("4000") }),
                market(12, {
                    debtValue: wad("2000"),
                    totalDebt: wad("2000"),
                    maturitySeconds: 180n * 24n * 60n * 60n,
                }),
            ],
            policy,
        );

        expect(result.markets).to.equal(2n);
        expect(result.largestMarketId).to.equal(11n);
        expect(result.largestMarketShareWad).to.equal(666666666666666666n);
        expect(result.debtHhiWad).to.equal(555555555555555553n);
        expect(result.debtWeightedMaturitySeconds).to.equal(10368000n);
        expect(result.concentrationCompliant).to.equal(true);
    });

    it("rejects invalid stress ratios and policy bounds", async function () {
        const Engine = await ethers.getContractFactory("CipherCapitalEngine");
        const engine = await Engine.deploy();

        await expect(
            engine.assessMarket(market(1, { collateralShockWad: WAD + 1n }), policy),
        ).to.be.revertedWithCustomError(engine, "InvalidRatio");
        await expect(
            engine.assessMarket(market(1), { ...policy, targetCoverageWad: WAD - 1n }),
        ).to.be.revertedWithCustomError(engine, "InvalidPolicy");
    });

    it("binds operation identities to payload, salt, schedule and protocol domain", async function () {
        const { governance } = await deployGovernance();
        const eta = (await now()) + 20n;
        const expires = eta + 120n;
        const dataA = governance.interface.encodeFunctionData("setPolicy", [15, 120, 2]);
        const dataB = governance.interface.encodeFunctionData("setPolicy", [20, 120, 2]);
        const idA = await governance.operationId(
            governance.target,
            0,
            dataA,
            ethers.ZeroHash,
            ethers.id("policy-1"),
            eta,
            expires,
        );
        const idB = await governance.operationId(
            governance.target,
            0,
            dataB,
            ethers.ZeroHash,
            ethers.id("policy-1"),
            eta,
            expires,
        );
        expect(idA).to.not.equal(idB);
    });

    it("requires unique governor approvals and enforces the timelock", async function () {
        const { governance, governorA, governorB, executorAccount } = await deployGovernance();
        const data = governance.interface.encodeFunctionData("setPolicy", [20, 180, 2]);
        const scheduled = await scheduleSelfCall(
            governance,
            governorA,
            data,
            ethers.id("unique-approval"),
        );

        await expect(
            governance.connect(governorA).approve(scheduled.id),
        ).to.be.revertedWithCustomError(governance, "AlreadyApproved");
        await governance.connect(governorB).approve(scheduled.id);
        expect((await governance.getOperation(scheduled.id)).approvals).to.equal(2n);
        await expect(
            governance.connect(executorAccount).execute(scheduled.id, scheduled.data),
        ).to.be.revertedWithCustomError(governance, "NotReady");
    });

    it("executes approved self-governance and records terminal state", async function () {
        const { governance, governorA, governorB, executorAccount } = await deployGovernance();
        const data = governance.interface.encodeFunctionData("setPolicy", [25, 240, 2]);
        const scheduled = await scheduleSelfCall(
            governance,
            governorA,
            data,
            ethers.id("execute-policy"),
        );
        await governance.connect(governorB).approve(scheduled.id);
        await moveTo(scheduled.eta);

        await expect(
            governance.connect(executorAccount).execute(scheduled.id, scheduled.data),
        ).to.emit(governance, "OperationExecuted");
        expect(await governance.minimumDelay()).to.equal(25n);
        expect(await governance.gracePeriod()).to.equal(240n);
        expect(await governance.state(scheduled.id)).to.equal(4n);
        await expect(
            governance.connect(executorAccount).execute(scheduled.id, scheduled.data),
        ).to.be.revertedWithCustomError(governance, "TerminalOperation");
    });

    it("blocks successors until their predecessor has executed", async function () {
        const { governance, governorA, governorB, executorAccount } = await deployGovernance();
        const firstData = governance.interface.encodeFunctionData("setGuardian", [
            executorAccount.address,
        ]);
        const first = await scheduleSelfCall(
            governance,
            governorA,
            firstData,
            ethers.id("predecessor"),
        );
        const secondData = governance.interface.encodeFunctionData("setPolicy", [15, 180, 2]);
        const second = await scheduleSelfCall(
            governance,
            governorA,
            secondData,
            ethers.id("successor"),
            first.id,
        );
        await governance.connect(governorB).approve(first.id);
        await governance.connect(governorB).approve(second.id);
        await moveTo(second.eta);

        await expect(
            governance.connect(executorAccount).execute(second.id, second.data),
        ).to.be.revertedWithCustomError(governance, "PredecessorIncomplete");
        await governance.connect(executorAccount).execute(first.id, first.data);
        await governance.connect(executorAccount).execute(second.id, second.data);
        expect(await governance.minimumDelay()).to.equal(15n);
    });

    it("lets the guardian cancel queued operations irreversibly", async function () {
        const { governance, governorA, guardian } = await deployGovernance();
        const data = governance.interface.encodeFunctionData("setPolicy", [20, 180, 2]);
        const scheduled = await scheduleSelfCall(
            governance,
            governorA,
            data,
            ethers.id("guardian-cancel"),
        );

        await governance.connect(guardian).cancel(scheduled.id);
        expect(await governance.state(scheduled.id)).to.equal(5n);
        await expect(
            governance.connect(governorA).approve(scheduled.id),
        ).to.be.revertedWithCustomError(governance, "TerminalOperation");
    });
});
