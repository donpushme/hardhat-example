// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


/**
 * @title TeamAVault
 * @dev Vault contract for holding bets for Team A across all events
 */
contract TeamAVault is Ownable, ReentrancyGuard {
    // Reference to the main Klaus Bet contract
    address public klausBet;

    // Reference to the complementary vault (Team B)
    address public teamBVault;

    // BASE token reference
    IERC20 public baseToken;

    // Bet structure
    struct Bet {
        address bettor;
        uint256 amount;
        bool matched;
        uint256 timestamp;
    }

    // Track bets for each event
    mapping(uint256 => Bet[]) public bets;

    // Total amounts for each event
    mapping(uint256 => uint256) public totalAmounts;
    mapping(uint256 => uint256) public totalMatchedAmounts;
    mapping(uint256 => uint256) public matchedIndices; // Index tracking matched bets

    // Event odds
    mapping(uint256 => uint256) public eventOdds;

    // Track ongoing matching operations to prevent reentrancy
    mapping(uint256 => bool) private processing;

    // Events
    event EventInitialized(uint256 indexed eventId, uint256 odds);
    event BetPlaced(
        uint256 indexed eventId,
        address indexed bettor,
        uint256 amount,
        uint256 betIndex
    );
    event BetMatched(uint256 indexed eventId, uint256 betIndex, uint256 amount);
    event WinningsDistributed(
        uint256 indexed eventId,
        address indexed bettor,
        uint256 amount
    );
    event UnmatchedBetReturned(
        uint256 indexed eventId,
        address indexed bettor,
        uint256 amount
    );
    event AllBetsReturned(uint256 indexed eventId);

    /**
     * @dev Constructor sets the owner and vault configuration
     * @param _klausBet Address of the KlausBet main contract
     * @param _baseToken Address of the BASE token contract
     */
    constructor(address _klausBet, address _baseToken) Ownable(_klausBet) {
        require(_baseToken != address(0), "Invalid token address");
        klausBet = _klausBet;
        baseToken = IERC20(_baseToken);
    }

    /**
     * @dev Set the complementary vault address (Team B)
     * @param _teamBVault Address of the Team B vault
     */
    function setTeamBVault(address _teamBVault) external onlyOwner {
        require(_teamBVault != address(0), "Invalid vault address");
        teamBVault = _teamBVault;
    }

    /**
     * @dev Initialize tracking for a new event
     * @param _eventId ID of the event
     * @param _odds Odds for Team A
     */
    function initializeEvent(
        uint256 _eventId,
        uint256 _odds
    ) external onlyOwner {
        require(eventOdds[_eventId] == 0, "Event already initialized");
        eventOdds[_eventId] = _odds;
        emit EventInitialized(_eventId, _odds);
    }

    /**
     * @dev Place a bet on Team A for an event
     * @param _eventId ID of the event
     * @param _amount Amount of BASE tokens to bet
     */
    function placeBet(uint256 _eventId, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Bet amount must be greater than zero");
        require(
            KlausBet(klausBet).isEventOpen(_eventId),
            "Event is not open for betting"
        );
        require(
            eventOdds[_eventId] > 0,
            "Event not initialized for this vault"
        );

        // Transfer BASE tokens from bettor to this contract
        require(
            baseToken.transferFrom(msg.sender, address(this), _amount),
            "Token transfer failed"
        );

        // Record the bet
        bets[_eventId].push(
            Bet({
                bettor: msg.sender,
                amount: _amount,
                matched: false,
                timestamp: block.timestamp
            })
        );

        totalAmounts[_eventId] += _amount;

        emit BetPlaced(
            _eventId,
            msg.sender,
            _amount,
            bets[_eventId].length - 1
        );

        // Try to match bets with Team B vault
        _tryMatchBets(_eventId);
    }

    /**
     * @dev Try to match bets with the Team B vault
     * @param _eventId ID of the event
     */
    function _tryMatchBets(uint256 _eventId) internal {
        require(!processing[_eventId], "Already processing");
        processing[_eventId] = true;

        uint256 oddsA = eventOdds[_eventId];

        // Calculate how much from Team B is needed to match Team A bets
        // For Team A bets, required amount from Team B = (Team A amount * oddsA / 100)
        uint256 requiredAmount = (totalAmounts[_eventId] * oddsA) / 100;

        // Check Team B vault's matched amount for this event
        uint256 compMatchedAmount = TeamBVault(teamBVault)
            .getTotalMatchedAmount(_eventId);

        // If there's enough in Team B vault, match our bets
        if (compMatchedAmount >= requiredAmount) {
            uint256 newlyMatchedAmount = totalAmounts[_eventId] -
                totalMatchedAmounts[_eventId];

            // Mark bets as matched, following chronological order
            for (
                uint256 i = matchedIndices[_eventId];
                i < bets[_eventId].length;
                i++
            ) {
                Bet storage bet = bets[_eventId][i];
                if (!bet.matched) {
                    bet.matched = true;
                    emit BetMatched(_eventId, i, bet.amount);
                }
            }

            totalMatchedAmounts[_eventId] = totalAmounts[_eventId];
            matchedIndices[_eventId] = bets[_eventId].length;

            // Inform Team B vault to update its matching
            TeamBVault(teamBVault).updateMatching(_eventId, newlyMatchedAmount);
        }

        processing[_eventId] = false;
    }

    /**
     * @dev Team B vault calls this to update matching after it receives new bets
     * @param _eventId ID of the event
     * @param _newlyMatchedAmount Amount newly matched in Team B vault
     */
    function updateMatching(
        uint256 _eventId,
        uint256 _newlyMatchedAmount
    ) external {
        require(msg.sender == teamBVault, "Only Team B vault can call");
        if (!processing[_eventId]) {
            _tryMatchBets(_eventId);
        }
    }

    /**
     * @dev Distribute winnings when Team A wins
     * @param _eventId ID of the event
     * @param _treasury Address to send platform fees
     * @param _platformFeePercentage Platform fee percentage
     */
    function distributeWinnings(
        uint256 _eventId,
        address _treasury,
        uint256 _platformFeePercentage
    ) external nonReentrant {
        require(msg.sender == klausBet, "Only KlausBet can call");

        // Get losing bets from Team B vault
        uint256 totalWinnings = TeamBVault(teamBVault).getEventBalance(
            _eventId
        );
        require(totalWinnings > 0, "No winnings to distribute");

        // Calculate platform fee
        uint256 platformFee = (totalWinnings * _platformFeePercentage) / 100;
        uint256 distributedWinnings = totalWinnings - platformFee;

        // Transfer all tokens from Team B vault for this event
        TeamBVault(teamBVault).transferEventFunds(_eventId, address(this));

        // Send platform fee to treasury
        require(
            baseToken.transfer(_treasury, platformFee),
            "Treasury fee transfer failed"
        );

        // Return original bets and distribute winnings to matched bettors
        Bet[] storage eventBets = bets[_eventId];
        for (uint256 i = 0; i < matchedIndices[_eventId]; i++) {
            Bet storage bet = eventBets[i];
            if (bet.matched) {
                // Return original bet
                require(
                    baseToken.transfer(bet.bettor, bet.amount),
                    "Original bet return failed"
                );

                // Calculate and distribute winnings proportionally
                uint256 winningShare = (distributedWinnings * bet.amount) /
                    totalMatchedAmounts[_eventId];
                if (winningShare > 0) {
                    require(
                        baseToken.transfer(bet.bettor, winningShare),
                        "Winnings distribution failed"
                    );
                    emit WinningsDistributed(
                        _eventId,
                        bet.bettor,
                        winningShare
                    );
                }
            }
        }
    }

    /**
     * @dev Return unmatched bets when the event closes
     * @param _eventId ID of the event
     */
    function returnUnmatchedBets(uint256 _eventId) external nonReentrant {
        require(msg.sender == klausBet, "Only KlausBet can call");

        Bet[] storage eventBets = bets[_eventId];
        for (uint256 i = 0; i < eventBets.length; i++) {
            Bet storage bet = eventBets[i];
            if (!bet.matched) {
                require(
                    baseToken.transfer(bet.bettor, bet.amount),
                    "Unmatched bet return failed"
                );
                emit UnmatchedBetReturned(_eventId, bet.bettor, bet.amount);
            }
        }
    }

    /**
     * @dev Return all bets if event is cancelled
     * @param _eventId ID of the event
     */
    function returnAllBets(uint256 _eventId) external nonReentrant {
        require(msg.sender == klausBet, "Only KlausBet can call");

        Bet[] storage eventBets = bets[_eventId];
        for (uint256 i = 0; i < eventBets.length; i++) {
            Bet storage bet = eventBets[i];
            require(
                baseToken.transfer(bet.bettor, bet.amount),
                "Bet return failed"
            );
        }

        emit AllBetsReturned(_eventId);
    }

    /**
     * @dev Get total amount of matched bets for an event
     * @param _eventId ID of the event
     * @return Total matched amount
     */
    function getTotalMatchedAmount(
        uint256 _eventId
    ) external view returns (uint256) {
        return totalMatchedAmounts[_eventId];
    }

    /**
     * @dev Get total balance for an event
     * @param _eventId ID of the event
     * @return Event's total balance in this vault
     */
    function getEventBalance(uint256 _eventId) external view returns (uint256) {
        uint256 total = 0;
        Bet[] storage eventBets = bets[_eventId];
        for (uint256 i = 0; i < eventBets.length; i++) {
            if (eventBets[i].matched) {
                total += eventBets[i].amount;
            }
        }
        return total;
    }

    /**
     * @dev Transfer all matched funds for an event to another address
     * @param _eventId ID of the event
     * @param _to Address to send funds to
     * @return Amount transferred
     */
    function transferEventFunds(
        uint256 _eventId,
        address _to
    ) external nonReentrant returns (uint256) {
        require(
            msg.sender == teamBVault || msg.sender == klausBet,
            "Unauthorized"
        );

        uint256 total = 0;
        Bet[] storage eventBets = bets[_eventId];
        for (uint256 i = 0; i < eventBets.length; i++) {
            if (eventBets[i].matched) {
                total += eventBets[i].amount;
                // Mark as unmatched to prevent double counting/transfer
                eventBets[i].matched = false;
            }
        }

        if (total > 0) {
            require(baseToken.transfer(_to, total), "Transfer failed");
        }

        return total;
    }

    /**
     * @dev Get bettor's bet information for an event
     * @param _eventId ID of the event
     * @param _bettor Address of the bettor
     * @return totalBetAmount Total amount bet by the bettor
     * @return matchedAmount Amount that has been matched
     */
    function getBettorInfo(
        uint256 _eventId,
        address _bettor
    ) external view returns (uint256 totalBetAmount, uint256 matchedAmount) {
        Bet[] storage eventBets = bets[_eventId];
        for (uint256 i = 0; i < eventBets.length; i++) {
            if (eventBets[i].bettor == _bettor) {
                totalBetAmount += eventBets[i].amount;
                if (eventBets[i].matched) {
                    matchedAmount += eventBets[i].amount;
                }
            }
        }
        return (totalBetAmount, matchedAmount);
    }
}

