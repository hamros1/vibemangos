# The Cleaner during Benediction

## Which actions bring The Cleaner?

### Takeaway

An outsider running into the active peasant procession and an outsider healing the priest who started the quest are supported triggers. A helper on the hill by Eris can heal and cleanse peasants while standing still. These observations distinguish whom a spell helped and where a bystander stood. [Archived player accounts](https://www.wowhead.com/classic/quest=7622/the-balance-of-light-and-shadow) · [2019 Classic participants](https://www.reddit.com/r/classicwow/comments/e9f2ef/) · [Classic walkthrough by a player who completed the event](https://almarsguides.com/wow/gettingstarted/classes/classic/priest/quests/benediction/)

### Cited Findings

- An archived Allakhazam author describes a warlock running through the peasants and summoning The Cleaner. Another account describes a helper staying off the path by the cave while the initiating priest moved with the peasants. A Classic priest reports that a party member running in caused The Cleaner to kill the priest. [Original player comments](https://www.wowhead.com/classic/quest=7622/the-balance-of-light-and-shadow) · [December 2019 Classic account](https://www.reddit.com/r/classicwow/comments/edqev6/)
- An archived player who completed the event alongside two other priests reports that healing the priest who accepted triggered the demon. Almar’s Classic walkthrough also identifies an outside heal or buff to the priest as a trigger. A Classic Era commenter reports the same for healing the initiating priest. [Original quest comments](https://www.wowhead.com/classic/quest=7622/the-balance-of-light-and-shadow) · [Almar’s walkthrough](https://almarsguides.com/wow/gettingstarted/classes/classic/priest/quests/benediction/) · [Era participant’s July 2024 comment](https://www.reddit.com/r/classicwow/comments/1edvjs2/)
- One 2019 group describes several priests of both factions helping from the hill with heals and disease dispels on the peasants. Another firsthand player reports that he and another priest both completed a shared quest while his stationary partner healed peasants and killed skeletons near the cave. [Hill group](https://www.reddit.com/r/classicwow/comments/e9f2ef/) · [Two successful priests](https://www.reddit.com/r/classicwow/comments/edqev6/)
- A Classic mage describes using Blizzard and Arcane Explosion from one stationary spot without triggering the demon. This also appears in a separate 2019 completion report. A blanket rule penalizing any outsider damage would wrongly fail those runs. [Mage’s November 2019 recording and account](https://www.youtube.com/watch?v=qy7XGIaLF5g) · [Independent Classic account](https://www.reddit.com/r/classicwow/comments/edqev6/)

### Inferences

- Positive tests should cover a moving outsider crossing the active procession and an effective direct heal to its initiating priest. Negative tests should cover a priest moving with their own procession, an observer on the hill, and a helper on the hill curing or healing a peasant. Include a stationary magic attack on a skeleton from the documented safe spot.
- Membership in the priest’s party cannot by itself determine who triggers the penalty. A second eligible priest can complete the shared quest and still runs a risk entering its route.

### Gaps

- The exact shape, radius, vertical tolerance, and polling cadence of the route trigger remain undocumented. Phrases like “don't move” describe a strategy. They do not prove a movement rule extending to the entire zone. Reports disagree about a skeleton hitting a helper versus the helper doing damage. Tests should distinguish movement across the path from combat in a stationary position. The Classic client or surviving packet captures would be needed to establish the numeric boundary.
- Direct healing the initiating priest is better evidenced than a new buff, an overheal, an existing HoT, incidental party aura, pet damage, or casting from outside the area. Pre-event buffs and self-healing are part of successful strategies. A broad global heal/combat or generic party threat rule exceeds the evidence.

## Who does the demon punish and how does the event reset?

### Takeaway

The initiating priest can die to a real hostile Cleaner and fail the attempt after a helper interferes. Reports about the helper dying and the reset timer vary. The current world database already has a 10-minute normal respawn on Eris. [Firsthand interference and recovery](https://www.reddit.com/r/classicwow/comments/edqev6/) · [Classic quest accounts](https://www.wowhead.com/classic/quest=7622/the-balance-of-light-and-shadow) · [World database source](https://github.com/cmangos/classic-db)

### Cited Findings

- The priest who asked a friend to run in says that The Cleaner killed only the priest in that attempt. Quest comments include accounts of both dying. Survival of the interloper therefore cannot invalidate a test that observed the demon attacking the initiator. [December 2019 priest’s report](https://www.reddit.com/r/classicwow/comments/edqev6/) · [Additional firsthand Classic quest accounts](https://www.wowhead.com/classic/quest=7622/the-balance-of-light-and-shadow)
- The installed server database gives Eris (14494, spawn 590009) both a minimum and maximum of 600 seconds. The Cleaner (14503) already binds to npc_the_cleaner, which applies its immunity on spawn, speaks on aggro, and implements its combat lifecycle. Eris already owns the encounter summons and has a failure path. [Eris script](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/easternplaguelands.d#L17) · [Cleaner script](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/npcs.d#L403) · [Classic-DB](https://github.com/cmangos/classic-db)
- December 2019 Classic players observed waits of about 15 minutes after failures. Almar describes a longer reset for an ordinary failure and a shorter one for interference. Neither provides a timed original 1.12 trace that would justify overriding this realm’s data. [2019 reports](https://www.reddit.com/r/classicwow/comments/edqev6/) · [Almar’s account](https://almarsguides.com/wow/gettingstarted/classes/classic/priest/quests/benediction/)

### Inferences

- Exercise the existing NPC with a real threat target and its combat AI. Test that the initiating priest is attacked, death precludes credit, the event clears its summons and later restarts, and the next solo run can succeed.
- Check that an inactive or completed event cannot trigger the demon. Keep one interference signal from repeatedly spawning it every server update. The evidence does not establish the number of Cleaners which independent infractions at exactly the same instant could produce.

### Gaps

- Whether the original event failed on the spawn itself or only after the quest holder died, and whether the demon always acquired the helper as a second threat target, are unproven. Evidence supports the observed attack and failed attempt. It does not support instantly killing every bystander or a new hard-coded cooldown.
