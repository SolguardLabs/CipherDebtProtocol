"use strict";

const WAD = 10n ** 18n;
const UINT256_MAX = (1n << 256n) - 1n;

function toUint(value, field) {
    let parsed;
    try {
        parsed = typeof value === "bigint" ? value : BigInt(value);
    } catch {
        throw new TypeError(`${field} must be an integer`);
    }
    if (parsed < 0n || parsed > UINT256_MAX) {
        throw new RangeError(`${field} is outside uint256`);
    }
    return parsed;
}

function assertWad(value, field) {
    const parsed = toUint(value, field);
    if (parsed > WAD) throw new RangeError(`${field} must not exceed WAD`);
    return parsed;
}

function mulDivDown(a, b, denominator) {
    const left = toUint(a, "a");
    const right = toUint(b, "b");
    const divisor = toUint(denominator, "denominator");
    if (divisor === 0n) throw new RangeError("denominator must be positive");
    return (left * right) / divisor;
}

function mulDivUp(a, b, denominator) {
    const left = toUint(a, "a");
    const right = toUint(b, "b");
    const divisor = toUint(denominator, "denominator");
    if (divisor === 0n) throw new RangeError("denominator must be positive");
    if (left === 0n || right === 0n) return 0n;
    return (left * right - 1n) / divisor + 1n;
}

function assessMarket(input, policy) {
    const suppliedLiquidity = toUint(input.suppliedLiquidity, "suppliedLiquidity");
    const totalDebt = toUint(input.totalDebt, "totalDebt");
    const reserveBalance = toUint(input.reserveBalance, "reserveBalance");
    const collateralValue = toUint(input.collateralValue, "collateralValue");
    const debtValue = toUint(input.debtValue, "debtValue");
    const liquidationThresholdWad = assertWad(
        input.liquidationThresholdWad,
        "liquidationThresholdWad",
    );
    const collateralShockWad = assertWad(input.collateralShockWad, "collateralShockWad");
    const debtShockWad = assertWad(input.debtShockWad, "debtShockWad");
    const liquidationCostWad = assertWad(input.liquidationCostWad, "liquidationCostWad");
    const liquidityHaircutWad = assertWad(input.liquidityHaircutWad, "liquidityHaircutWad");
    const targetCoverageWad = toUint(policy.targetCoverageWad, "targetCoverageWad");
    if (targetCoverageWad < WAD) throw new RangeError("targetCoverageWad must be at least WAD");

    const stressedCollateralValue = mulDivDown(collateralValue, WAD - collateralShockWad, WAD);
    const stressedDebtValue = mulDivDown(debtValue, WAD + debtShockWad, WAD);
    const protectedCollateral = mulDivDown(stressedCollateralValue, liquidationThresholdWad, WAD);
    const liquidationProceeds = mulDivDown(protectedCollateral, WAD - liquidationCostWad, WAD);
    const encumbered = totalDebt + reserveBalance;
    const grossLiquidity = suppliedLiquidity > encumbered ? suppliedLiquidity - encumbered : 0n;
    const liquidLiquidity = mulDivDown(grossLiquidity, WAD - liquidityHaircutWad, WAD);
    const availableCapital = liquidationProceeds + liquidLiquidity + reserveBalance;
    const requiredCapital =
        mulDivUp(stressedDebtValue, targetCoverageWad, WAD) +
        toUint(policy.operationalBuffer, "operationalBuffer");
    const surplus = availableCapital >= requiredCapital ? availableCapital - requiredCapital : 0n;
    const deficit = requiredCapital > availableCapital ? requiredCapital - availableCapital : 0n;

    return {
        marketId: toUint(input.marketId, "marketId"),
        stressedCollateralValue,
        stressedDebtValue,
        liquidationProceeds,
        liquidLiquidity,
        availableCapital,
        requiredCapital,
        surplus,
        deficit,
        coverageWad:
            requiredCapital === 0n
                ? UINT256_MAX
                : mulDivDown(availableCapital, WAD, requiredCapital),
        utilizationWad:
            suppliedLiquidity === 0n ? 0n : mulDivDown(totalDebt, WAD, suppliedLiquidity),
        liquid: liquidLiquidity >= toUint(policy.minimumLiquidLiquidity, "minimumLiquidLiquidity"),
        covered: deficit === 0n,
    };
}

