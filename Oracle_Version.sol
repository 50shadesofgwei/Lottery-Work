//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// load other contracts
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
// for debugging
import "hardhat/console.sol";

contract Lottery is Ownable, VRFConsumerBase, AutomationCompatibleInterface {
    using Math for uint256;

    // State Variables
    struct LotteryStruct {
        uint256 lotteryId;
        bool isActive; // minting tickets is allowed. TASK: rename to "isMintingPeriodActive"?
        bool isCompleted; // winner was found; winnings were deposited.
        bool isCreated; // is created
    }

    bytes32 internal keyHash;
    uint256 internal fee;
    uint256 public randomResult;

    struct TicketDistributionStruct {
        address playerAddress;
        uint256 startIndex; // inclusive
        uint256 endIndex; // inclusive
    }
    struct WinningTicketStruct {
        uint256 currentLotteryId;
        uint256 winningTicketIndex;
        address winningAddress; // TASK: rename to "winningAddress"?
    }
    /* TASK: rename to TICKET_PRICE? More human readable, makes more sense. Although it technically is the minimum increment.
     */
    uint256 public constant MIN_DRAWING_INCREMENT = 1000000000000000; // 0.00001 ETH; min eth amount to enter lottery.

    uint public immutable interval;
    uint public lastTimeStamp;
    uint public counter;

    // max # loops allowed for binary search; to prevent some bugs causing infinite loops in binary search
    uint256 public maxLoops = 50;
    uint256 private loopCount = 0; // for binary search

    uint256 public currentLotteryId = 0;
    uint256 public numLotteries = 0;
    uint256 public prizeAmount; // winnings. Probably duplicate and can be removed. Just use numTotalTickets/ (MIN_DRAWING_INCREMENT) to calculate prize amount

    WinningTicketStruct public winningTicket;
    TicketDistributionStruct[] public ticketDistribution;
    address[] public listOfPlayers; // won't be deleted; sucessive lotteries overwrite indices. Don't rely on this for current participants list

    uint256 public numActivePlayers;
    uint256 public numTotalTickets;

    mapping(uint256 => uint256) public prizes; // key is lotteryId
    mapping(uint256 => WinningTicketStruct) public winningTickets; // key is lotteryId
    mapping(address => bool) public players; // key is player address
    mapping(address => uint256) public tickets; // key is player address
    mapping(uint256 => LotteryStruct) public lotteries; // key is lotteryId
    mapping(uint256 => mapping(address => uint256)) public pendingWithdrawals; // pending withdrawals for each winner, key is lotteryId, then player address
    // withdrawal design pattern

    // Events
    event LogNewLottery(address creator); // emit when lottery created
    event LogTicketsMinted(address player, uint256 numTicketsMinted); // emit when user purchases tix
    // emit when lottery drawing happens; winner found
    event LogWinnerFound(
        uint256 lotteryId,
        uint256 winningTicketIndex,
        address winningAddress
    );
    // emit when lottery winnings deposited in pending withdrawals
    event LotteryWinningsDeposited(
        uint256 lotteryId,
        address winningAddress,
        uint256 amountDeposited
    );
    // emit when funds withdrawn by winner
    event LogWinnerFundsWithdrawn(
        address winnerAddress,
        uint256 withdrawalAmount
    );
    // emit when owner has changed max player param
    event LogMaxPlayersAllowedUpdated(uint256 maxPlayersAllowed);

    // Errors
    error Lottery__ActiveLotteryExists();
    error Lottery__MintingPeriodClosed();
    error Lottery__MintingNotCompleted();
    error Lottery__InadequateFunds();
    error Lottery__InvalidWinningIndex();
    error Lottery__InvalidWithdrawalAmount();
    error Lottery__WithdrawalFailed();

    // modifiers
    /* @dev check that new lottery is a valid implementation
    previous lottery must be inactive for new lottery to be saved
    for when new lottery will be saved
    */
    modifier isNewLotteryValid() {
        // active lottery
        LotteryStruct memory lottery = lotteries[currentLotteryId];
        if (lottery.isActive == true) {
            revert Lottery__ActiveLotteryExists();
        }
        _;
    }

    /* @dev check that minting period is completed, and lottery drawing can begin
    either:
    1) minting period manually ended, ie lottery is inactive. Then drawing can begin immediately.
    2) lottery minting period has ended organically, and lottery is still active at that point
    */
    modifier isLotteryMintingCompleted() {
        if (
            (lotteries[currentLotteryId].isActive == true)
        ) {
            revert Lottery__MintingNotCompleted();
        }
        _;
    }
    /* check that new player has enough eth to buy at least 1 ticket
     */
    modifier isNewPlayerValid() {
        if (msg.value.min(MIN_DRAWING_INCREMENT) < MIN_DRAWING_INCREMENT) {
            revert Lottery__InadequateFunds();
        }
        _;
    }

    
    constructor (uint updateInterval)
        VRFConsumerBase(
            	0x2Ca8E0C643bDe4C2E08ab1fA0da3401AdAD7734D,
                0x326C977E6efc84E512bB9C30f76E30c160eD06FB
            ) {
                keyHash = 0x79d3d8832d904592c0bf9818b621522c988bb8b0c05cdc3b15aea1b6e8db0c15;
                fee = 0.25 * 10 ** 18;
                interval = updateInterval;
                lastTimeStamp = block.timestamp;
            }

        
    function getRandomNumber() public returns (bytes32 requestId) {
        require(LINK.balanceOf(address(this)) >= fee, "Insufficient LINK in contract");
        return requestRandomness(keyHash, fee);
    }
 
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        randomResult = randomness % (numTotalTickets);
    }

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory)
    {
        upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
    }

    function performUpkeep(bytes calldata performData) public override onlyOwner{
        if ((block.timestamp - lastTimeStamp) > interval) {
            lastTimeStamp = block.timestamp;
            getRandomNumber();
            triggerLotteryDrawing();
            triggerDepositWinnings();
            initLottery();
        }
    }

    /*
     * @title initLottery
     * @dev A function to initialize a lottery
     * probably should also be onlyOwner
     * @param uint256 startTime_: start of minting period, unixtime
     * @param uint256 numHours: in hours, how long mint period will last
     */
    function initLottery()
        public
        isNewLotteryValid
        onlyOwner
    {
        lotteries[currentLotteryId] = LotteryStruct({
            lotteryId: currentLotteryId,
            isActive: true,
            isCompleted: false,
            isCreated: true
        });
        numLotteries = numLotteries + 1;
        emit LogNewLottery(msg.sender);
    }

    /*
     * @title mintLotteryTickets
     * @dev a function for players to mint lottery tix
     */
    function mintLotteryTickets() external payable isNewPlayerValid {
        uint256 _numTicketsToMint = msg.value / (MIN_DRAWING_INCREMENT);
        require(_numTicketsToMint >= 1); // double check that user put in at least enough for 1 ticket
        // if player is "new" for current lottery, update the player lists

        // memory var to conserve gas
        uint _numActivePlayers = numActivePlayers;

        if (players[msg.sender] == false) {
            if (listOfPlayers.length > _numActivePlayers) {
                listOfPlayers[_numActivePlayers] = msg.sender; // set based on index for when lottery is reset - overwrite array instead of delete to save gas
            } else {
                listOfPlayers.push(msg.sender); // otherwise append to array
            }
            players[msg.sender] = true;
            numActivePlayers = _numActivePlayers + 1;
        }
        tickets[msg.sender] = tickets[msg.sender] + _numTicketsToMint; // account for if user has already minted tix previously for this current lottery
        prizeAmount = prizeAmount + (msg.value); // update the pot size
        numTotalTickets = numTotalTickets + _numTicketsToMint; // update the total # of tickets minted
        emit LogTicketsMinted(msg.sender, _numTicketsToMint);
    }

    /*
     * @title triggerLotteryDrawing
     * @dev a function for owner to trigger lottery drawing
     */
    function triggerLotteryDrawing()
        public
        isLotteryMintingCompleted
        onlyOwner
    {
        // console.log("triggerLotteryDrawing");
        prizes[currentLotteryId] = prizeAmount; // keep track of prize amts for each of the previous lotteries

        _playerTicketDistribution(); // create the distribution to get ticket indexes for each user
        // can't be done a priori bc of potential multiple mints per user
        uint256 winningTicketIndex = randomResult;
        // initialize what we can first
        winningTicket.currentLotteryId = currentLotteryId;
        winningTicket.winningTicketIndex = winningTicketIndex;
        findWinningAddress(winningTicketIndex); // via binary search

        emit LogWinnerFound(
            currentLotteryId,
            winningTicket.winningTicketIndex,
            winningTicket.winningAddress
        );
    }

    /*
     * @title triggerDepositWinnings // TASK: rename to maybe depositWinnings
     * @dev function to deposit winnings for user withdrawal pattern
     * then reset lottery params for new one to be created
     */
    function triggerDepositWinnings() public {
        // console.log("triggerDepositWinnings");
        pendingWithdrawals[currentLotteryId][winningTicket.winningAddress] = prizeAmount;
        prizeAmount = 0;
        lotteries[currentLotteryId].isCompleted = true;
        winningTickets[currentLotteryId] = winningTicket;
        // emit before resetting lottery so vars still valid
        emit LotteryWinningsDeposited(
            currentLotteryId,
            winningTicket.winningAddress,
            pendingWithdrawals[currentLotteryId][winningTicket.winningAddress]
        );
        _resetLottery();
    }

    /*
     * @title getTicketDistribution
     * @dev getter function for ticketDistribution bc its a struct
     */
    function getTicketDistribution(uint256 playerIndex_)
        public
        view
        returns (
            address playerAddress,
            uint256 startIndex, // inclusive
            uint256 endIndex // inclusive
        )
    {
        return (
            ticketDistribution[playerIndex_].playerAddress,
            ticketDistribution[playerIndex_].startIndex,
            ticketDistribution[playerIndex_].endIndex
        );
    }

    /*
     * @title _playerTicketDistribution
     * @dev function to handle creating the ticket distribution
     * if 1) player1 buys 10 tix, then 2) player2 buys 5 tix, and then 3) player1 buys 5 more
     * player1's ticket indices will be 0-14; player2's from 15-19
     * this is why ticketDistribution cannot be determined until minting period is closed
     */
    function _playerTicketDistribution() private {
        // console.log("_playerTicketDistribution");
        uint _ticketDistributionLength = ticketDistribution.length; // so state var doesn't need to be invoked each iteration of loop
        uint256 _ticketIndex = 0; // counter within loop
        for (uint256 i = _ticketIndex; i < numActivePlayers; i++) {
            address _playerAddress = listOfPlayers[i];
            uint256 _numTickets = tickets[_playerAddress];

            TicketDistributionStruct memory newDistribution = TicketDistributionStruct({
                playerAddress: _playerAddress,
                startIndex: _ticketIndex,
                endIndex: _ticketIndex + _numTickets - 1 // sub 1 to account for array indices starting from 0
            });
            // gas optimization - overwrite existing values instead of re-initializing; otherwise append
            if (_ticketDistributionLength > i) {
                ticketDistribution[i] = newDistribution;
            } else {
                ticketDistribution.push(newDistribution);
            }

            tickets[_playerAddress] = 0; // reset player's tickets to 0 after they've been counted
            _ticketIndex = _ticketIndex + _numTickets;
        }
    }

    /*
     * @title findWinningAddress
     * @dev function to find winning player address corresponding to winning ticket index
     * calls binary search
     * @param uint256 winningTicketIndex_: ticket index selected as winner.
     * Search for this within the ticket distribution to find corresponding Player
     */
    function findWinningAddress(uint256 winningTicketIndex_) public onlyOwner {
        // console.log("findWinningAddress");
        // trivial case, no search required
        uint _numActivePlayers = numActivePlayers;
        if (_numActivePlayers == 1) {
            winningTicket.winningAddress = ticketDistribution[0].playerAddress;
        } else {
            // do binary search on ticketDistribution array to find winner
            uint256 _winningPlayerIndex = _binarySearch(
                0,
                _numActivePlayers - 1,
                winningTicketIndex_
            );
            if (_winningPlayerIndex >= _numActivePlayers) {
                // sanity check
                revert Lottery__InvalidWinningIndex();
            }
            winningTicket.winningAddress = ticketDistribution[_winningPlayerIndex]
                .playerAddress;
        }
    }

    /*
     * @title _binarySearch
     * @dev function implementing binary search on ticket distribution var
     * recursive function
     * @param uint256 leftIndex_ initially 0
     * @param uint256 rightIndex_ initially max ind, ie array.length - 1
     * @param uint256 ticketIndexToFind_ to search for
     */
    function _binarySearch(
        uint256 leftIndex_,
        uint256 rightIndex_,
        uint256 ticketIndexToFind_
    ) private returns (uint256) {
        uint256 _searchIndex = (rightIndex_ - leftIndex_) / (2) + (leftIndex_);
        uint _loopCount = loopCount;
        // counter
        loopCount = _loopCount + 1;
        if (_loopCount + 1 > maxLoops) {
            // emergency stop in case infinite loop due to unforeseen bug
            return numActivePlayers;
        }

        if (
            ticketDistribution[_searchIndex].startIndex <= ticketIndexToFind_ &&
            ticketDistribution[_searchIndex].endIndex >= ticketIndexToFind_
        ) {
            return _searchIndex;
        } else if (
            ticketDistribution[_searchIndex].startIndex > ticketIndexToFind_
        ) {
            // go to left subarray
            rightIndex_ = _searchIndex - (leftIndex_);

            return _binarySearch(leftIndex_, rightIndex_, ticketIndexToFind_);
        } else if (
            ticketDistribution[_searchIndex].endIndex < ticketIndexToFind_
        ) {
            // go to right subarray
            leftIndex_ = _searchIndex + (leftIndex_) + 1;
            return _binarySearch(leftIndex_, rightIndex_, ticketIndexToFind_);
        }

        // if nothing found (bug), return an impossible player index
        // this index is outside expected bound, bc indexes run from 0 to numActivePlayers-1
        return numActivePlayers;
    }

    /*
     * @title _resetLottery
     * @dev function to reset lottery by setting state vars to defaults
     * don't delete if possible, as it requires lots of gas
     */
    function _resetLottery() private {
        // console.log("_resetLottery");

        numTotalTickets = 0;
        numActivePlayers = 0;
        lotteries[currentLotteryId].isActive = false;
        lotteries[currentLotteryId].isCompleted = true;
        winningTicket = WinningTicketStruct({
            currentLotteryId: 0,
            winningTicketIndex: 0,
            winningAddress: address(0)
        });

        currentLotteryId = currentLotteryId + (1); // increment id counter
    }

    /*
     * @title withdraw
     * @dev function to allow winner to withdraw prize
     * implement withdrawal pattern
     * @param uint256 lotteryId_ to minimize the search requirement
     */
    function withdraw(uint256 lotteryId_) external payable {
        // console.log("withdraw");
        uint256 _pendingCurrentUserWithdrawal = pendingWithdrawals[lotteryId_][
            msg.sender
        ];
        if (_pendingCurrentUserWithdrawal == 0) {
            revert Lottery__InvalidWithdrawalAmount();
        }
        pendingWithdrawals[lotteryId_][msg.sender] = 0; // zero out pendingWithdrawals before transfer, to prevent attacks
        (bool sent, ) = msg.sender.call{value: _pendingCurrentUserWithdrawal}(
            ""
        );
        if (sent == false) {
            revert Lottery__WithdrawalFailed();
        }
        emit LogWinnerFundsWithdrawn(msg.sender, _pendingCurrentUserWithdrawal);
    }

}
