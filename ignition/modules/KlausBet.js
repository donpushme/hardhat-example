const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

const KlausBet = buildModule("KlausBet", (m) => {
    const klausbet = m.contract("KlausBet");

    return { klausbet };
});

module.exports = KlausBet;