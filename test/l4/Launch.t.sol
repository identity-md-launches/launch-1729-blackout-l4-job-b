// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameModule} from "src/lib/GameModule.sol";
import {ModuleCode} from "src/lib/ModuleCode.sol";

/// @dev One call models one eight-contract factory transaction, including transient-storage semantics.
contract L4BatchProbe {
    function deploy(bytes[] memory initcodes) external returns (address[8] memory deployed) {
        require(initcodes.length == 8);
        for (uint256 i; i < 8; ++i) {
            bytes memory code = initcodes[i];
            address application;
            assembly ("memory-safe") { application := create2(0, add(code, 32), mload(code), i) }
            require(application != address(0), "L4 constructor failed");
            deployed[i] = application;
        }
    }
}

contract L4JobBLaunchTest is Test {
    address private constant RECORDED_REGISTRY = 0x1b41fC9723DF25EeC7e91D947072dCcc2483285F;

    function _codes(address registry) private view returns (bytes[] memory codes) {
        string[8] memory names =
            ["FeeRouter", "GridOperator", "Season", "FarmEngine", "Economy", "Enhancement", "Civic", "Billboards"];
        bytes32[8] memory expected = [
            bytes32(0x3b53c8d89f2836c0744007bac7e168e6c66dd19eaf4a74b2eadd5161ad12e6af),
            0x931bdfaeeacadb7c8014ce1411671d0045013c2b373d95bbf0bb83dfce0b7c74,
            0xa79fdfbecdb2450bc94c1cedac7618b1f4244fe63c3f1bc6fea784f82cd42c83,
            0x48a9f8dd8c707a2a8c6b4a1838640be765a3e3c9d2306680bda5ce679b6dbe7c,
            0x105f9f29d79579fa33ff8e11d4d86847dd7d9f59bd681500553a3844db50ccc9,
            0x31242676dd3a728a2ad32a5cb300166020e87831b0f547756fa0bab88cedea38,
            0xb3e89ec00b8ad51904cdac336644a6025ceea25c15fa931cac2ad13d89dc0bb2,
            0x3cb8b542f7baa025b6db7f2a4864288a594d05e75b9b4e9ec66416c1fe52aa60
        ];
        codes = new bytes[](8);
        for (uint256 i; i < 8; ++i) {
            bytes memory creation = vm.getCode(string.concat(names[i], ".sol:", names[i]));
            assertEq(keccak256(creation), expected[i], names[i]);
            assertEq(ModuleCode.launchHash(i + 6), expected[i], "bound L3 registry pin");
            codes[i] = bytes.concat(creation, abi.encode(registry));
            assertLe(codes[i].length, 49_152, "EIP-3860 initcode size");
        }
    }

    function test_jobBExactPinsAndConstructorOrderOnEmptyChain4663() public {
        vm.chainId(4663);
        assertEq(RECORDED_REGISTRY.code.length, 0, "constructors must not need a live dependency");
        L4BatchProbe probe = new L4BatchProbe();
        bytes[] memory codes = _codes(RECORDED_REGISTRY);
        address[8] memory applications = probe.deploy(codes);
        for (uint256 i; i < 8; ++i) {
            address predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(probe), bytes32(i), keccak256(codes[i]))))
                )
            );
            assertEq(applications[i], predicted, "batch index/salt must match");
            assertEq(address(GameModule(applications[i]).registry()), RECORDED_REGISTRY);
            bytes memory code = applications[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "escape opcode");
            }
        }
        vm.expectRevert("L4 constructor failed");
        probe.deploy(codes);
    }

    function test_eachZeroRegistryConstructorAbortsTheEntireBatch() public {
        bytes[] memory valid = _codes(RECORDED_REGISTRY);
        bytes[] memory invalid = _codes(address(0));
        for (uint256 bad; bad < 8; ++bad) {
            L4BatchProbe probe = new L4BatchProbe();
            bytes memory saved = valid[bad];
            valid[bad] = invalid[bad];
            vm.expectRevert("L4 constructor failed");
            probe.deploy(valid);
            valid[bad] = saved;
            // Successful retry proves every earlier CREATE2 in the failed batch was rolled back.
            address[8] memory applications = probe.deploy(valid);
            for (uint256 i; i < 8; ++i) {
                assertGt(applications[i].code.length, 0);
            }
        }
    }
}
