/**
 * The ids a spell's data is made of, as the 1.12 client numbers them: its effects, the aura types its
 * effects apply, its implicit targets and its damage class. A leaf module (it imports nothing), so that the
 * spell data (`spells.d`) and the code that carries spells out can both use the types.
 *
 * The data comes from the client's `Spell.dbc` and the database, so a field of one of these types can hold
 * a value no member names (an id this list lacks, or a broken row): a `final switch` over one must be
 * preceded by a check that the value is a member.
 */
module dmangos.world.spellids;

/// No effect of a spell: what a function looking for one of a spell's three effects returns when none is it.
enum size_t noEffect = size_t.max;

/**
 * Every spell effect of 1.12 (`Spell.dbc`'s `Effect` columns), numbered as the client numbers them. Members
 * with a comment naming the reference's constant were added from its list; whether the server handles each
 * is decided where effects are carried out.
 */
enum SpellEffect : uint
{
    none = 0,
    instantKill = 1,
    schoolDamage = 2, // SPELL_EFFECT_SCHOOL_DAMAGE
    dummy = 3, // SPELL_EFFECT_DUMMY
    portalTeleport = 4, // SPELL_EFFECT_PORTAL_TELEPORT
    teleportUnits = 5, // SPELL_EFFECT_TELEPORT_UNITS
    applyAura = 6,
    environmentalDamage = 7, // SPELL_EFFECT_ENVIRONMENTAL_DAMAGE
    powerDrain = 8, // SPELL_EFFECT_POWER_DRAIN
    healthLeech = 9, // SPELL_EFFECT_HEALTH_LEECH
    heal = 10, // SPELL_EFFECT_HEAL
    bind = 11, // SPELL_EFFECT_BIND
    portal = 12, // SPELL_EFFECT_PORTAL
    ritualBase = 13, // SPELL_EFFECT_RITUAL_BASE
    ritualSpecialize = 14, // SPELL_EFFECT_RITUAL_SPECIALIZE
    ritualActivatePortal = 15, // SPELL_EFFECT_RITUAL_ACTIVATE_PORTAL
    questComplete = 16, // SPELL_EFFECT_QUEST_COMPLETE
    weaponDamageNoschool = 17, // SPELL_EFFECT_WEAPON_DAMAGE_NOSCHOOL
    resurrect = 18, // SPELL_EFFECT_RESURRECT
    addExtraAttacks = 19, // SPELL_EFFECT_ADD_EXTRA_ATTACKS
    dodge = 20, // SPELL_EFFECT_DODGE
    evade = 21, // SPELL_EFFECT_EVADE
    parry = 22,
    block = 23,
    createItem = 24,
    weapon = 25, // SPELL_EFFECT_WEAPON
    defense = 26, // SPELL_EFFECT_DEFENSE
    persistentAreaAura = 27, // SPELL_EFFECT_PERSISTENT_AREA_AURA
    summon = 28, // SPELL_EFFECT_SUMMON
    leap = 29, // SPELL_EFFECT_LEAP
    energize = 30, // SPELL_EFFECT_ENERGIZE
    weaponPercentDamage = 31, // SPELL_EFFECT_WEAPON_PERCENT_DAMAGE
    triggerMissile = 32, // SPELL_EFFECT_TRIGGER_MISSILE
    openLock = 33, // SPELL_EFFECT_OPEN_LOCK
    summonChangeItem = 34, // SPELL_EFFECT_SUMMON_CHANGE_ITEM
    applyAreaAuraParty = 35, // SPELL_EFFECT_APPLY_AREA_AURA_PARTY
    learnSpell = 36,
    spellDefense = 37, // SPELL_EFFECT_SPELL_DEFENSE
    dispel = 38, // SPELL_EFFECT_DISPEL
    language = 39, // SPELL_EFFECT_LANGUAGE
    dualWield = 40,
    summonWild = 41, // SPELL_EFFECT_SUMMON_WILD
    summonGuardian = 42, // SPELL_EFFECT_SUMMON_GUARDIAN
    teleportUnitsFaceCaster = 43, // SPELL_EFFECT_TELEPORT_UNITS_FACE_CASTER
    skillStep = 44,
    addHonor = 45, // SPELL_EFFECT_ADD_HONOR
    spawn = 46, // SPELL_EFFECT_SPAWN
    tradeSkill = 47, // SPELL_EFFECT_TRADE_SKILL
    stealth = 48, // SPELL_EFFECT_STEALTH
    detect = 49, // SPELL_EFFECT_DETECT
    transDoor = 50, // SPELL_EFFECT_TRANS_DOOR
    forceCriticalHit = 51, // SPELL_EFFECT_FORCE_CRITICAL_HIT
    guaranteeHit = 52, // SPELL_EFFECT_GUARANTEE_HIT
    enchantItem = 53, // SPELL_EFFECT_ENCHANT_ITEM
    enchantItemTemporary = 54, // SPELL_EFFECT_ENCHANT_ITEM_TEMPORARY
    tamecreature = 55, // SPELL_EFFECT_TAMECREATURE
    summonPet = 56, // SPELL_EFFECT_SUMMON_PET
    learnPetSpell = 57, // SPELL_EFFECT_LEARN_PET_SPELL
    weaponDamage = 58, // SPELL_EFFECT_WEAPON_DAMAGE
    openLockItem = 59, // SPELL_EFFECT_OPEN_LOCK_ITEM
    proficiency = 60,
    sendEvent = 61, // SPELL_EFFECT_SEND_EVENT
    powerBurn = 62, // SPELL_EFFECT_POWER_BURN
    threat = 63, // SPELL_EFFECT_THREAT
    triggerSpell = 64, // SPELL_EFFECT_TRIGGER_SPELL
    healthFunnel = 65, // SPELL_EFFECT_HEALTH_FUNNEL
    powerFunnel = 66, // SPELL_EFFECT_POWER_FUNNEL
    healMaxHealth = 67, // SPELL_EFFECT_HEAL_MAX_HEALTH
    interruptCast = 68, // SPELL_EFFECT_INTERRUPT_CAST
    distract = 69, // SPELL_EFFECT_DISTRACT
    pull = 70, // SPELL_EFFECT_PULL
    pickpocket = 71,
    addFarsight = 72, // SPELL_EFFECT_ADD_FARSIGHT
    summonPossessed = 73, // SPELL_EFFECT_SUMMON_POSSESSED
    summonTotem = 74, // SPELL_EFFECT_SUMMON_TOTEM
    healMechanical = 75, // SPELL_EFFECT_HEAL_MECHANICAL
    summonObjectWild = 76, // SPELL_EFFECT_SUMMON_OBJECT_WILD
    scriptEffect = 77, // SPELL_EFFECT_SCRIPT_EFFECT
    attack = 78, // SPELL_EFFECT_ATTACK
    sanctuary = 79, // SPELL_EFFECT_SANCTUARY
    addComboPoints = 80, // SPELL_EFFECT_ADD_COMBO_POINTS
    createHouse = 81, // SPELL_EFFECT_CREATE_HOUSE
    bindSight = 82, // SPELL_EFFECT_BIND_SIGHT
    duel = 83, // SPELL_EFFECT_DUEL
    stuck = 84, // SPELL_EFFECT_STUCK
    summonPlayer = 85, // SPELL_EFFECT_SUMMON_PLAYER
    activateObject = 86, // SPELL_EFFECT_ACTIVATE_OBJECT
    summonTotemSlot1 = 87, // SPELL_EFFECT_SUMMON_TOTEM_SLOT1
    summonTotemSlot2 = 88, // SPELL_EFFECT_SUMMON_TOTEM_SLOT2
    summonTotemSlot3 = 89, // SPELL_EFFECT_SUMMON_TOTEM_SLOT3
    summonTotemSlot4 = 90, // SPELL_EFFECT_SUMMON_TOTEM_SLOT4
    threatAll = 91, // SPELL_EFFECT_THREAT_ALL
    enchantHeldItem = 92, // SPELL_EFFECT_ENCHANT_HELD_ITEM
    summonPhantasm = 93, // SPELL_EFFECT_SUMMON_PHANTASM
    selfResurrect = 94, // SPELL_EFFECT_SELF_RESURRECT
    skinning = 95,
    charge = 96, // SPELL_EFFECT_CHARGE
    summonCritter = 97, // SPELL_EFFECT_SUMMON_CRITTER
    knockBack = 98, // SPELL_EFFECT_KNOCK_BACK
    disenchant = 99, // SPELL_EFFECT_DISENCHANT
    inebriate = 100, // SPELL_EFFECT_INEBRIATE
    feedPet = 101, // SPELL_EFFECT_FEED_PET
    dismissPet = 102, // SPELL_EFFECT_DISMISS_PET
    reputation = 103, // SPELL_EFFECT_REPUTATION
    summonObjectSlot1 = 104, // SPELL_EFFECT_SUMMON_OBJECT_SLOT1
    summonObjectSlot2 = 105, // SPELL_EFFECT_SUMMON_OBJECT_SLOT2
    summonObjectSlot3 = 106, // SPELL_EFFECT_SUMMON_OBJECT_SLOT3
    summonObjectSlot4 = 107, // SPELL_EFFECT_SUMMON_OBJECT_SLOT4
    dispelMechanic = 108, // SPELL_EFFECT_DISPEL_MECHANIC
    summonDeadPet = 109, // SPELL_EFFECT_SUMMON_DEAD_PET
    destroyAllTotems = 110, // SPELL_EFFECT_DESTROY_ALL_TOTEMS
    durabilityDamage = 111, // SPELL_EFFECT_DURABILITY_DAMAGE
    summonDemon = 112, // SPELL_EFFECT_SUMMON_DEMON
    resurrectNew = 113, // SPELL_EFFECT_RESURRECT_NEW
    attackMe = 114, // SPELL_EFFECT_ATTACK_ME
    durabilityDamagePct = 115, // SPELL_EFFECT_DURABILITY_DAMAGE_PCT
    skinPlayerCorpse = 116, // SPELL_EFFECT_SKIN_PLAYER_CORPSE
    spiritHeal = 117, // SPELL_EFFECT_SPIRIT_HEAL
    skill = 118,
    applyAreaAuraPet = 119, // SPELL_EFFECT_APPLY_AREA_AURA_PET
    teleportGraveyard = 120, // SPELL_EFFECT_TELEPORT_GRAVEYARD
    normalizedWeaponDmg = 121, // SPELL_EFFECT_NORMALIZED_WEAPON_DMG
    n122 = 122, // SPELL_EFFECT_122
    sendTaxi = 123, // SPELL_EFFECT_SEND_TAXI
    pullTowards = 124, // SPELL_EFFECT_PULL_TOWARDS
    modifyThreatPercent = 125, // SPELL_EFFECT_MODIFY_THREAT_PERCENT
    n126 = 126, // SPELL_EFFECT_126
    n127 = 127, // SPELL_EFFECT_127
    applyAreaAuraFriend = 128, // SPELL_EFFECT_APPLY_AREA_AURA_FRIEND
    applyAreaAuraEnemy = 129, // SPELL_EFFECT_APPLY_AREA_AURA_ENEMY
}

