pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title KlausBet
 * @dev Main contract for the Klaus Bet platform on Base blockchain
 */
contract KlausBet is Ownable, ReentrancyGuard {
    // Platform fee percentage (5%)
    uint256 public constant PLATFORM_FEE = 5;

    // Event status enum
    enum EventStatus {
        Created,
        Open,
        Closed,
        Settled,
        Cancelled
    }

    // Bet event structure
    struct BetEvent {
        string name;
        string teamA;
        string teamB;
        uint256 oddsA; // Moneyline odds for team A (e.g., 200 = profit of $200 on a $100 bet)
        uint256 oddsB; // Moneyline odds for team B
        uint256 openTime;
        uint256 closeTime;
        uint256 settlementTime;
        EventStatus status;
        uint8 winner; // 0 = not decided, 1 = team A, 2 = team B
    }

    // Mapping of event ID to BetEvent
    mapping(uint256 => BetEvent) public betEvents;

    // Event counter for generating unique IDs
    uint256 public eventCounter;

    // List of all event IDs for enumeration
    uint256[] public allEventIds;

    // References to vault contracts
    address public teamAVault; // For team A bets across all events
    address public teamBVault; // For team B bets across all events

    // Treasury address for collecting platform fees
    address public treasury;

    // BASE token reference
    IERC20 public baseToken;

    // Events
    event EventCreated(
        uint256 indexed eventId,
        string name,
        string teamA,
        string teamB
    );
    event EventOpened(uint256 indexed eventId);
    event EventClosed(uint256 indexed eventId);
    event EventSettled(uint256 indexed eventId, uint8 winner);
    event EventCancelled(uint256 indexed eventId);

    /**
     * @dev Constructor sets the owner, treasury address, and BASE token address
     * @param _treasury Address that will receive platform fees
     * @param _baseToken Address of the BASE token contract
     */
    constructor(address _treasury, address _baseToken) Ownable(msg.sender) {
        require(_treasury != address(0), "Invalid treasury address");
        require(_baseToken != address(0), "Invalid token address");
        treasury = _treasury;
        baseToken = IERC20(_baseToken);
        eventCounter = 1;
    }

    /**
     * @dev Set the vault contracts
     * @param _teamAVault Address of Team A vault
     * @param _teamBVault Address of Team B vault
     */
    function setVaults(
        address _teamAVault,
        address _teamBVault
    ) external onlyOwner {
        require(
            _teamAVault != address(0) && _teamBVault != address(0),
            "Invalid vault addresses"
        );
        teamAVault = _teamAVault;
        teamBVault = _teamBVault;
    }

    /**
     * @dev Update the treasury address
     * @param _newTreasury New treasury address
     */
    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid treasury address");
        treasury = _newTreasury;
    }

    /**
     * @dev Create a new betting event
     * @param _name Name of the event
     * @param _teamA Name of team A
     * @param _teamB Name of team B
     * @param _oddsA Odds for team A
     * @param _oddsB Odds for team B
     * @param _openTime Time when betting opens
     * @param _closeTime Time when betting closes
     * @param _settlementTime Estimated time for settlement
     */
    function createEvent(
        string memory _name,
        string memory _teamA,
        string memory _teamB,
        uint256 _oddsA,
        uint256 _oddsB,
        uint256 _openTime,
        uint256 _closeTime,
        uint256 _settlementTime
    ) external onlyOwner {
        require(_openTime < _closeTime, "Open time must be before close time");
        require(
            _closeTime < _settlementTime,
            "Close time must be before settlement time"
        );
        require(_oddsA > 0 && _oddsB > 0, "Odds must be greater than zero");
        require(
            teamAVault != address(0) && teamBVault != address(0),
            "Vaults not set"
        );

        // Create and store the event
        betEvents[eventCounter] = BetEvent({
            name: _name,
            teamA: _teamA,
            teamB: _teamB,
            oddsA: _oddsA,
            oddsB: _oddsB,
            openTime: _openTime,
            closeTime: _closeTime,
            settlementTime: _settlementTime,
            status: EventStatus.Created,
            winner: 0
        });

        // Add to list of all events
        allEventIds.push(eventCounter);

        // Initialize vaults for this event
        TeamAVault(teamAVault).initializeEvent(eventCounter, _oddsA);
        TeamBVault(teamBVault).initializeEvent(eventCounter, _oddsB);

        emit EventCreated(eventCounter, _name, _teamA, _teamB);
        eventCounter++;
    }

    /**
     * @dev Open betting for an event
     * @param _eventId ID of the event to open
     */
    function openEvent(uint256 _eventId) external onlyOwner {
        BetEvent storage betEvent = betEvents[_eventId];
        require(betEvent.openTime > 0, "Event does not exist");
        require(
            betEvent.status == EventStatus.Created,
            "Event is not in created state"
        );
        require(block.timestamp >= betEvent.openTime, "Not yet open time");

        betEvent.status = EventStatus.Open;
        emit EventOpened(_eventId);
    }

    /**
     * @dev Close betting for an event
     * @param _eventId ID of the event to close
     */
    function closeEvent(uint256 _eventId) external onlyOwner {
        BetEvent storage betEvent = betEvents[_eventId];
        require(betEvent.openTime > 0, "Event does not exist");
        require(betEvent.status == EventStatus.Open, "Event is not open");
        require(block.timestamp >= betEvent.closeTime, "Not yet close time");

        betEvent.status = EventStatus.Closed;

        // Return unmatched bets to senders
        TeamAVault(teamAVault).returnUnmatchedBets(_eventId);
        TeamBVault(teamBVault).returnUnmatchedBets(_eventId);

        emit EventClosed(_eventId);
    }

    /**
     * @dev Settle an event by declaring the winner
     * @param _eventId ID of the event to settle
     * @param _winner Winner (1 for team A, 2 for team B)
     */
    function settleEvent(uint256 _eventId, uint8 _winner) external onlyOwner {
        BetEvent storage betEvent = betEvents[_eventId];
        require(betEvent.openTime > 0, "Event does not exist");
        require(betEvent.status == EventStatus.Closed, "Event is not closed");
        require(_winner == 1 || _winner == 2, "Winner must be 1 or 2");

        betEvent.status = EventStatus.Settled;
        betEvent.winner = _winner;

        // Distribute winnings
        if (_winner == 1) {
            // Team A wins
            TeamAVault(teamAVault).distributeWinnings(
                _eventId,
                treasury,
                PLATFORM_FEE
            );
        } else {
            // Team B wins
            TeamBVault(teamBVault).distributeWinnings(
                _eventId,
                treasury,
                PLATFORM_FEE
            );
        }

        emit EventSettled(_eventId, _winner);
    }

    /**
     * @dev Cancel an event and return all bets
     * @param _eventId ID of the event to cancel
     */
    function cancelEvent(uint256 _eventId) external onlyOwner {
        BetEvent storage betEvent = betEvents[_eventId];
        require(betEvent.openTime > 0, "Event does not exist");
        require(
            betEvent.status == EventStatus.Created ||
                betEvent.status == EventStatus.Open ||
                betEvent.status == EventStatus.Closed,
            "Event cannot be cancelled"
        );

        betEvent.status = EventStatus.Cancelled;

        // Return all bets to senders
        TeamAVault(teamAVault).returnAllBets(_eventId);
        TeamBVault(teamBVault).returnAllBets(_eventId);

        emit EventCancelled(_eventId);
    }

    /**
     * @dev Get event details
     * @param _eventId ID of the event
     * @return Full event details
     */
    function getEvent(
        uint256 _eventId
    ) external view returns (BetEvent memory) {
        BetEvent storage betEvent = betEvents[_eventId];
        require(betEvent.openTime > 0, "Event does not exist");
        return betEvent;
    }

    /**
     * @dev Check whether an event is open for betting
     * @param _eventId ID of the event
     * @return bool indicating if event is open
     */
    function isEventOpen(uint256 _eventId) external view returns (bool) {
        BetEvent storage betEvent = betEvents[_eventId];
        return betEvent.status == EventStatus.Open;
    }

    /**
     * @dev Get all active betting events (created or open)
     * @return Array of event IDs that are active
     */
    function getActiveEvents() external view returns (uint256[] memory) {
        uint256 activeCount = 0;

        // First, count active events
        for (uint256 i = 0; i < allEventIds.length; i++) {
            uint256 eventId = allEventIds[i];
            if (
                betEvents[eventId].status == EventStatus.Created ||
                betEvents[eventId].status == EventStatus.Open
            ) {
                activeCount++;
            }
        }

        // Create array of active event IDs
        uint256[] memory activeEvents = new uint256[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < allEventIds.length; i++) {
            uint256 eventId = allEventIds[i];
            if (
                betEvents[eventId].status == EventStatus.Created ||
                betEvents[eventId].status == EventStatus.Open
            ) {
                activeEvents[index] = eventId;
                index++;
            }
        }

        return activeEvents;
    }

    /**
     * @dev Get all events (paginated)
     * @param _offset Starting index
     * @param _limit Maximum number of events to return
     * @return Array of event IDs
     */
    function getEvents(
        uint256 _offset,
        uint256 _limit
    ) external view returns (uint256[] memory) {
        uint256 end = _offset + _limit;
        if (end > allEventIds.length) {
            end = allEventIds.length;
        }

        uint256 resultSize = end - _offset;
        uint256[] memory result = new uint256[](resultSize);

        for (uint256 i = 0; i < resultSize; i++) {
            result[i] = allEventIds[_offset + i];
        }

        return result;
    }

    /**
     * @dev Get total number of events
     * @return Total count of events
     */
    function getTotalEventCount() external view returns (uint256) {
        return allEventIds.length;
    }
}