const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

const Disperse = buildModule("Disperse", (m) => {
  const disperse = m.contract("Disperse");

  return { disperse };
});

module.exports = Disperse;