/**
 * Every aura type of 1.12 (a spell effect's `EffectApplyAuraName`), numbered as the client numbers them.
 * Members with a comment naming the reference's constant were added from its list; whether the server does
 * something with each is decided where auras are applied.
 */
enum AuraType : uint
{
    none = 0,
    bindSight = 1,
    modPossess = 2,
    periodicDamage = 3,
    dummy = 4,
    modConfuse = 5,
    modCharm = 6,
    modFear = 7,
    periodicHeal = 8,
    modAttackSpeed = 9,
    modThreat = 10,
    modTaunt = 11,
    modStun = 12,
    modDamageDone = 13,
    modDamageTaken = 14,
    damageShield = 15,
    modStealth = 16,
    modStealthDetect = 17, // SPELL_AURA_MOD_STEALTH_DETECT
    modInvisibility = 18,
    modInvisibilityDetection = 19, // SPELL_AURA_MOD_INVISIBILITY_DETECTION
    obsModHealth = 20,
    obsModMana = 21,
    modResistance = 22,
    periodicTriggerSpell = 23,
    periodicEnergize = 24,
    modPacify = 25,
    modRoot = 26,
    modSilence = 27,
    reflectSpells = 28,
    modStat = 29,
    modSkill = 30,
    modIncreaseSpeed = 31,
    modIncreaseMountedSpeed = 32,
    modDecreaseSpeed = 33,
    modIncreaseHealth = 34,
    modIncreaseEnergy = 35,
    modShapeshift = 36,
    effectImmunity = 37,
    stateImmunity = 38,
    schoolImmunity = 39,
    damageImmunity = 40,
    dispelImmunity = 41,
    procTriggerSpell = 42,
    procTriggerDamage = 43,
    trackCreatures = 44,
    trackResources = 45,
    n46 = 46, // SPELL_AURA_46
    modParryPercent = 47,
    n48 = 48, // SPELL_AURA_48
    modDodgePercent = 49,
    modBlockSkill = 50, // SPELL_AURA_MOD_BLOCK_SKILL
    modBlockPercent = 51,
    modCritPercent = 52,
    periodicLeech = 53,
    modHitChance = 54,
    modSpellHitChance = 55,
    transform = 56,
    modSpellCritChance = 57,
    modIncreaseSwimSpeed = 58,
    modDamageDoneCreature = 59,
    modPacifySilence = 60,
    modScale = 61,
    periodicHealthFunnel = 62, // SPELL_AURA_PERIODIC_HEALTH_FUNNEL
    periodicManaFunnel = 63, // SPELL_AURA_PERIODIC_MANA_FUNNEL
    periodicManaLeech = 64,
    modCastingSpeed = 65,
    feignDeath = 66, // SPELL_AURA_FEIGN_DEATH
    modDisarm = 67, // SPELL_AURA_MOD_DISARM
    modStalked = 68, // SPELL_AURA_MOD_STALKED
    schoolAbsorb = 69,
    extraAttacks = 70, // SPELL_AURA_EXTRA_ATTACKS
    modSpellCritChanceSchool = 71,
    modPowerCostSchoolPct = 72,
    modPowerCostSchool = 73,
    reflectSpellsSchool = 74, // SPELL_AURA_REFLECT_SPELLS_SCHOOL
    modLanguage = 75, // SPELL_AURA_MOD_LANGUAGE
    farSight = 76, // SPELL_AURA_FAR_SIGHT
    mechanicImmunity = 77, // SPELL_AURA_MECHANIC_IMMUNITY
    mounted = 78,
    modDamagePercentDone = 79,
    modPercentStat = 80,
    splitDamagePct = 81, // SPELL_AURA_SPLIT_DAMAGE_PCT
    waterBreathing = 82, // SPELL_AURA_WATER_BREATHING
    modBaseResistance = 83, // SPELL_AURA_MOD_BASE_RESISTANCE
    modRegen = 84,
    modPowerRegen = 85,
    channelDeathItem = 86, // SPELL_AURA_CHANNEL_DEATH_ITEM
    modDamagePercentTaken = 87, // SPELL_AURA_MOD_DAMAGE_PERCENT_TAKEN
    modHealthRegenPercent = 88, // SPELL_AURA_MOD_HEALTH_REGEN_PERCENT
    periodicDamagePercent = 89, // SPELL_AURA_PERIODIC_DAMAGE_PERCENT
    modResistChance = 90, // SPELL_AURA_MOD_RESIST_CHANCE
    modDetectRange = 91, // SPELL_AURA_MOD_DETECT_RANGE
    preventsFleeing = 92, // SPELL_AURA_PREVENTS_FLEEING
    modUnattackable = 93, // SPELL_AURA_MOD_UNATTACKABLE
    interruptRegen = 94, // SPELL_AURA_INTERRUPT_REGEN
    ghost = 95, // SPELL_AURA_GHOST
    spellMagnet = 96, // SPELL_AURA_SPELL_MAGNET
    manaShield = 97,
    modSkillTalent = 98, // SPELL_AURA_MOD_SKILL_TALENT
    modAttackPower = 99,
    aurasVisible = 100, // SPELL_AURA_AURAS_VISIBLE
    modResistancePct = 101,
    modMeleeAttackPowerVersus = 102, // SPELL_AURA_MOD_MELEE_ATTACK_POWER_VERSUS
    modTotalThreat = 103, // SPELL_AURA_MOD_TOTAL_THREAT
    waterWalk = 104, // SPELL_AURA_WATER_WALK
    featherFall = 105, // SPELL_AURA_FEATHER_FALL
    hover = 106, // SPELL_AURA_HOVER
    addFlatModifier = 107, // SPELL_AURA_ADD_FLAT_MODIFIER
    addPctModifier = 108, // SPELL_AURA_ADD_PCT_MODIFIER
    addTargetTrigger = 109, // SPELL_AURA_ADD_TARGET_TRIGGER
    modPowerRegenPercent = 110, // SPELL_AURA_MOD_POWER_REGEN_PERCENT
    addCasterHitTrigger = 111, // SPELL_AURA_ADD_CASTER_HIT_TRIGGER
    overrideClassScripts = 112, // SPELL_AURA_OVERRIDE_CLASS_SCRIPTS
    modRangedDamageTaken = 113, // SPELL_AURA_MOD_RANGED_DAMAGE_TAKEN
    modRangedDamageTakenPct = 114, // SPELL_AURA_MOD_RANGED_DAMAGE_TAKEN_PCT
    modHealing = 115, // SPELL_AURA_MOD_HEALING
    modRegenDuringCombat = 116, // SPELL_AURA_MOD_REGEN_DURING_COMBAT
    modMechanicResistance = 117, // SPELL_AURA_MOD_MECHANIC_RESISTANCE
    modHealingPct = 118, // SPELL_AURA_MOD_HEALING_PCT
    sharePetTracking = 119, // SPELL_AURA_SHARE_PET_TRACKING
    untrackable = 120, // SPELL_AURA_UNTRACKABLE
    empathy = 121, // SPELL_AURA_EMPATHY
    modOffhandDamagePct = 122, // SPELL_AURA_MOD_OFFHAND_DAMAGE_PCT
    modTargetResistance = 123, // SPELL_AURA_MOD_TARGET_RESISTANCE
    modRangedAttackPower = 124,
    modMeleeDamageTaken = 125, // SPELL_AURA_MOD_MELEE_DAMAGE_TAKEN
    modMeleeDamageTakenPct = 126, // SPELL_AURA_MOD_MELEE_DAMAGE_TAKEN_PCT
    rangedAttackPowerAttackerBonus = 127, // SPELL_AURA_RANGED_ATTACK_POWER_ATTACKER_BONUS
    modPossessPet = 128, // SPELL_AURA_MOD_POSSESS_PET
    modSpeedAlways = 129, // SPELL_AURA_MOD_SPEED_ALWAYS
    modMountedSpeedAlways = 130, // SPELL_AURA_MOD_MOUNTED_SPEED_ALWAYS
    modRangedAttackPowerVersus = 131, // SPELL_AURA_MOD_RANGED_ATTACK_POWER_VERSUS
    modIncreaseEnergyPercent = 132, // SPELL_AURA_MOD_INCREASE_ENERGY_PERCENT
    modIncreaseHealthPercent = 133, // SPELL_AURA_MOD_INCREASE_HEALTH_PERCENT
    modManaRegenInterrupt = 134, // SPELL_AURA_MOD_MANA_REGEN_INTERRUPT
    modHealingDone = 135,
    modHealingDonePercent = 136, // SPELL_AURA_MOD_HEALING_DONE_PERCENT
    modTotalStatPercentage = 137, // SPELL_AURA_MOD_TOTAL_STAT_PERCENTAGE
    modMeleeHaste = 138, // SPELL_AURA_MOD_MELEE_HASTE
    forceReaction = 139, // SPELL_AURA_FORCE_REACTION
    modRangedHaste = 140, // SPELL_AURA_MOD_RANGED_HASTE
    modRangedAmmoHaste = 141, // SPELL_AURA_MOD_RANGED_AMMO_HASTE
    modBaseResistancePct = 142, // SPELL_AURA_MOD_BASE_RESISTANCE_PCT
    modResistanceExclusive = 143, // SPELL_AURA_MOD_RESISTANCE_EXCLUSIVE
    safeFall = 144, // SPELL_AURA_SAFE_FALL
    charisma = 145, // SPELL_AURA_CHARISMA
    persuaded = 146, // SPELL_AURA_PERSUADED
    mechanicImmunityMask = 147, // SPELL_AURA_MECHANIC_IMMUNITY_MASK
    retainComboPoints = 148, // SPELL_AURA_RETAIN_COMBO_POINTS
    resistPushback = 149, // SPELL_AURA_RESIST_PUSHBACK
    modShieldBlockvaluePct = 150, // SPELL_AURA_MOD_SHIELD_BLOCKVALUE_PCT
    trackStealthed = 151, // SPELL_AURA_TRACK_STEALTHED
    modDetectedRange = 152, // SPELL_AURA_MOD_DETECTED_RANGE
    splitDamageFlat = 153, // SPELL_AURA_SPLIT_DAMAGE_FLAT
    modStealthLevel = 154, // SPELL_AURA_MOD_STEALTH_LEVEL
    modWaterBreathing = 155, // SPELL_AURA_MOD_WATER_BREATHING
    modReputationGain = 156, // SPELL_AURA_MOD_REPUTATION_GAIN
    petDamageMulti = 157, // SPELL_AURA_PET_DAMAGE_MULTI
    modShieldBlockvalue = 158, // SPELL_AURA_MOD_SHIELD_BLOCKVALUE
    noPvpCredit = 159, // SPELL_AURA_NO_PVP_CREDIT
    modAoeAvoidance = 160, // SPELL_AURA_MOD_AOE_AVOIDANCE
    modHealthRegenInCombat = 161, // SPELL_AURA_MOD_HEALTH_REGEN_IN_COMBAT
    powerBurnMana = 162, // SPELL_AURA_POWER_BURN_MANA
    modCritDamageBonus = 163, // SPELL_AURA_MOD_CRIT_DAMAGE_BONUS
    n164 = 164, // SPELL_AURA_164
    meleeAttackPowerAttackerBonus = 165, // SPELL_AURA_MELEE_ATTACK_POWER_ATTACKER_BONUS
    modAttackPowerPct = 166, // SPELL_AURA_MOD_ATTACK_POWER_PCT
    modRangedAttackPowerPct = 167, // SPELL_AURA_MOD_RANGED_ATTACK_POWER_PCT
    modDamageDoneVersus = 168, // SPELL_AURA_MOD_DAMAGE_DONE_VERSUS
    modCritPercentVersus = 169, // SPELL_AURA_MOD_CRIT_PERCENT_VERSUS
    detectAmore = 170, // SPELL_AURA_DETECT_AMORE
    modSpeedNotStack = 171, // SPELL_AURA_MOD_SPEED_NOT_STACK
    modMountedSpeedNotStack = 172, // SPELL_AURA_MOD_MOUNTED_SPEED_NOT_STACK
    allowChampionSpells = 173, // SPELL_AURA_ALLOW_CHAMPION_SPELLS
    modSpellDamageOfStatPercent = 174, // SPELL_AURA_MOD_SPELL_DAMAGE_OF_STAT_PERCENT
    modSpellHealingOfStatPercent = 175, // SPELL_AURA_MOD_SPELL_HEALING_OF_STAT_PERCENT
    spiritOfRedemption = 176, // SPELL_AURA_SPIRIT_OF_REDEMPTION
    aoeCharm = 177, // SPELL_AURA_AOE_CHARM
    modDebuffResistance = 178, // SPELL_AURA_MOD_DEBUFF_RESISTANCE
    modAttackerSpellCritChance = 179, // SPELL_AURA_MOD_ATTACKER_SPELL_CRIT_CHANCE
    modFlatSpellDamageVersus = 180, // SPELL_AURA_MOD_FLAT_SPELL_DAMAGE_VERSUS
    modFlatSpellCritDamageVersus = 181, // SPELL_AURA_MOD_FLAT_SPELL_CRIT_DAMAGE_VERSUS
    modResistanceOfStatPercent = 182, // SPELL_AURA_MOD_RESISTANCE_OF_STAT_PERCENT
    modCriticalThreat = 183, // SPELL_AURA_MOD_CRITICAL_THREAT
    modAttackerMeleeHitChance = 184, // SPELL_AURA_MOD_ATTACKER_MELEE_HIT_CHANCE
    modAttackerRangedHitChance = 185, // SPELL_AURA_MOD_ATTACKER_RANGED_HIT_CHANCE
    modAttackerSpellHitChance = 186, // SPELL_AURA_MOD_ATTACKER_SPELL_HIT_CHANCE
    modAttackerMeleeCritChance = 187, // SPELL_AURA_MOD_ATTACKER_MELEE_CRIT_CHANCE
    modAttackerRangedCritChance = 188, // SPELL_AURA_MOD_ATTACKER_RANGED_CRIT_CHANCE
    modRating = 189, // SPELL_AURA_MOD_RATING
    modFactionReputationGain = 190, // SPELL_AURA_MOD_FACTION_REPUTATION_GAIN
    useNormalMovementSpeed = 191, // SPELL_AURA_USE_NORMAL_MOVEMENT_SPEED
}

