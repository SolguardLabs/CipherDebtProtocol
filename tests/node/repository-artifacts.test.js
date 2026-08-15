const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "../..");
const expectedDocs = [
    "architecture.md",
    "debt-accounting.md",
    "economic-model.md",
    "governance.md",
    "operations.md",
    "sdk.md",
    "security-model.md",
];

const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");

test("documentation inventory is exact and diagram-rich", () => {
    const actual = fs.readdirSync(path.join(root, "docs")).sort();
    assert.deepEqual(actual, [...expectedDocs].sort());
    const documents = [
        read("README.md"),
        read("SECURITY.md"),
        ...actual.map((file) => read(`docs/${file}`)),
    ];
    const diagrams = documents.reduce(
        (count, document) => count + (document.match(/```mermaid/g) ?? []).length,
        0,
    );
    assert.ok(diagrams >= 15);
});

test("README consumes the canonical production banner", () => {
    assert.match(read("README.md"), /^# CipherDebtProtocol/m);
    assert.match(read("README.md"), /!\[CipherDebtProtocol\]\(\.\/assets\/banner\.png\)/);
    assert.ok(fs.statSync(path.join(root, "assets", "banner.png")).size > 100_000);
});

test("release metadata and repository controls are present", () => {
    const metadata = JSON.parse(read("package.json"));
    assert.equal(metadata.version, "1.0.0");
    assert.ok(metadata.scripts.ci);
    assert.ok(fs.existsSync(path.join(root, ".github", "workflows", "ci.yml")));
    assert.ok(fs.existsSync(path.join(root, ".github", "workflows", "release-integrity.yml")));
    assert.match(read("SECURITY.md"), /Production 1\.0\.0/);
});
