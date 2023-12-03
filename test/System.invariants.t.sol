// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {Licenser} from "../src/core/Licenser.sol";
import {DNft} from "src/core/DNft.sol";
import {Dyad} from "src/core/Dyad.sol";
import {Vault} from "src/core/Vault.sol";
import {VaultManager} from "src/core/VaultManager.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {OracleMock} from "./OracleMock.sol";
import {Handler} from "./Handler.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {LibString} from "solady/src/utils/LibString.sol";
import {AddressHelpers} from "./utils/AddressHelpers.sol";

/// @author philogy <https://github.com/philogy>
contract SystemInvariants is Test {
    using AddressHelpers for address[];

    address internal owner;
    Licenser internal minterLicenser;
    Licenser internal vaultLicenser;
    DNft internal dnft;
    Dyad internal dyad;
    VaultManager internal manager;
    Vault[] internal vaults;

    Handler handler;

    bytes4[] selectors;

    function setUp() public {
        owner = makeAddr("owner");
        vm.startPrank(owner);
        dnft = new DNft();

        minterLicenser = new Licenser();
        dyad = new Dyad(minterLicenser);

        vaultLicenser = new Licenser();
        manager = new VaultManager(dnft, dyad, vaultLicenser);
        minterLicenser.add(address(manager));

        vaults.push(_createVault(18, 8));
        vaults.push(_createVault(21, 6));
        vaults.push(_createVault(12, 10));

        for (uint256 i = 0; i < 10; i++) {
            dnft.mintInsiderNft(makeAddr(string.concat("holder_", LibString.toString(i))));
        }

        handler = new Handler(dnft, dyad, manager, vaults);

        selectors.push(Handler.deposit.selector);
        selectors.push(Handler.withdraw.selector);
        selectors.push(Handler.addVault.selector);
        selectors.push(Handler.removeVault.selector);
        selectors.push(Handler.mintDyad.selector);
        selectors.push(Handler.priceDrift.selector);
        selectors.push(Handler.burnDyad.selector);

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
        vm.stopPrank();
    }

    function invariant_allSupplyValidDNftIDs() public {
        uint256 totalDNfts = dnft.totalSupply();
        for (uint256 i = 0; i < totalDNfts; i++) {
            assertTrue(dnft.ownerOf(i) != address(0));
        }
    }

    function invariant_vaultSolvency() public {
        for (uint256 i = 0; i < vaults.length; i++) {
            Vault vault = vaults[i];
            ERC20 asset = vault.asset();
            uint256 totalRecordedAssets = 0;
            for (uint256 id = 0; id < dnft.totalSupply(); id++) {
                totalRecordedAssets += vault.id2asset(id);
            }
            assertEq(asset.balanceOf(address(vault)), totalRecordedAssets);
        }
    }

    function invariant_dyadMintedSupplyConsistent() public {
        uint256 totalMinted;
        for (uint256 id = 0; id < dnft.totalSupply(); id++) {
            totalMinted += dyad.mintedDyad(address(manager), id);
        }
        assertEq(totalMinted, dyad.totalSupply());
    }

    function invariant_addedVaultListConsistency() public {
        for (uint256 id = 0; id < dnft.totalSupply(); id++) {
            address[] memory addedVaults = handler.getAddedVaults(id);
            for (uint256 i = 0; i < addedVaults.length; i++) {
                assertTrue(addedVaults.contains(manager.vaults(id, i)));
            }
            (bool success,) = address(manager).staticcall(abi.encodeCall(manager.vaults, (id, addedVaults.length)));
            assertFalse(success);
            assertLe(addedVaults.length, manager.MAX_VAULTS());
        }
    }

    function invariant_systemCRHealthy() public {
        assertGt(handler.systemCR(), 1.2e18);
    }

    function invariant_participantPositionsCollateralized() public {
        for (uint256 id = 0; id < dnft.totalSupply(); id++) {
            assertGe(handler.usdWorth(id, handler.getAddedVaults(id)), 0);
        }
    }

    function _createVault(uint8 tokenDecimals, uint8 oracleDecimals) internal returns (Vault) {
        OracleMock oracle = new OracleMock(10 ** oracleDecimals, oracleDecimals);
        ERC20Mock token = new ERC20Mock("Mock", "MOCK", tokenDecimals);
        Vault vault = new Vault(manager, ERC20(address(token)), IAggregatorV3(address(oracle)));
        assert(address(vault.vaultManager()) != address(0));
        vaultLicenser.add(address(vault));
        return vault;
    }
}