/**
 * Every implicit target of 1.12 (`Spell.dbc`'s target columns), numbered as the client numbers them; members
 * with a comment naming the reference's constant were added from its list.
 */
enum ImplicitTarget : uint
{
    none = 0,
    caster = 1,
    enemyNearCaster = 2,
    friendNearCaster = 3,
    unitNearCaster = 4, // TARGET_UNIT_NEAR_CASTER
    unitCasterPet = 5, // TARGET_UNIT_CASTER_PET
    enemy = 6,
    enumUnitsScriptAoeAtSrcLoc = 7, // TARGET_ENUM_UNITS_SCRIPT_AOE_AT_SRC_LOC
    enumUnitsScriptAoeAtDestLoc = 8, // TARGET_ENUM_UNITS_SCRIPT_AOE_AT_DEST_LOC
    homeBind = 9,
    locationCasterDivineBindNyi = 10, // TARGET_LOCATION_CASTER_DIVINE_BIND_NYI
    playerNyi = 11, // TARGET_PLAYER_NYI
    playerNearCasterNyi = 12, // TARGET_PLAYER_NEAR_CASTER_NYI
    playerEnemyNyi = 13, // TARGET_PLAYER_ENEMY_NYI
    playerFriendNyi = 14, // TARGET_PLAYER_FRIEND_NYI
    enemiesAroundSource = 15,
    enemiesAroundDest = 16,
    database = 17,
    locationCasterDest = 18, // TARGET_LOCATION_CASTER_DEST
    unk19 = 19, // TARGET_UNK_19
    partyInRange = 20,
    friend = 21,
    casterSource = 22,
    gameObject = 23,
    enemiesInCone = 24,
    unit = 25,
    gameObjectItem = 26,
    unitCasterMaster = 27, // TARGET_UNIT_CASTER_MASTER
    enumUnitsEnemyAoeAtDynobjLoc = 28, // TARGET_ENUM_UNITS_ENEMY_AOE_AT_DYNOBJ_LOC
    enumUnitsFriendAoeAtDynobjLoc = 29, // TARGET_ENUM_UNITS_FRIEND_AOE_AT_DYNOBJ_LOC
    friendsAroundSource = 30,
    friendsAroundDest = 31,
    locationUnitMinionPosition = 32, // TARGET_LOCATION_UNIT_MINION_POSITION
    partyAroundSource = 33,
    enumUnitsPartyAoeAtDestLoc = 34, // TARGET_ENUM_UNITS_PARTY_AOE_AT_DEST_LOC
    party = 35,
    enumUnitsEnemyWithinCasterRange = 36, // TARGET_ENUM_UNITS_ENEMY_WITHIN_CASTER_RANGE
    unitFriendAndParty = 37, // TARGET_UNIT_FRIEND_AND_PARTY
    unitScriptNearCaster = 38, // TARGET_UNIT_SCRIPT_NEAR_CASTER
    locationCasterFishingSpot = 39, // TARGET_LOCATION_CASTER_FISHING_SPOT
    gameobjectScriptNearCaster = 40, // TARGET_GAMEOBJECT_SCRIPT_NEAR_CASTER
    locationCasterFrontRight = 41, // TARGET_LOCATION_CASTER_FRONT_RIGHT
    locationCasterBackRight = 42, // TARGET_LOCATION_CASTER_BACK_RIGHT
    locationCasterBackLeft = 43, // TARGET_LOCATION_CASTER_BACK_LEFT
    locationCasterFrontLeft = 44, // TARGET_LOCATION_CASTER_FRONT_LEFT
    unitFriendChainHeal = 45, // TARGET_UNIT_FRIEND_CHAIN_HEAL
    locationScriptNearCaster = 46, // TARGET_LOCATION_SCRIPT_NEAR_CASTER
    locationCasterFront = 47, // TARGET_LOCATION_CASTER_FRONT
    locationCasterBack = 48, // TARGET_LOCATION_CASTER_BACK
    locationCasterLeft = 49, // TARGET_LOCATION_CASTER_LEFT
    locationCasterRight = 50, // TARGET_LOCATION_CASTER_RIGHT
    enumGameobjectsScriptAoeAtSrcLoc = 51, // TARGET_ENUM_GAMEOBJECTS_SCRIPT_AOE_AT_SRC_LOC
    enumGameobjectsScriptAoeAtDestLoc = 52, // TARGET_ENUM_GAMEOBJECTS_SCRIPT_AOE_AT_DEST_LOC
    locationCasterTargetPosition = 53, // TARGET_LOCATION_CASTER_TARGET_POSITION
    enumUnitsEnemyInCone54 = 54, // TARGET_ENUM_UNITS_ENEMY_IN_CONE_54
    locationCasterFrontLeap = 55, // TARGET_LOCATION_CASTER_FRONT_LEAP
    enumUnitsRaidWithinCasterRange = 56, // TARGET_ENUM_UNITS_RAID_WITHIN_CASTER_RANGE
    unitRaid = 57, // TARGET_UNIT_RAID
    unitRaidNearCaster = 58, // TARGET_UNIT_RAID_NEAR_CASTER
    enumUnitsFriendInCone = 59, // TARGET_ENUM_UNITS_FRIEND_IN_CONE
    enumUnitsScriptInCone60 = 60, // TARGET_ENUM_UNITS_SCRIPT_IN_CONE_60
    unitRaidAndClass = 61, // TARGET_UNIT_RAID_AND_CLASS
    playerRaidNyi = 62, // TARGET_PLAYER_RAID_NYI
    locationUnitPosition = 63, // TARGET_LOCATION_UNIT_POSITION
}

