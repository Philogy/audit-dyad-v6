// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {console2 as console} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {DNft} from "src/core/DNft.sol";
import {Dyad} from "src/core/Dyad.sol";
import {Vault} from "src/core/Vault.sol";
import {VaultManager} from "src/core/VaultManager.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {OracleMock} from "./OracleMock.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

/// @author philogy <https://github.com/philogy>
contract Handler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    DNft internal immutable dnft;
    Dyad internal immutable dyad;
    VaultManager internal immutable manager;
    Vault[] internal vaults;

    EnumerableSet.AddressSet internal actors;

    uint256 internal constant SANE_CONSTANT_CAP = 10_000_000;

    address immutable liquidator = makeAddr("liquidator");

    mapping(uint256 => EnumerableSet.AddressSet) internal idAddedVaults;

    error VaultHasAssets();

    constructor(DNft _dnft, Dyad _dyad, VaultManager _manager, Vault[] memory _vaults) {
        dnft = _dnft;
        dyad = _dyad;
        manager = _manager;
        vaults = _vaults;
        deal(address(_dyad), liquidator, 1 << 160);
    }

    function addVault(uint256 idSeed, uint256 vaultSeed) public {
        uint256 id = randDNftId(idSeed);
        address actor = dnft.ownerOf(id);
        Vault unusedVault = randUnusedVault(id, vaultSeed);
        if (address(unusedVault) == address(0)) return;
        console.log("added (%d): %s", id, address(unusedVault));
        vm.prank(actor);
        manager.add(id, address(unusedVault));
        require(idAddedVaults[id].add(address(unusedVault)), "Duplicate vault");
    }

    function removeVault(uint256 idSeed, uint256 vaultSeed) public {
        uint256 id = randDNftId(idSeed);
        address actor = dnft.ownerOf(id);
        Vault usedVault = randUsedVault(id, vaultSeed);
        if (address(usedVault) == address(0)) return;
        console.log("removed (%d): %s", id, address(usedVault));
        vm.prank(actor);
        try manager.remove(id, address(usedVault)) {
            require(idAddedVaults[id].remove(address(usedVault)), "Not in vault list");
        } catch (bytes memory errData) {
            if (bytes4(errData) != VaultHasAssets.selector) {
                /// @solidity memory-safe-assembly
                assembly {
                    revert(add(errData, 0x20), mload(errData))
                }
            }
        }
    }

    function priceDrift(uint256 driftSeed) public {
        for (uint256 i = 0; i < vaults.length; i++) {
            Vault vault = vaults[i];
            driftSeed = nextSeed(driftSeed);
            uint256 priceMul = bound(driftSeed, 0.9e18, 1.1e18);
            OracleMock oracle = OracleMock(address(vault.oracle()));
            oracle.setPrice(oracle.price().mulWad(priceMul));
        }

        for (uint256 id = 0; id < dnft.totalSupply(); id++) {
            driftSeed = tryLiquidate(id, driftSeed);
        }
    }

    function deposit(uint256 idSeed, uint256 vaultSeed, uint256 amount) public {
        uint256 id = randDNftId(idSeed);
        address actor = dnft.ownerOf(id);
        Vault vault = randVault(vaultSeed);
        amount = bound(amount, 0, SANE_CONSTANT_CAP * 10 ** vault.asset().decimals());
        ERC20Mock asset = ERC20Mock(address(vault.asset()));
        asset.mint(actor, amount);
        // Assumption (non-critical): `deposit` caller is always dnft owner
        vm.startPrank(actor);
        asset.approve(address(manager), amount);
        manager.deposit(id, address(vault), amount);
        vm.stopPrank();
    }

    function mintDyad(uint256 idSeed, uint256 amount) public {
        uint256 id = randDNftId(idSeed);
        uint256 totalValue = getTotalAssetValue(id, idAddedVaults[id].values());
        uint256 preCr = manager.collatRatio(id);
        uint256 maxSafeDebt = totalValue.divWad(manager.MIN_COLLATERIZATION_RATIO());
        uint256 debt = debtOf(id);
        assertGe(maxSafeDebt, debt, "Maximum safe debt above debt");
        amount = bound(amount, 0, maxSafeDebt - debt);
        address actor = dnft.ownerOf(id);
        vm.prank(actor);
        manager.mintDyad(id, amount, actor);
        uint256 afterCr = manager.collatRatio(id);
        assertGe(preCr, afterCr, "CR increase post mint");
    }

    function burnDyad(uint256 idSeed, uint256 amount) public {
        uint256 id = randDNftId(idSeed);
        amount = bound(amount, 0, debtOf(id));
        vm.prank(dnft.ownerOf(id));
        manager.burnDyad(id, amount);
    }

    function withdraw(uint256 idSeed, uint256 vaultSeed, uint256 amount) public {
        uint256 id = randDNftId(idSeed);
        address actor = dnft.ownerOf(id);
        Vault vault = randVault(vaultSeed);
        uint256 debt = debtOf(id);
        uint256 withdrawCap = vault.id2asset(id);
        if (debt > 0) {
            uint256 minAssets = debt.mulWadUp(manager.MIN_COLLATERIZATION_RATIO());
            uint256 available = manager.getTotalUsdValue(id);
            if (minAssets >= available) {
                withdrawCap = 0;
            } else {
                uint256 withdrawInAmount = getAmountOfValue(vault, available - minAssets);
                withdrawCap = withdrawInAmount < withdrawCap ? withdrawInAmount : withdrawCap;
            }
        }
        amount = bound(amount, 0, withdrawCap);

        // Assumption (non-critical): `withdraw` caller is always dnft owner
        vm.prank(actor);
        manager.withdraw(id, address(vault), amount, actor);
    }

    function getActors() public view returns (address[] memory) {
        return actors.values();
    }

    function getAddedVaults(uint256 id) public view returns (address[] memory) {
        return idAddedVaults[id].values();
    }

    function allVaults() public view returns (address[] memory addrs) {
        Vault[] memory vaults_ = vaults;
        /// @solidity memory-safe-assembly
        assembly {
            addrs := vaults_
        }
    }

    function systemCR() public view returns (uint256) {
        uint256 totalDebt = 0;
        uint256 totalAssetUsdValue = 0;

        for (uint256 id = 0; id < dnft.totalSupply(); id++) {
            totalDebt += debtOf(id);
        }

        if (totalDebt == 0) return type(uint256).max;

        for (uint256 i = 0; i < vaults.length; i++) {
            Vault vault = vaults[i];
            totalAssetUsdValue += getValueOfAmount(vault, vault.asset().balanceOf(address(vault)));
        }

        return totalAssetUsdValue.divWad(totalDebt);
    }

    function getAmountOfValue(Vault vault, uint256 value) public view returns (uint256) {
        return value * 10 ** (vault.oracle().decimals() + vault.asset().decimals()) / vault.assetPrice() / 1e18;
    }

    function getValueOfAmount(Vault vault, uint256 amount) public view returns (uint256) {
        return amount * vault.assetPrice() * 1e18 / 10 ** (vault.oracle().decimals() + vault.asset().decimals());
    }

    function getTotalAssetValue(uint256 id, address[] memory includedVaults) public view returns (uint256) {
        uint256 totalAssetValue = 0;
        for (uint256 i = 0; i < includedVaults.length; i++) {
            Vault vault = Vault(includedVaults[i]);
            totalAssetValue += getValueOfAmount(vault, vault.id2asset(id));
        }
        return totalAssetValue;
    }

    function usdWorth(uint256 id, address[] memory includedVaults) public view returns (int256) {
        return getTotalAssetValue(id, includedVaults).toInt256() - debtOf(id).toInt256();
    }

    function debtOf(uint256 id) internal view returns (uint256) {
        return dyad.mintedDyad(address(manager), id);
    }

    function tryLiquidate(uint256 id, uint256 seed) internal returns (uint256) {
        uint256 cr = manager.collatRatio(id);
        if (cr >= manager.MIN_COLLATERIZATION_RATIO()) return seed;
        uint256 debtToCover = debtOf(id);
        uint256 recipientId = randDNftId(seed);
        seed = nextSeed(seed);
        uint256 worthBefore = usdWorth(recipientId, allVaults()).toUint256();
        vm.prank(liquidator);
        manager.liquidate(id, recipientId);
        console.log("liquidated");
        if (cr >= 1e18) {
            uint256 worthAfter = usdWorth(recipientId, allVaults()).toUint256();
            assertGe(
                worthAfter - worthBefore,
                debtToCover,
                "Invariant: Liquidation of position with CR >= 100% resulted in net loss"
            );
        }
        return seed;
    }

    function nextSeed(uint256 seed) internal pure returns (uint256 newSeed) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, seed)
            newSeed := keccak256(0x00, 0x20)
        }
    }

    function randVault(uint256 seed) internal view returns (Vault) {
        return vaults[seed % vaults.length];
    }

    function randActor(uint256 seed) internal view returns (address) {
        return actors.at(seed % actors.length());
    }

    function randDNftId(uint256 seed) internal view returns (uint256) {
        return bound(seed, 0, dnft.totalSupply() - 1);
    }

    function randUnusedVault(uint256 id, uint256 seed) internal view returns (Vault) {
        uint256 unaddedVaults = vaults.length - idAddedVaults[id].length();
        if (unaddedVaults == 0) return Vault(address(0));
        uint256 vaultIndex = bound(seed, 0, unaddedVaults - 1);
        uint256 unusedIndex = 0;
        for (uint256 i; i < vaults.length; i++) {
            if (!idAddedVaults[id].contains(address(vaults[i]))) {
                if (vaultIndex == unusedIndex) return vaults[i];
                unusedIndex++;
            }
        }
        revert("Unused vault selection failed");
    }

    function randUsedVault(uint256 id, uint256 seed) internal view returns (Vault) {
        uint256 totalAdded = idAddedVaults[id].length();
        if (totalAdded == 0) return Vault(address(0));
        return Vault(idAddedVaults[id].at(bound(seed, 0, totalAdded - 1)));
    }
}
