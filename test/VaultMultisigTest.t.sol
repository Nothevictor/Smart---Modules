/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/VaultMultisig.sol";

// Mock-контракт для тестирования неудачных переводов
contract RejectingReceiver {
    receive() external payable {
        revert("ETH transfer rejected");
    }
}

contract VaultMultisigTest is Test {
    VaultMultisig vault;
    address[] signers;
    address signer1 = makeAddr("signer1");
    address signer2 = makeAddr("signer2");
    address signer3 = makeAddr("signer3");
    address nonSigner = makeAddr("nonSigner");
    address recipient = makeAddr("recipient");

    uint256 constant INITIAL_BALANCE = 10 ether;
    uint256 constant TRANSFER_AMOUNT = 1 ether;

    // События и ошибки для более чистого тестирования
    event TransferInitiated(uint256 indexed transferId, address indexed to, uint256 amount);
    event TransferApproved(uint256 indexed transferId, address indexed approver);
    event TransferExecuted(uint256 indexed transferId);
    event QuorumUpdated(uint256 quorum);
    event MultiSigSignersUpdated();

    function setUp() public {
        // Инициализируем массив подписантов
        signers.push(signer1);
        signers.push(signer2);
        signers.push(signer3);

        // Разворачиваем контракт с кворумом 2 из 3
        vault = new VaultMultisig(signers, 2);

        // Пополняем контракт начальным балансом
        vm.deal(address(vault), INITIAL_BALANCE);
    }

    /*
     * ТЕСТЫ КОНСТРУКТОРА
     */

    function test_Revert_When_SignersEmpty() public {
        address[] memory emptySigners;
        vm.expectRevert(VaultMultisig.SignersArrayCannotBeEmpty.selector);
        new VaultMultisig(emptySigners, 1);
    }

    function test_Revert_When_QuorumIsZero() public {
        vm.expectRevert(VaultMultisig.QuorumCannotBeZero.selector);
        new VaultMultisig(signers, 0);
    }

    function test_Revert_When_QuorumGreaterThanSigners() public {
        vm.expectRevert(VaultMultisig.QuorumGreaterThanSigners.selector);
        new VaultMultisig(signers, 4);
    }

    function test_InitialStateIsCorrect() public {
        assertEq(vault.quorum(), 2);
        assertEq(address(vault).balance, INITIAL_BALANCE);
        assertTrue(vault.hasSignedTransfer(0, address(0)) == false);
    }

    function test_InitiateTransfer_Success() public {
        vm.prank(signer1);
        vm.expectEmit(true, true, false, true);
        emit TransferInitiated(0, recipient, TRANSFER_AMOUNT);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);

        (address to, uint256 amount, uint256 approvals, bool executed) = vault.getTransfer(0);
        assertEq(to, recipient);
        assertEq(amount, TRANSFER_AMOUNT);
        assertEq(approvals, 1);
        assertEq(executed, false);
        assertTrue(vault.hasSignedTransfer(0, signer1));
        assertEq(vault.getTransferCount(), 1);
    }

    function test_Revert_When_NonSignerInitiatesTransfer() public {
        vm.prank(nonSigner);
        vm.expectRevert(VaultMultisig.InvalidMultisigSigner.selector);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);
    }

    function test_Revert_When_RecipientIsZeroAddress() public {
        vm.prank(signer1);
        vm.expectRevert(VaultMultisig.InvalidRecipient.selector);
        vault.initiateTransfer(address(0), TRANSFER_AMOUNT);
    }

    function test_Revert_When_AmountIsZero() public {
        vm.prank(signer1);
        vm.expectRevert(VaultMultisig.InvalidAmount.selector);
        vault.initiateTransfer(recipient, 0);
    }

    function test_Revert_When_VaultIsEmpty() public {
        // Создаем новый пустой vault
        VaultMultisig emptyVault = new VaultMultisig(signers, 2);
        vm.prank(signer1);
        vm.expectRevert(VaultMultisig.VaultIsEmpty.selector);
        emptyVault.initiateTransfer(recipient, TRANSFER_AMOUNT);
    }

    function test_ApproveTransfer_Success() public {
        vm.prank(signer1);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);
        vm.prank(signer2);
        vm.expectEmit(true, true, false, true);
        emit TransferApproved(0, signer2);
        vault.approveTransfer(0);

        (,, uint256 approvals,) = vault.getTransfer(0);
        assertEq(approvals, 2);
        assertTrue(vault.hasSignedTransfer(0, signer2));
    }

    function test_Revert_When_NonSignerApproves() public {
        vm.prank(signer1);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);

        vm.prank(nonSigner);
        vm.expectRevert(VaultMultisig.InvalidMultisigSigner.selector);
        vault.approveTransfer(0);
    }

    function test_Revert_When_SignerAlreadyApproved() public {
        vm.prank(signer1);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);

        vm.prank(signer1);
        vm.expectRevert(abi.encodeWithSelector(VaultMultisig.SignerAlreadyApproved.selector, signer1));
        vault.approveTransfer(0);
    }

    function test_ExecuteTransfer_Success() public {
        uint256 recipientInitialBalance = recipient.balance;

        vm.prank(signer1);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);

        vm.prank(signer2);
        vault.approveTransfer(0);

        vm.prank(signer3);
        vm.expectEmit(true, false, false, true);
        emit TransferExecuted(0);
        vault.executeTransfer(0);

        (,,, bool executed) = vault.getTransfer(0);
        assertTrue(executed);
        assertEq(address(vault).balance, INITIAL_BALANCE - TRANSFER_AMOUNT);
        assertEq(recipient.balance, recipientInitialBalance + TRANSFER_AMOUNT);
    }

    function test_Revert_When_QuorumNotReached() public {
        vm.prank(signer1);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);

        vm.prank(signer2);
        vm.expectRevert(abi.encodeWithSelector(VaultMultisig.QuorumHasNotBeenReached.selector, 0));
        vault.executeTransfer(0);
    }

    function test_Revert_When_TransferAlreadyExecuted() public {
        vm.prank(signer1);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);
        vm.prank(signer2);
        vault.approveTransfer(0);
        vm.prank(signer3);
        vault.executeTransfer(0);

        vm.prank(signer1);
        vm.expectRevert(abi.encodeWithSelector(VaultMultisig.TransferIsAlreadyExecuted.selector, 0));
        vault.executeTransfer(0);
    }

    function test_Revert_When_InsufficientBalance() public {
        uint256 largeAmount = INITIAL_BALANCE + 1 ether;
        vm.prank(signer1);
        vault.initiateTransfer(recipient, largeAmount);
        vm.prank(signer2);
        vault.approveTransfer(0);

        vm.prank(signer3);
        vm.expectRevert(
            abi.encodeWithSelector(VaultMultisig.InsufficientBalance.selector, address(vault).balance, largeAmount)
        );
        vault.executeTransfer(0);
    }

    function test_Revert_When_TransferFailed() public {
        RejectingReceiver rejectingReceiver = new RejectingReceiver();

        vm.prank(signer1);
        vault.initiateTransfer(address(rejectingReceiver), TRANSFER_AMOUNT);
        vm.prank(signer2);
        vault.approveTransfer(0);

        vm.prank(signer3);
        vm.expectRevert(abi.encodeWithSelector(VaultMultisig.TransferFailed.selector, 0));
        vault.executeTransfer(0);
    }

    function test_UpdateSignersAndQuorum_Success() public {
        address newSigner4 = makeAddr("newSigner4");
        address[] memory newSigners = new address[](3);
        newSigners[0] = signer1;
        newSigners[1] = signer2;
        newSigners[2] = newSigner4;
        uint256 newQuorum = 3;

        vm.prank(signer1);
        vm.expectEmit(true, false, false, true);
        emit MultiSigSignersUpdated();
        vm.expectEmit(true, false, false, true);
        emit QuorumUpdated(newQuorum);

        vault.updateSignersAndQuorum(newSigners, newQuorum);

        assertEq(vault.quorum(), newQuorum);

        vm.prank(newSigner4);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);

        // Verify that the transfer was created successfully
        (address to, uint256 amount, uint256 approvals, bool executed) = vault.getTransfer(0);
        assertEq(to, recipient);
        assertEq(amount, TRANSFER_AMOUNT);
        assertEq(approvals, 1);
        assertEq(executed, false);

        vm.prank(signer3);
        vm.expectRevert(VaultMultisig.InvalidMultisigSigner.selector);
        vault.initiateTransfer(recipient, TRANSFER_AMOUNT);
    }

    function test_Revert_UpdateSigners_When_NewSignersEmpty() public {
        address[] memory emptySigners;
        vm.prank(signer1);
        vm.expectRevert(VaultMultisig.SignersArrayCannotBeEmpty.selector);
        vault.updateSignersAndQuorum(emptySigners, 1);
    }

    function test_Revert_UpdateSigners_When_NewQuorumIsZero() public {
        address[] memory newSigners = new address[](1);
        newSigners[0] = signer1;
        vm.prank(signer1);
        vm.expectRevert(VaultMultisig.QuorumCannotBeZero.selector);
        vault.updateSignersAndQuorum(newSigners, 0);
    }

    function test_Revert_UpdateSigners_When_NewQuorumTooHigh() public {
        address[] memory newSigners = new address[](2);
        newSigners[0] = signer1;
        newSigners[1] = signer2;
        vm.prank(signer1);
        vm.expectRevert(VaultMultisig.QuorumGreaterThanSigners.selector);
        vault.updateSignersAndQuorum(newSigners, 3);
    }

    function test_ReceiveEther() public {
        uint256 depositAmount = 5 ether;
        (bool success,) = address(vault).call{value: depositAmount}("");
        assertTrue(success, "Receive ether failed");
        assertEq(address(vault).balance, INITIAL_BALANCE + depositAmount);
    }
}
