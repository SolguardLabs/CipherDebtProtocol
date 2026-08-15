const assert = require("node:assert/strict");
const test = require("node:test");

const {
    CipherDebtClient,
    MIGRATION_ORDER_TYPES,
    WAD,
    assessMarket,
    assessPortfolio,
    buildMigrationOrder,
    mulDivDown,
    mulDivUp,
} = require("../../sdk/cipherDebtClient");

const wad = (value) => BigInt(value) * WAD;

const policy = {
    targetCoverageWad: 1_150_000_000_000_000_000n,
    operationalBuffer: wad(100),
    minimumLiquidLiquidity: wad(500),
    maximumMarketShareWad: 700_000_000_000_000_000n,
    maximumHhiWad: 600_000_000_000_000_000n,
};

function market(marketId, overrides = {}) {
    return {
        marketId,
        suppliedLiquidity: wad(10000),
        totalDebt: wad(6000),
        reserveBalance: wad(300),
        collateralValue: wad(7000),
        debtValue: wad(6000),
        liquidationThresholdWad: 750_000_000_000_000_000n,
        collateralShockWad: 200_000_000_000_000_000n,
        debtShockWad: 100_000_000_000_000_000n,
        liquidationCostWad: 80_000_000_000_000_000n,
        liquidityHaircutWad: 250_000_000_000_000_000n,
        maturitySeconds: 7_776_000n,
        ...overrides,
    };
}

test("fixed-point helpers preserve floor and ceiling semantics", () => {
    assert.equal(mulDivDown(10n, 10n, 6n), 16n);
    assert.equal(mulDivUp(10n, 10n, 6n), 17n);
    assert.equal(mulDivUp(0n, 10n, 6n), 0n);
});

test("market stress matches the Solidity model exactly", () => {
    const result = assessMarket(market(7), policy);
    assert.equal(result.stressedCollateralValue, wad(5600));
    assert.equal(result.stressedDebtValue, wad(6600));
    assert.equal(result.liquidationProceeds, wad(3864));
    assert.equal(result.liquidLiquidity, wad(2775));
    assert.equal(result.requiredCapital, wad(7690));
    assert.equal(result.deficit, wad(751));
    assert.equal(result.covered, false);
});

test("portfolio aggregation calculates share, HHI and maturity without Number", () => {
    const result = assessPortfolio(
        [
            market(11, { debtValue: wad(4000), totalDebt: wad(4000) }),
            market(12, {
                debtValue: wad(2000),
                totalDebt: wad(2000),
                maturitySeconds: 15_552_000n,
            }),
        ],
        policy,
    );
    assert.equal(result.largestMarketId, 11n);
    assert.equal(result.largestMarketShareWad, 666666666666666666n);
    assert.equal(result.debtHhiWad, 555555555555555553n);
    assert.equal(result.debtWeightedMaturitySeconds, 10_368_000n);
    assert.equal(result.concentrationCompliant, true);
});

test("migration orders are immutable decimal-safe transport objects", () => {
    const order = buildMigrationOrder({
        borrower: "0x1111111111111111111111111111111111111111",
        sourceMarketId: 1n,
        destinationMarketId: 2n,
        debtAmount: wad(450),
        collateralAmount: wad(900),
        destinationIndexSnapshot: WAD,
        minHealthFactor: WAD,
        deadline: 2_000_000_000n,
        nonce: 9n,
    });
    assert.equal(order.debtAmount, wad(450).toString());
    assert.equal(order.destinationIndexSnapshot, WAD.toString());
    assert.equal(Object.isFrozen(order), true);
    assert.equal(MIGRATION_ORDER_TYPES.MigrationOrder.length, 9);
});

test("client rejects cleartext remote endpoints and malformed addresses", async () => {
    assert.throws(
        () =>
            new CipherDebtClient({
                baseUrl: "http://api.cipher.example",
                fetchImpl: async () => {},
            }),
        /HTTPS/,
    );
    const client = new CipherDebtClient({
        baseUrl: "http://localhost:8545",
        fetchImpl: async () => {},
    });
    assert.throws(() => client.position(1n, "not-an-address"), /account is invalid/);
});

test("client sends authenticated JSON with exact decimal values and idempotency", async () => {
    let captured;
    const fetchImpl = async (url, options) => {
        captured = { url, options };
        return {
            ok: true,
            status: 200,
            headers: new Headers({ "content-type": "application/json; charset=utf-8" }),
            json: async () => ({ accepted: true }),
        };
    };
    const client = new CipherDebtClient({
        baseUrl: "https://api.cipher.example/",
        fetchImpl,
        bearerToken: "token-value",
    });
    const result = await client.submitMigration(
        {
            borrower: "0x2222222222222222222222222222222222222222",
            sourceMarketId: 4n,
            destinationMarketId: 8n,
            debtAmount: wad(125),
            collateralAmount: wad(250),
            destinationIndexSnapshot: WAD,
            minHealthFactor: WAD,
            deadline: 2_000_000_000n,
            nonce: 44n,
        },
        "cipher-order-000044",
    );

    assert.deepEqual(result, { accepted: true });
    assert.equal(captured.url, "https://api.cipher.example/v1/migrations");
    assert.equal(captured.options.redirect, "error");
    assert.equal(captured.options.headers.Authorization, "Bearer token-value");
    assert.equal(captured.options.headers["Idempotency-Key"], "cipher-order-000044");
    assert.equal(JSON.parse(captured.options.body).debtAmount, wad(125).toString());
});

test("client rejects non-JSON responses before consuming an ambiguous payload", async () => {
    const client = new CipherDebtClient({
        baseUrl: "https://api.cipher.example",
        fetchImpl: async () => ({
            ok: true,
            status: 200,
            headers: new Headers({ "content-type": "text/html" }),
            json: async () => ({ ignored: true }),
        }),
    });
    await assert.rejects(() => client.market(1n), /unexpected content type/);
});
