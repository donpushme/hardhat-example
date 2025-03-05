import { ethers } from "hardhat";

async function main() {
  const Collin = await ethers.getContractFactory("Collin");
  const collin = await Collin.deploy();

  await collin.deployed();

  console.log(`Collin token deployed to: ${collin.address}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});