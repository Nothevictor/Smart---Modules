/// SPDX-License-Identifier: MIT
/// @title: Contract for a wallet with multisig withdrawal for multiple ERC20 tokens.
/// @notice: Allows withdrawing ERC20 tokens from the vault only if a certain number of signers approve the transaction.
/// @author: Solidity University
pragma solidity ^0.8.30;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract VaultMultisig {
    /// @notice The number of signatures required to execute a transaction
    uint256 public quorum;

    /// @notice The number of transfers executed
    uint256 public transfersCount;

    /// @notice The current multisig signers
    address[] public currentMultiSigSigners;

    /// @dev Struct to store the details of a transfer
    /// @param token The address of the ERC20 token contract
    /// @param to The address of the recipient
    /// @param amount The amount of tokens to transfer
    /// @param approvals The number of approvals required to execute the transfer
    /// @param executed Whether the transfer has been executed
    /// @param cancelled Whether the transfer has been cancelled
    /// @param approved Mapping of signers to their approval status
    struct Transfer {
        address token;
        address to;
        uint256 amount;
        uint256 approvals;
        bool executed;
        bool cancelled;
        mapping(address => bool) approved;
    }

    /// @notice Mapping of transfer IDs to transfer details
    mapping (uint256 => Transfer) private transfers;

    /// @notice Mapping to verify if an address is a signer
    mapping (address => bool) private multiSigSigners;

    /// @notice Checks that the signers array is not empty
    error SignersArrayCannotBeEmpty();

    /// @notice Checks that the quorum does not exceed the number of signers
    error QuorumGreaterThanSigners();

    /// @notice Checks that the quorum is greater than zero
    error QuorumCannotBeZero();

    /// @notice Checks that the recipient address is not zero
    error InvalidRecipient();

    /// @notice Checks that the token address is not zero
    error InvalidToken();

    /// @notice Checks that the amount is greater than zero
    error InvalidAmount();

    /// @notice Checks that the signer is a multisig signer
    error InvalidMultisigSigner();

    /// @notice Checks that the token balance is sufficient for the transfer
    error InsufficientTokenBalance(uint256 balance, uint256 desiredAmount);

    /// @notice Checks that the transfer is not already executed
    /// @param transferId The ID of the transfer
    error TransferIsAlreadyExecuted(uint256 transferId);

    /// @notice Checks that the transfer is not already cancelled
    /// @param transferId The ID of the transfer
    error TransferAlreadyCancelled(uint256 transferId);

    /// @notice Checks that the signer has already approved the transfer
    /// @param signer The address of the signer
    error SignerAlreadyApproved(address signer);

    /// @notice Checks that the transfer failed
    /// @param transferId The ID of the transfer
    error TransferFailed(uint256 transferId);

    /// @notice Checks that the quorum for the transfer has not been reached
    /// @param transferId The ID of the transfer
    error QuorumHasNotBeenReached(uint256 transferId);

    /// @notice Emitted when a transfer is initiated
    event TransferInitiated(uint256 indexed transferId, address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a transfer is approved
    event TransferApproved(uint256 indexed transferId, address indexed approver);

    /// @notice Emitted when a transfer is executed
    event TransferExecuted(uint256 indexed transferId);

    /// @notice Emitted when a transfer is cancelled
    event TransferCancelled(uint256 indexed transferId, address indexed canceller);

    /// @notice Emitted when the multisig signers are updated
    event MultiSigSignersUpdated();

    /// @notice Emitted when the quorum is updated
    event QuorumUpdated(uint256 quorum);

    modifier onlyMultisigSigner() {
        if (!multiSigSigners[msg.sender]) revert InvalidMultisigSigner();
        _;
    }

    /// @notice Initializes the multisig contract
    /// @param _signers Array of signer addresses
    /// @param _quorum Number of signatures required to execute a transaction
    constructor(address[] memory _signers, uint256 _quorum) {
        if (_signers.length == 0) revert SignersArrayCannotBeEmpty();
        if (_quorum > _signers.length) revert QuorumGreaterThanSigners();
        if (_quorum == 0) revert QuorumCannotBeZero();

        for (uint256 i = 0; i < _signers.length; i++) {
            multiSigSigners[_signers[i]] = true;
        }

        quorum = _quorum;
        currentMultiSigSigners = _signers;
    }

    /// @notice Initiates a transfer
    /// @param _token Address of the ERC20 token contract
    /// @param _to Address of the recipient
    /// @param _amount Amount of tokens to transfer
    function initiateTransfer(address _token, address _to, uint256 _amount) external onlyMultisigSigner {
        if (_to == address(0)) revert InvalidRecipient();
        if (_token == address(0)) revert InvalidToken();
        if (_amount <= 0) revert InvalidAmount();

        uint256 transferId = transfersCount++;
        Transfer storage transfer = transfers[transferId];
        transfer.token = _token;
        transfer.to = _to;
        transfer.amount = _amount;
        transfer.approvals = 0;
        transfer.executed = false;
        transfer.cancelled = false;
        transfer.approved[msg.sender] = true;

        emit TransferInitiated(transferId, _token, _to, _amount);
    }

    /// @notice Approves a transfer
    /// @param _transferId The ID of the transfer
    function approveTransfer(uint256 _transferId) external onlyMultisigSigner {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.executed) revert TransferIsAlreadyExecuted(_transferId);
        if (transfer.cancelled) revert TransferAlreadyCancelled(_transferId);
        if (transfer.approved[msg.sender]) revert SignerAlreadyApproved(msg.sender);

        transfer.approvals++;
        transfer.approved[msg.sender] = true;

        emit TransferApproved(_transferId, msg.sender);
    }

    /// @notice Executes a transfer
    /// @param _transferId The ID of the transfer
    function executeTransfer(uint256 _transferId) external onlyMultisigSigner {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.approvals < quorum) revert QuorumHasNotBeenReached(_transferId);
        if (transfer.executed) revert TransferIsAlreadyExecuted(_transferId);
        if (transfer.cancelled) revert TransferAlreadyCancelled(_transferId);

        IERC20 token = IERC20(transfer.token);
        uint256 balance = token.balanceOf(address(this));
        if (transfer.amount > balance) revert InsufficientTokenBalance(balance, transfer.amount);

        bool success = token.transfer(transfer.to, transfer.amount);
        if (!success) revert TransferFailed(_transferId);

        transfer.executed = true;

        emit TransferExecuted(_transferId);
    }

    /// @notice Cancels a transfer
    /// @param _transferId The ID of the transfer
    function cancelTransfer(uint256 _transferId) external onlyMultisigSigner {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.executed) revert TransferIsAlreadyExecuted(_transferId);
        if (transfer.cancelled) revert TransferAlreadyCancelled(_transferId);

        transfer.cancelled = true;

        emit TransferCancelled(_transferId, msg.sender);
    }

    /// @notice Gets the details of a transfer
    /// @param _transferId The ID of the transfer
    /// @return token The address of the token
    /// @return to The address of the recipient
    /// @return amount The amount of tokens to transfer
    /// @return approvals The number of approvals required to execute the transfer
    /// @return executed Whether the transfer has been executed
    /// @return cancelled Whether the transfer has been cancelled
    function getTransfer(uint256 _transferId) external view returns (
        address token,
        address to,
        uint256 amount,
        uint256 approvals,
        bool executed,
        bool cancelled
    ) {
        Transfer storage transfer = transfers[_transferId];
        return (transfer.token, transfer.to, transfer.amount, transfer.approvals, transfer.executed, transfer.cancelled);
    }

    /// @notice Checks if a signer has signed a transfer
    /// @param _transferId The ID of the transfer
    /// @param _signer The address of the signer
    /// @return hasSigned Whether the signer has signed the transfer
    function hasSignedTransfer(uint256 _transferId, address _signer) external view returns (bool) {
        Transfer storage transfer = transfers[_transferId];
        return transfer.approved[_signer];
    }

    /// @notice Gets the number of transfers
    /// @return The number of transfers
    function getTransferCount() external view returns (uint256) {
        return transfersCount;
    }
}