/// A spell's damage class (`Spell.dbc`).
enum DamageClass : uint
{
    none = 0,
    magic = 1,
    melee = 2,
    ranged = 3,
}

/**
 * `value` as an `E`, or `E.init` (each of these enums' "none") if no member has it, counted in `unknown`.
 * The members of each are 0 to `E.max` without a gap (checked below), so one comparison decides.
 */
E knownOr(E)(uint value, ref uint unknown) pure nothrow @nogc @safe
if (is(E == enum))
{
    if (value <= E.max)
        return cast(E) value;
    ++unknown;
    return E.init;
}

private bool contiguous(E)()
{
    import std.traits : EnumMembers;

    bool[E.max + 1] seen;
    foreach (m; EnumMembers!E)
        seen[m] = true;
    foreach (s; seen)
        if (!s)
            return false;
    return E.init == 0;
}

static assert(contiguous!SpellEffect && contiguous!AuraType && contiguous!ImplicitTarget && contiguous!DamageClass,
    "knownOr assumes each id enum runs from 0 to its last member without a gap");

pure nothrow @nogc @safe unittest
{
    uint unknown;
    assert(knownOr!SpellEffect(6, unknown) == SpellEffect.applyAura && unknown == 0);
    assert(knownOr!SpellEffect(900, unknown) == SpellEffect.none && unknown == 1);
}
