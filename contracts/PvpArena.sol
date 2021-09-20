pragma solidity ^0.6.0;
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "hardhat/console.sol";
import "./util.sol";
import "./interfaces/IRandoms.sol";
import "./cryptoblades.sol";
import "./characters.sol";
import "./weapons.sol";
import "./shields.sol";
import "./raid1.sol";

contract PvpArena is Initializable, AccessControlUpgradeable {
    using SafeMath for uint256;
    using ABDKMath64x64 for int128;
    using SafeMath for uint8;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct Fighter {
        uint256 characterID;
        uint256 weaponID;
        uint256 shieldID;
        /// @dev amount of skill wagered for this character
        uint256 wager;
        bool useShield;
    }
    struct Duel {
        uint256 attackerID;
        uint256 defenderID;
        uint256 createdAt;
        bool isPending;
    }

    struct BountyDistribution {
        uint256 winnerReward;
        uint256 loserPayment;
        uint256 rankingPoolTax;
    }

    bytes32 public constant GAME_ADMIN = keccak256("GAME_ADMIN");

    CryptoBlades public game;
    Characters public characters;
    Weapons public weapons;
    Shields public shields;
    IERC20 public skillToken;
    Raid1 public raids;
    IRandoms public randoms;

    /// @dev how much of a duel's bounty is sent to the rankings pool
    uint8 private _rankingsPoolTaxPercent;
    /// @dev how many times the cost of battling must be wagered to enter the arena
    uint8 public wageringFactor;
    /// @dev the base amount wagered per duel in dollars
    int128 private _baseWagerUSD;
    /// @dev how much extra USD is wagered per level tier
    int128 private _tierWagerUSD;
    /// @dev amount of time a character is unattackable
    uint256 public unattackableSeconds;
    /// @dev amount of time an attacker has to make a decision
    uint256 public decisionSeconds;
    /// @dev amount of points earned by winning a fight
    uint8 public winningPoints;
    /// @dev amount of points lost by losing fight
    uint8 public losingPoints;

    /// @dev Fighter by characterID
    mapping(uint256 => Fighter) public fighterByCharacter;
    /// @dev Active duel by characterID currently attacking
    mapping(uint256 => Duel) public duelByAttacker;
    /// @dev last time a character was involved in activity that makes it untattackable
    mapping(uint256 => uint256) private _lastActivityByCharacter;
    /// @dev IDs of characters available by tier (1-10, 11-20, etc...)
    mapping(uint8 => EnumerableSet.UintSet) private _fightersByTier;
    /// @dev IDs of characters in the arena per player
    mapping(address => EnumerableSet.UintSet) private _fightersByPlayer;
    /// @dev characters currently in the arena
    mapping(uint256 => bool) private _charactersInArena;
    /// @dev weapons currently in the arena
    mapping(uint256 => bool) private _weaponsInArena;
    /// @dev shields currently in the arena
    mapping(uint256 => bool) private _shieldsInArena;
    /// @dev earnings earned by player
    mapping(address => uint256) private _rewardsByPlayer;
    /// @dev accumulated rewards per tier
    mapping(uint8 => uint256) private _rankingsPoolByTier;
    /// @dev ranking by tier
    mapping(uint8 => uint256[3]) private _rankingByTier;
    /// @dev rankPoints by character
    mapping(uint256 => uint256) private _characterRankingPoints;

    event NewDuel(
        uint256 indexed attacker,
        uint256 indexed defender,
        uint256 timestamp
    );
    event DuelFinished(
        uint256 indexed attacker,
        uint256 indexed defender,
        uint256 timestamp,
        uint256 attackerRoll,
        uint256 defenderRoll,
        bool attackerWon
    );

    modifier characterInArena(uint256 characterID) {
        require(
            isCharacterInArena(characterID),
            "Character is not in the arena"
        );
        _;
    }
    modifier isOwnedCharacter(uint256 characterID) {
        require(
            characters.ownerOf(characterID) == msg.sender,
            "Character is not owned by sender"
        );
        _;
    }

    modifier restricted() {
        _restricted();
        _;
    }

    function _restricted() internal view {
        require(hasRole(GAME_ADMIN, msg.sender), "Not game admin");
    }

    modifier enteringArenaChecks(
        uint256 characterID,
        uint256 weaponID,
        uint256 shieldID,
        bool useShield
    ) {
        require(!isCharacterInArena(characterID), "Character already in arena");
        require(!_weaponsInArena[weaponID], "Weapon already in arena");
        require(
            characters.ownerOf(characterID) == msg.sender,
            "Not character owner"
        );
        require(weapons.ownerOf(weaponID) == msg.sender, "Not weapon owner");
        require(!raids.isCharacterRaiding(characterID), "Character is in raid");
        require(!raids.isWeaponRaiding(weaponID), "Weapon is in raid");

        if (useShield) {
            require(
                shields.ownerOf(shieldID) == msg.sender,
                "Not shield owner"
            );
            require(!_shieldsInArena[shieldID], "Shield already in arena");
        }

        _;
    }

    function initialize(
        address gameContract,
        address shieldsContract,
        address raidContract,
        address randomsContract
    ) public initializer {
        __AccessControl_init_unchained();
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

        game = CryptoBlades(gameContract);
        characters = Characters(game.characters());
        weapons = Weapons(game.weapons());
        shields = Shields(shieldsContract);
        skillToken = IERC20(game.skillToken());
        raids = Raid1(raidContract);
        randoms = IRandoms(randomsContract);

        // TODO: Tweak these values, they are placeholders
        wageringFactor = 3;
        _baseWagerUSD = ABDKMath64x64.divu(500, 100); // $5
        _tierWagerUSD = ABDKMath64x64.divu(50, 100); // $0.5
        _rankingsPoolTaxPercent = 15;
        unattackableSeconds = 2 minutes;
        decisionSeconds = 3 minutes;
        winningPoints = 5;
        losingPoints = 3;
    }

    /// @notice enter the arena with a character, a weapon and optionally a shield
    function enterArena(
        uint256 characterID,
        uint256 weaponID,
        uint256 shieldID,
        bool useShield
    ) external enteringArenaChecks(characterID, weaponID, shieldID, useShield) {
        uint256 wager = getEntryWager(characterID);
        uint8 tier = getArenaTier(characterID);

        _charactersInArena[characterID] = true;
        _weaponsInArena[weaponID] = true;

        if (useShield) _shieldsInArena[shieldID] = true;

        _fightersByTier[tier].add(characterID);
        _fightersByPlayer[msg.sender].add(characterID);
        fighterByCharacter[characterID] = Fighter(
            characterID,
            weaponID,
            shieldID,
            wager,
            useShield
        );
        // update tier ranking
        updateTierRanks(characterID);
        // character starts unattackable
        _updateLastActivityTimestamp(characterID);

        skillToken.transferFrom(msg.sender, address(this), wager);
    }

    /// @dev attempts to find an opponent for a character. If a battle is still pending, it charges a penalty and re-rolls the opponent
    function requestOpponent(uint256 characterID)
        external
        characterInArena(characterID)
        isOwnedCharacter(characterID)
    {
        require(!hasPendingDuel(characterID), "Opponent already requested");
        _assignOpponent(characterID);
    }

    /// @dev requests a new opponent for a fee
    function reRollOpponent(uint256 characterID)
        external
        characterInArena(characterID)
        isOwnedCharacter(characterID)
    {
        require(hasPendingDuel(characterID), "Character is not dueling");

        _assignOpponent(characterID);

        skillToken.transferFrom(
            msg.sender,
            address(this),
            getDuelCost(characterID).div(4)
        );
    }

    /// @dev performs a given character's duel against its opponent
    function performDuel(uint256 attackerID)
        external
        isOwnedCharacter(attackerID)
    {
        require(hasPendingDuel(attackerID), "Character not in a duel");
        require(
            isAttackerWithinDecisionTime(attackerID),
            "Decision time expired"
        );

        uint256 defenderID = getOpponent(attackerID);
        uint8 defenderTrait = characters.getTrait(defenderID);
        uint8 attackerTrait = characters.getTrait(attackerID);

        uint24 attackerRoll = _getCharacterPowerRoll(attackerID, defenderTrait);
        uint24 defenderRoll = _getCharacterPowerRoll(defenderID, attackerTrait);

        uint256 winnerID = attackerRoll >= defenderRoll
            ? attackerID
            : defenderID;
        uint256 loserID = attackerRoll >= defenderRoll
            ? defenderID
            : attackerID;

        address winner = characters.ownerOf(winnerID);

        emit DuelFinished(
            attackerID,
            defenderID,
            block.timestamp,
            attackerRoll,
            defenderRoll,
            attackerRoll >= defenderRoll
        );

        BountyDistribution
            memory bountyDistribution = _getDuelBountyDistribution(attackerID);

        _rewardsByPlayer[winner] = _rewardsByPlayer[winner].add(
            bountyDistribution.winnerReward
        );
        fighterByCharacter[loserID].wager = fighterByCharacter[loserID]
            .wager
            .sub(bountyDistribution.loserPayment);

        if (fighterByCharacter[loserID].wager == 0) {
            _removeCharacterFromArena(loserID);
        }

        // add ranking points to the winner
        _characterRankingPoints[winnerID] = _characterRankingPoints[winnerID]
            .add(winningPoints);
        // subtract ranking points to the loser
        if (_characterRankingPoints[loserID] <= 3) {
            _characterRankingPoints[loserID] = 0;
        } else {
            _characterRankingPoints[loserID] = _characterRankingPoints[loserID]
                .sub(losingPoints);
        }

        // update the tier's ranking after a fight
        updateTierRanks(attackerID);
        // add to the rankings pool
        _rankingsPoolByTier[getArenaTier(attackerID)] = _rankingsPoolByTier[
            getArenaTier(attackerID)
        ].add(bountyDistribution.rankingPoolTax);

        _updateLastActivityTimestamp(attackerID);
        _updateLastActivityTimestamp(defenderID);

        duelByAttacker[attackerID].isPending = false;
    }

    /// @dev withdraws a character and its items from the arena.
    /// if the character is in a battle, a penalty is charged
    function withdrawFromArena(uint256 characterID)
        external
        isOwnedCharacter(characterID)
    {
        Fighter storage fighter = fighterByCharacter[characterID];
        uint256 wager = fighter.wager;
        _removeCharacterFromArena(characterID);

        if (hasPendingDuel(characterID)) {
            skillToken.safeTransfer(msg.sender, wager.sub(wager.div(4)));
        } else {
            skillToken.safeTransfer(msg.sender, wager);
        }
    }

    /// @dev returns the SKILL amounts distributed to the winner and the ranking pool
    function _getDuelBountyDistribution(uint256 attackerID)
        private
        view
        returns (BountyDistribution memory bountyDistribution)
    {
        uint256 duelCost = getDuelCost(attackerID);
        uint256 bounty = duelCost.mul(2);
        uint256 poolTax = _rankingsPoolTaxPercent.mul(bounty).div(100);

        uint256 reward = bounty.sub(poolTax).sub(duelCost);

        return BountyDistribution(reward, duelCost, poolTax);
    }

    /// @dev gets the player's unclaimed rewards
    function getMyRewards() public view returns (uint256) {
        return _rewardsByPlayer[msg.sender];
    }

    function getRankingRewardsPool(uint8 tier) public view returns (uint256) {
        return _rankingsPoolByTier[tier];
    }

    /// @dev gets the amount of SKILL that is risked per duel
    function getDuelCost(uint256 characterID) public view returns (uint256) {
        int128 tierExtra = ABDKMath64x64
            .divu(getArenaTier(characterID).mul(100), 100)
            .mul(_tierWagerUSD);

        return game.usdToSkill(_baseWagerUSD.add(tierExtra));
    }

    /// @notice gets the amount of SKILL required to enter the arena
    /// @param characterID the id of the character entering the arena
    function getEntryWager(uint256 characterID) public view returns (uint256) {
        return getDuelCost(characterID).mul(wageringFactor);
    }

    /// @dev gets the arena tier of a character (tiers are 1-10, 11-20, etc...)
    function getArenaTier(uint256 characterID) public view returns (uint8) {
        uint256 level = characters.getLevel(characterID);
        return uint8(level.div(10));
    }

    /// @dev gets IDs of the sender's characters currently in the arena
    function getMyParticipatingCharacters()
        public
        view
        returns (uint256[] memory)
    {
        uint256 length = _fightersByPlayer[msg.sender].length();
        uint256[] memory values = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            values[i] = _fightersByPlayer[msg.sender].at(i);
        }

        return values;
    }

    /// @dev returns the IDs of the sender's weapons currently in the arena
    function getMyParticipatingWeapons()
        external
        view
        returns (uint256[] memory)
    {
        Fighter[] memory fighters = _getMyFighters();
        uint256[] memory weaponIDs = new uint256[](fighters.length);

        for (uint256 i = 0; i < fighters.length; i++) {
            weaponIDs[i] = fighters[i].weaponID;
        }

        return weaponIDs;
    }

    /// @dev returns the IDs of the sender's shields currently in the arena
    function getMyParticipatingShields()
        external
        view
        returns (uint256[] memory)
    {
        Fighter[] memory fighters = _getMyFighters();
        uint256 shieldsCount = 0;

        for (uint256 i = 0; i < fighters.length; i++) {
            if (fighters[i].useShield) shieldsCount++;
        }

        uint256[] memory shieldIDs = new uint256[](shieldsCount);
        uint256 shieldIDsIndex = 0;

        for (uint256 i = 0; i < fighters.length; i++) {
            if (fighters[i].useShield) {
                shieldIDs[shieldIDsIndex] = fighters[i].shieldID;
                shieldIDsIndex++;
            }
        }

        return shieldIDs;
    }

    ///@dev update the respective character's tier rank
    function updateTierRanks(uint256 characterID) internal {
        uint8 tier = getArenaTier(characterID);

        uint256 fighterPoints = _characterRankingPoints[characterID];
        uint256 firstRankingPlayer = _rankingByTier[tier][0];
        uint256 firstRankingPlayerPoints = _characterRankingPoints[
            firstRankingPlayer
        ];

        uint256 secondRankingPlayer = _rankingByTier[tier][1];
        uint256 secondRankingPlayerPoints = _characterRankingPoints[
            secondRankingPlayer
        ];

        uint256 thirdRankingPlayer = _rankingByTier[tier][2];
        uint256 thirdRankingPlayerPoints = _characterRankingPoints[
            thirdRankingPlayer
        ];

        if (fighterPoints >= thirdRankingPlayerPoints) {
            _rankingByTier[tier][2] = characterID;
            thirdRankingPlayer = characterID;
            thirdRankingPlayerPoints = _characterRankingPoints[characterID];
        }
        if (thirdRankingPlayerPoints >= secondRankingPlayerPoints) {
            _rankingByTier[tier][1] = thirdRankingPlayer;
            _rankingByTier[tier][2] = secondRankingPlayer;
            thirdRankingPlayer = _rankingByTier[tier][2];
            thirdRankingPlayerPoints = _characterRankingPoints[
                _rankingByTier[tier][2]
            ];
            secondRankingPlayer = _rankingByTier[tier][1];
            secondRankingPlayerPoints = _characterRankingPoints[
                _rankingByTier[tier][1]
            ];
        }
        if (secondRankingPlayerPoints >= firstRankingPlayerPoints) {
            _rankingByTier[tier][0] = secondRankingPlayer;
            _rankingByTier[tier][1] = firstRankingPlayer;
            secondRankingPlayer = _rankingByTier[tier][1];
            secondRankingPlayerPoints = _characterRankingPoints[
                _rankingByTier[tier][1]
            ];
            firstRankingPlayer = _rankingByTier[tier][0];
            firstRankingPlayerPoints = _characterRankingPoints[
                _rankingByTier[tier][0]
            ];
        }
    }

    /// @dev get the top players of a tier
    function getTopTierPlayers(uint256 characterID)
        public
        view
        returns (uint256[3] memory)
    {
        uint8 tier = getArenaTier(characterID);
        return _rankingByTier[tier];
    }

    /// @dev get the player's ranking points
    function getCharacterRankingPoints(uint256 characterID)
        public
        view
        returns (uint256)
    {
        return _characterRankingPoints[characterID];
    }

    /// @dev checks if a character is in the arena
    function isCharacterInArena(uint256 characterID)
        public
        view
        returns (bool)
    {
        return _charactersInArena[characterID];
    }

    /// @dev checks if a weapon is in the arena
    function isWeaponInArena(uint256 weaponID) public view returns (bool) {
        return _weaponsInArena[weaponID];
    }

    /// @dev checks if a shield is in the arena
    function isShieldInArena(uint256 shieldID) public view returns (bool) {
        return _shieldsInArena[shieldID];
    }

    /// @dev get an attacker's opponent
    function getOpponent(uint256 characterID) public view returns (uint256) {
        require(hasPendingDuel(characterID), "Character has no pending duel");
        return duelByAttacker[characterID].defenderID;
    }

    /// @dev get amount wagered for a given character
    function getCharacterWager(uint256 characterID)
        public
        view
        returns (uint256)
    {
        return fighterByCharacter[characterID].wager;
    }

    /// @dev wether or not the character is still in time to start a duel
    function isAttackerWithinDecisionTime(uint256 characterID)
        public
        view
        returns (bool)
    {
        return
            duelByAttacker[characterID].createdAt.add(decisionSeconds) >
            block.timestamp;
    }

    /// @dev wether or not the character is the attacker in a duel
    // and has not performed an action
    function hasPendingDuel(uint256 characterID) public view returns (bool) {
        return duelByAttacker[characterID].isPending;
    }

    /// @dev wether or not a character can appear as someone's opponent
    function isCharacterAttackable(uint256 characterID)
        public
        view
        returns (bool)
    {
        uint256 lastActivity = _lastActivityByCharacter[characterID];

        return lastActivity.add(unattackableSeconds) <= block.timestamp;
    }

    /// @dev updates the last activity timestamp of a character
    function _updateLastActivityTimestamp(uint256 characterID) private {
        _lastActivityByCharacter[characterID] = block.timestamp;
    }

    /// @dev function where admins can seta character's ranking points
    function setRankingPoints(uint256 characterID, uint8 newRankingPoints)
        public
    {
        _characterRankingPoints[characterID] = newRankingPoints;
    }

    function _getCharacterPowerRoll(uint256 characterID, uint8 opponentTrait)
        private
        view
        returns (uint24)
    {
        // TODO:
        // - [ ] consider shield
        uint8 trait = characters.getTrait(characterID);
        uint24 basePower = characters.getPower(characterID);
        uint256 weaponID = fighterByCharacter[characterID].weaponID;
        uint256 seed = randoms.getRandomSeed(msg.sender);

        (
            ,
            int128 weaponMultFight,
            uint24 weaponBonusPower,
            uint8 weaponTrait
        ) = weapons.getFightData(weaponID, trait);

        int128 playerTraitBonus = getPVPTraitBonusAgainst(
            trait,
            weaponTrait,
            opponentTrait
        );

        uint256 playerFightPower = game.getPlayerPower(
            basePower,
            weaponMultFight,
            weaponBonusPower
        );

        uint256 playerPower = RandomUtil.plusMinus10PercentSeeded(
            playerFightPower,
            seed
        );

        return uint24(playerTraitBonus.mulu(playerPower));
    }

    /// @dev returns the trait bonuses against another character
    function getPVPTraitBonusAgainst(
        uint8 characterTrait,
        uint8 weaponTrait,
        uint8 opponentTrait
    ) public view returns (int128) {
        int128 traitBonus = ABDKMath64x64.fromUInt(1);
        int128 fightTraitBonus = game.fightTraitBonus();
        int128 charTraitFactor = ABDKMath64x64.divu(50, 100);

        if (characterTrait == weaponTrait) {
            traitBonus = traitBonus.add(fightTraitBonus);
        }

        // We apply 50% of char trait bonuses because they are applied twice (once per fighter)
        if (game.isTraitEffectiveAgainst(characterTrait, opponentTrait)) {
            traitBonus = traitBonus.add(fightTraitBonus.mul(charTraitFactor));
        } else if (
            game.isTraitEffectiveAgainst(opponentTrait, characterTrait)
        ) {
            traitBonus = traitBonus.sub(fightTraitBonus.mul(charTraitFactor));
        }

        return traitBonus;
    }

    /// @dev removes a character from the arena's state
    function _removeCharacterFromArena(uint256 characterID) private {
        require(isCharacterInArena(characterID), "Character not in arena");
        Fighter storage fighter = fighterByCharacter[characterID];

        uint256 weaponID = fighter.weaponID;
        uint256 shieldID = fighter.shieldID;

        delete fighterByCharacter[characterID];

        _fightersByPlayer[msg.sender].remove(characterID);

        uint8 tier = getArenaTier(characterID);

        _fightersByTier[tier].remove(characterID);

        _charactersInArena[characterID] = false;
        _weaponsInArena[weaponID] = false;
        _shieldsInArena[shieldID] = false;
    }

    /// @dev attempts to find an opponent for a character.
    function _assignOpponent(uint256 characterID) private {
        uint8 tier = getArenaTier(characterID);

        EnumerableSet.UintSet storage fightersInTier = _fightersByTier[tier];

        require(
            fightersInTier.length() != 0,
            "No opponents available for this character's level"
        );

        uint256 seed = randoms.getRandomSeed(msg.sender);
        uint256 randomIndex = RandomUtil.randomSeededMinMax(
            0,
            fightersInTier.length() - 1,
            seed
        );

        uint256 opponentID;
        bool foundOpponent = false;
        uint256 fighterCount = fightersInTier.length();

        // run through fighters from a random starting point until we find one or none are available
        for (uint256 i = 0; i < fighterCount; i++) {
            uint256 index = (randomIndex + i) % fighterCount;
            uint256 candidateID = fightersInTier.at(index);

            if (candidateID == characterID) continue;
            if (!isCharacterAttackable(candidateID)) continue;
            if (
                characters.ownerOf(candidateID) ==
                characters.ownerOf(characterID)
            ) continue;

            foundOpponent = true;
            opponentID = candidateID;
            break;
        }

        require(foundOpponent, "No opponent found");

        duelByAttacker[characterID] = Duel(
            characterID,
            opponentID,
            block.timestamp,
            true
        );

        // mark both characters as unattackable
        _lastActivityByCharacter[characterID] = block.timestamp;
        _lastActivityByCharacter[opponentID] = block.timestamp;

        emit NewDuel(characterID, opponentID, block.timestamp);
    }

    /// @dev returns the senders fighters in the arena
    function _getMyFighters() internal view returns (Fighter[] memory) {
        uint256[] memory characterIDs = getMyParticipatingCharacters();
        Fighter[] memory fighters = new Fighter[](characterIDs.length);

        for (uint256 i = 0; i < characterIDs.length; i++) {
            fighters[i] = fighterByCharacter[characterIDs[i]];
        }

        return fighters;
    }
}