function assessPortfolio(inputs, policy) {
    if (!Array.isArray(inputs) || inputs.length === 0) {
        throw new RangeError("inputs must contain at least one market");
    }
    const maximumMarketShareWad = assertWad(policy.maximumMarketShareWad, "maximumMarketShareWad");
    const maximumHhiWad = assertWad(policy.maximumHhiWad, "maximumHhiWad");
    if (maximumMarketShareWad === 0n || maximumHhiWad === 0n) {
        throw new RangeError("concentration limits must be positive");
    }

    const markets = inputs.map((input) => assessMarket(input, policy));
    const totalStressedDebt = markets.reduce((sum, market) => sum + market.stressedDebtValue, 0n);
    const totalAvailableCapital = markets.reduce(
        (sum, market) => sum + market.availableCapital,
        0n,
    );
    const totalRequiredCapital = markets.reduce((sum, market) => sum + market.requiredCapital, 0n);
    const totalSurplus = markets.reduce((sum, market) => sum + market.surplus, 0n);
    const totalDeficit = markets.reduce((sum, market) => sum + market.deficit, 0n);

    let largest = markets[0];
    let weightedMaturity = 0n;
    for (let index = 0; index < markets.length; index += 1) {
        if (markets[index].stressedDebtValue > largest.stressedDebtValue) largest = markets[index];
        weightedMaturity +=
            markets[index].stressedDebtValue *
            toUint(inputs[index].maturitySeconds, "maturitySeconds");
    }

    const largestMarketShareWad =
        totalStressedDebt === 0n
            ? 0n
            : mulDivDown(largest.stressedDebtValue, WAD, totalStressedDebt);
    const debtHhiWad =
        totalStressedDebt === 0n
            ? 0n
            : markets.reduce((sum, market) => {
                  const share = mulDivDown(market.stressedDebtValue, WAD, totalStressedDebt);
                  return sum + mulDivDown(share, share, WAD);
              }, 0n);

    return {
        markets: BigInt(inputs.length),
        totalStressedDebt,
        totalAvailableCapital,
        totalRequiredCapital,
        totalSurplus,
        totalDeficit,
        largestMarketId: largest.marketId,
        largestMarketShareWad,
        debtHhiWad,
        debtWeightedMaturitySeconds:
            totalStressedDebt === 0n ? 0n : weightedMaturity / totalStressedDebt,
        coverageWad:
            totalRequiredCapital === 0n
                ? UINT256_MAX
                : mulDivDown(totalAvailableCapital, WAD, totalRequiredCapital),
        concentrationCompliant:
            largestMarketShareWad <= maximumMarketShareWad && debtHhiWad <= maximumHhiWad,
        capitalCompliant: totalDeficit === 0n,
    };
}

function buildMigrationOrder(fields) {
    const requiredAddresses = ["borrower"];
    for (const field of requiredAddresses) {
        if (!/^0x[0-9a-fA-F]{40}$/.test(fields[field] ?? "")) {
            throw new TypeError(`${field} must be an EVM address`);
        }
    }
    return Object.freeze({
        borrower: fields.borrower,
        sourceMarketId: toUint(fields.sourceMarketId, "sourceMarketId").toString(),
        destinationMarketId: toUint(fields.destinationMarketId, "destinationMarketId").toString(),
        debtAmount: toUint(fields.debtAmount, "debtAmount").toString(),
        collateralAmount: toUint(fields.collateralAmount, "collateralAmount").toString(),
        destinationIndexSnapshot: toUint(
            fields.destinationIndexSnapshot,
            "destinationIndexSnapshot",
        ).toString(),
        minHealthFactor: toUint(fields.minHealthFactor, "minHealthFactor").toString(),
        deadline: toUint(fields.deadline, "deadline").toString(),
        nonce: toUint(fields.nonce, "nonce").toString(),
    });
}

