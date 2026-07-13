require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");

module.exports = {
    solidity: {
        version: "0.8.24",
        settings: {
            optimizer: {
                enabled: true,
                runs: 10000,
            },
            viaIR: true,
            evmVersion: "paris",
            metadata: {
                bytecodeHash: "none",
            },
        },
    },
    paths: {
        sources: "./src",
        tests: "./test",
        cache: "./cache",
        artifacts: "./artifacts",
    },
    networks: {
        hardhat: {
            allowUnlimitedContractSize: true,
        },
    },
    mocha: {
        timeout: 60000,
    },
};
