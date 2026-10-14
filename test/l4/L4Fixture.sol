// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockGameRegistry} from "../mocks/MockGameRegistry.sol";
import {Params} from "src/Params.sol";
import {RewardPool} from "src/RewardPool.sol";
import {FeeRouter} from "src/FeeRouter.sol";
import {Economy} from "src/Economy.sol";
import {Civic} from "src/Civic.sol";
import {Billboards} from "src/Billboards.sol";
import {Season} from "src/Season.sol";

/// @dev Only L3 callbacks are stubbed. These fixtures test L4 custody, not farm settlement or minting.
/// No storage of a production contract is patched. The full graph is covered by the existing BaseTest suites.
contract L4Dependencies {
    bool public live = true;
    bool public ready = true;
    uint256 public settledEpoch;
    uint256 public receipts;
    mapping(address => uint256) public lastSettled;
    mapping(address => uint256) public packs;

    function setLive(bool value) external {
        live = value;
    }

    function syncFor(address) external view {
        require(live, "L3 not live");
    }

    function lastAverageDaily() external pure returns (uint256) {
        return 0;
    }

    function lastFarmDaily(address) external pure returns (uint256) {
        return 0;
    }

    function lastYieldPerHash() external pure returns (uint256) {
        return 0;
    }

    function districtActiveHash(uint256) external pure returns (uint256) {
        return 0;
    }

    function seasonReady(uint256) external pure returns (bool) {
        return true;
    }

    function rewardPack(address p) external returns (uint256) {
        ++packs[p];
        return ++receipts;
    }
}

abstract contract L4Fixture is Test {
    MockToken internal asset;
    MockMarket internal exchange;
    MockGameRegistry internal registry;
    L4Dependencies internal l3;
    Params internal parameters;
    RewardPool internal pool;
    FeeRouter internal fees;
    Economy internal economy;
    Civic internal civic;
    Billboards internal boards;
    Season internal season;
    address internal governor;
    address[] internal actors;
    uint256 internal launch;
    uint256 internal constant ACTOR_FUNDS = 1_000_000 ether;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        vm.txGasPrice(20_000_000);
        launch = block.timestamp;
        governor = makeAddr("L4 test governor");
        asset = new MockToken();
        exchange = new MockMarket(address(asset));
        parameters = new Params(governor, 200, 1 ether);
        l3 = new L4Dependencies();
        registry =
            new MockGameRegistry(address(asset), address(parameters), address(exchange), launch, bytes32(0), 0, 0);
        bytes memory args = abi.encode(address(registry));
        pool = RewardPool(deployCode("RewardPool.sol:RewardPool", args));
        fees = FeeRouter(payable(deployCode("FeeRouter.sol:FeeRouter", args)));
        economy = Economy(deployCode("Economy.sol:Economy", args));
        civic = Civic(deployCode("Civic.sol:Civic", args));
        boards = Billboards(deployCode("Billboards.sol:Billboards", args));
        season = Season(deployCode("Season.sol:Season", args));
        registry.setModule(0, address(pool));
        registry.setModule(1, address(l3));
        registry.setModule(2, address(l3));
        registry.setModule(4, address(l3));
        registry.setModule(5, makeAddr("L4 starter producer"));
        registry.setModule(6, address(fees));
        registry.setModule(7, makeAddr("L4 grid producer"));
        registry.setModule(8, address(season));
        registry.setModule(10, address(economy));
        registry.setModule(12, address(civic));
        registry.setModule(13, address(boards));
        // Twelve actors in district 0 exercise the top-ten cap; four in district 1 oppose them.
        uint256 inA;
        uint256 inB;
        for (uint256 nonce = 1; inA < 12 || inB < 4; ++nonce) {
            address p = address(uint160(uint256(keccak256(abi.encode("L4 actor", nonce)))));
            uint256 district = civic.district(p);
            if ((district == 0 && inA < 12) || (district == 1 && inB < 4)) {
                if (district == 0) ++inA;
                else ++inB;
                actors.push(p);
                asset.transfer(p, ACTOR_FUNDS);
                vm.startPrank(p);
                asset.approve(address(boards), type(uint256).max);
                asset.approve(address(civic), type(uint256).max);
                asset.approve(address(economy), type(uint256).max);
                vm.stopPrank();
            }
        }
        asset.transfer(address(exchange), 100_000_000 ether);
        vm.deal(address(exchange), 10_000 ether);
        vm.deal(address(this), 10_000 ether);
    }

    function _enable(uint256 feature) internal {
        vm.prank(governor);
        civic.announce(feature, "L4 test feature notice");
        vm.warp(civic.noticeAt(feature));
        civic.enable(feature);
    }

    function _target(address handler, bytes4[] memory selectors) internal {
        targetContract(handler);
        targetSelector(FuzzSelector({addr: handler, selectors: selectors}));
        // Do not let Foundry auto-fund a protocol address when choosing the transaction sender.
        targetSender(actors[0]);
        targetSender(actors[1]);
    }
}
