"use strict";

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const expectedDocs = [
    "architecture.md",
    "debt-accounting.md",
    "economic-model.md",
    "governance.md",
    "operations.md",
    "sdk.md",
    "security-model.md",
];
const excludedDirectories = new Set([".git", "artifacts", "cache", "coverage", "node_modules"]);
const textExtensions = new Set([".js", ".json", ".md", ".sh", ".sol", ".yml", ".yaml"]);
const forbiddenTerms = [
    "c" + "tf",
    "la" + "boratorio",
    "l" + "a" + "b",
    "vulnera" + "bilidad",
    "vulnera" + "ble",
    "vulnera" + "bility",
    "b" + "ug",
    "ex" + "ploit",
];
const forbiddenNarrative = new RegExp(`\\b(?:${forbiddenTerms.join("|")})\\b`, "i");

function fail(message) {
    throw new Error(message);
}

function read(relativePath) {
    return fs.readFileSync(path.join(root, relativePath), "utf8");
}

function walk(directory, files = []) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        if (entry.isDirectory() && excludedDirectories.has(entry.name)) continue;
        const fullPath = path.join(directory, entry.name);
        if (entry.isDirectory()) walk(fullPath, files);
        else files.push(fullPath);
    }
    return files;
}

const docsDirectory = path.join(root, "docs");
const actualDocs = fs
    .readdirSync(docsDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort();
if (JSON.stringify(actualDocs) !== JSON.stringify([...expectedDocs].sort())) {
    fail(`docs/ must contain exactly: ${expectedDocs.join(", ")}`);
}

const readme = read("README.md");
const security = read("SECURITY.md");
if (!readme.includes("![CipherDebtProtocol](./assets/banner.png)")) {
    fail("README.md must reference the canonical banner");
}
if (!security.includes("Production 1.0.0"))
    fail("SECURITY.md must identify the maintained release");

const diagramCount = [readme, security, ...expectedDocs.map((file) => read(`docs/${file}`))].reduce(
    (count, content) => count + (content.match(/```mermaid/g) ?? []).length,
    0,
);
if (diagramCount < 15) fail("documentation must contain at least 15 Mermaid diagrams");

const bannerPath = path.join(root, "assets", "banner.png");
const bannerBytes = fs.statSync(bannerPath).size;
if (bannerBytes < 100_000) fail("banner.png is unexpectedly small");

const packageJson = JSON.parse(read("package.json"));
const packageLock = JSON.parse(read("package-lock.json"));
if (packageJson.version !== "1.0.0" || packageLock.version !== "1.0.0") {
    fail("package metadata must resolve to version 1.0.0");
}
for (const script of ["compile", "test", "test:node", "lint", "verify", "ci"]) {
    if (!packageJson.scripts[script]) fail(`missing package script: ${script}`);
}

const tracked = execFileSync("git", ["ls-files"], { cwd: root, encoding: "utf8" })
    .split(/\r?\n/)
    .filter(Boolean);
const privatePath = tracked.find((file) => /(^|\/)(?:private|proof)(?:\/|\.|$)/i.test(file));
if (privatePath) fail(`private material is tracked: ${privatePath}`);

for (const fullPath of walk(root)) {
    if (!textExtensions.has(path.extname(fullPath).toLowerCase())) continue;
    if (fullPath.endsWith("package-lock.json") || fullPath.endsWith("bun.lock")) continue;
    const relativePath = path.relative(root, fullPath).replaceAll("\\", "/");
    const content = fs.readFileSync(fullPath, "utf8");
    const match = content.match(forbiddenNarrative);
    if (match) fail(`disallowed public narrative in ${relativePath}: ${match[0]}`);
}

const solidityNonBlank = tracked
    .filter((file) => file.startsWith("src/") && file.endsWith(".sol"))
    .reduce(
        (count, file) =>
            count +
            read(file)
                .split(/\r?\n/)
                .filter((line) => line.trim()).length,
        0,
    );

console.log(
    `repository verified: docs=${actualDocs.length}, diagrams=${diagramCount}, banner=${bannerBytes}, solidity=${solidityNonBlank}, trackedPrivate=0`,
);