function jsonBody(value) {
    return JSON.stringify(value, (_key, item) =>
        typeof item === "bigint" ? item.toString() : item,
    );
}

class CipherDebtClient {
    constructor({ baseUrl, fetchImpl = globalThis.fetch, bearerToken, timeoutMs = 8_000 }) {
        if (typeof fetchImpl !== "function") throw new TypeError("fetchImpl is required");
        const parsed = new URL(baseUrl);
        const local = ["localhost", "127.0.0.1", "::1"].includes(parsed.hostname);
        if (parsed.protocol !== "https:" && !(local && parsed.protocol === "http:")) {
            throw new TypeError("baseUrl must use HTTPS outside localhost");
        }
        if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
            throw new RangeError("timeoutMs must be a positive safe integer");
        }
        this.baseUrl = parsed.toString().replace(/\/$/, "");
        this.fetchImpl = fetchImpl;
        this.bearerToken = bearerToken;
        this.timeoutMs = timeoutMs;
    }

    market(marketId) {
        return this._request("GET", `/v1/markets/${toUint(marketId, "marketId")}`);
    }

    position(marketId, account) {
        if (!/^0x[0-9a-fA-F]{40}$/.test(account)) throw new TypeError("account is invalid");
        return this._request(
            "GET",
            `/v1/markets/${toUint(marketId, "marketId")}/positions/${account}`,
        );
    }

    previewMigration(order) {
        return this._request("POST", "/v1/migrations/preview", buildMigrationOrder(order));
    }

    submitMigration(order, idempotencyKey) {
        if (typeof idempotencyKey !== "string" || idempotencyKey.length < 16) {
            throw new TypeError("idempotencyKey must contain at least 16 characters");
        }
        return this._request("POST", "/v1/migrations", buildMigrationOrder(order), idempotencyKey);
    }

    capitalAssessment(markets, policy) {
        return this._request("POST", "/v1/risk/capital", { markets, policy });
    }

    async _request(method, path, body, idempotencyKey) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
        const headers = { Accept: "application/json", "X-Cipher-Client": "sdk-js/1.0.0" };
        if (body !== undefined) headers["Content-Type"] = "application/json";
        if (this.bearerToken) headers.Authorization = `Bearer ${this.bearerToken}`;
        if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;

        try {
            const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
                method,
                headers,
                body: body === undefined ? undefined : jsonBody(body),
                signal: controller.signal,
                redirect: "error",
            });
            const contentType = response.headers.get("content-type") ?? "";
            if (!contentType.toLowerCase().includes("application/json")) {
                throw new Error(`unexpected content type: ${contentType || "missing"}`);
            }
            const payload = await response.json();
            if (!response.ok) {
                const error = new Error(
                    payload.message ?? `request failed with ${response.status}`,
                );
                error.status = response.status;
                error.code = payload.code;
                throw error;
            }
            return payload;
        } finally {
            clearTimeout(timeout);
        }
    }
}

const MIGRATION_ORDER_TYPES = Object.freeze({
    MigrationOrder: Object.freeze([
        Object.freeze({ name: "borrower", type: "address" }),
        Object.freeze({ name: "sourceMarketId", type: "uint256" }),
        Object.freeze({ name: "destinationMarketId", type: "uint256" }),
        Object.freeze({ name: "debtAmount", type: "uint256" }),
        Object.freeze({ name: "collateralAmount", type: "uint256" }),
        Object.freeze({ name: "destinationIndexSnapshot", type: "uint256" }),
        Object.freeze({ name: "minHealthFactor", type: "uint256" }),
        Object.freeze({ name: "deadline", type: "uint256" }),
        Object.freeze({ name: "nonce", type: "uint256" }),
    ]),
});

module.exports = {
    CipherDebtClient,
    MIGRATION_ORDER_TYPES,
    UINT256_MAX,
    WAD,
    assessMarket,
    assessPortfolio,
    buildMigrationOrder,
    mulDivDown,
    mulDivUp,
    toUint,
};
