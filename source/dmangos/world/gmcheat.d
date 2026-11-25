/// Gameplay cheats.
module dmangos.world.gmcheat;

/// `.cheat`: testing toggles, flight paths, exploration and aura stacks for the selected player.
mixin template CheatCommands()
{
    import std.format : format;
    import dmangos.world.commands : ChatColor, colored, Nullable, OnOff;
    import dmangos.world.defines : exploredZonesSize;
    import dmangos.world.updatefields : PLAYER_EXPLORED_ZONES_1;

private:
    /// `.cheat status`: which testing toggles the selected player has on.
    bool handleShowCheatsCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        greenSystemMessage("Testing toggles  ·  " ~ target.player.data.name);
        void status(string name, bool on)
        {
            const state = on ? colored(ChatColor.green, "On") : colored(ChatColor.grey, "Off");
            systemMessage(name ~ "  " ~ state);
        }

        status("No cooldowns", target.cooldownCheat);
        status("Instant casts", target.castTimeCheat);
        status("Damage immunity", target.godModeCheat);
        status("Free casts", target.powerCheat);
        status("Skip area requirements", target.triggerpassCheat);
        return true;
    }

    /// `.cheat taxi <on|off>`: every flight node known, or none.
    bool handleTaxiCheatCommand(OnOff state)
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        // The first message goes to the GM, the second to the player it is meant for.
        if (state == OnOff.on)
        {
            greenSystemMessage(format!"%s has all taxi nodes now."(target.player.data.name));
            target.systemMessage(format!"%s has given you all taxi nodes."(player.data.name));
        }
        else
        {
            greenSystemMessage(format!"%s has no more taxi nodes now."(target.player.data.name));
            target.systemMessage(format!"%s has deleted all your taxi nodes."(player.data.name));
        }
        target.player.data.taxiMask[] = state == OnOff.on ? uint.max : 0u;
        return true;
    }

    /// `.cheat explore <on|off>`: every zone explored, or none.
    bool handleExploreCheatCommand(OnOff state)
    {
        auto target = selectedCharacter(true);
        if (target is null)
        {
            target = this;
            systemMessage("Targeting yourself.");
        }
        const name = target.player.data.name;
        // The first message goes to the GM, the second to the player it is meant for.
        if (state == OnOff.on)
        {
            greenSystemMessage(format!"%s has explored all zones now."(name));
            target.systemMessage(format!"%s has explored all zones for you."(player.data.name));
            gmLog("explored all zones for player " ~ name);
        }
        else
        {
            greenSystemMessage(format!"%s has no more explored zones."(name));
            target.systemMessage(format!"%s has hidden all zones from you."(player.data.name));
            gmLog("hid all zones for player " ~ name);
        }
        foreach (i; 0 .. exploredZonesSize)
            target.player.values.set!PLAYER_EXPLORED_ZONES_1(i, state == OnOff.on ? uint.max : 0u);
        target.flushPlayerChanges();
        return true;
    }

    /**
     * Sets the selected player's testing flag `name` (`flag` points to it): flipped if `state` is
     * omitted, `whenOn` run when it is on. The player is told if it is not the GM.
     */
    bool toggleCheat(Nullable!OnOff state, string name, bool* delegate(Character) flag,
        void delegate(Character) whenOn = null)
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        auto enabled = flag(target);
        *enabled = state.isNull ? !*enabled : state.get == OnOff.on;
        if (*enabled && whenOn !is null)
            whenOn(target);

        const value = *enabled ? "on" : "off";
        blueSystemMessage(format!"%s: %s for %s."(name, value, target.player.data.name));
        if (target !is this)
            target.greenSystemMessage(format!"%s turned %s %s."(player.data.name, value, name));
        gmLog(format!"set %s %s for %s"(name, value, target.player.data.name));
        return true;
    }

    /// `.cheat stack <spell> <stacks>`: the stack count of an aura the selected player has.
    bool handleAuraStackCommand(uint spell, uint stacks)
    {
        if (stacks < 1 || stacks > 255)
            return false;
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        auto auras = &target.player.auras;
        foreach (aura; auras.list)
        {
            if (aura.spell.id != spell || aura.passive || aura.channelToken)
                continue;
            aura.stacks = stacks;
            ++auras.changes;
            auras.writeSlot(aura, target.player.values);
            target.player.refreshEquipmentStats(context.data);
            target.refreshSpeeds();
            target.flushPlayerChanges();
            gmLog(format!"set spell %s stacks to %s on %s"(spell, stacks, target.player.data.name));
            greenSystemMessage(format!"Spell %s · %s stacks on %s."(spell, stacks, target.player.data.name));
            return true;
        }
        redSystemMessage("Apply that spell as an ordinary aura before changing its stack count.");
        return true;
    }

    /// `.cheat casttime [on|off]`.
    bool handleCastTimeCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "Instant casts", (Character c) => &c.castTimeCheat);
    }

    /// `.cheat cooldown [on|off]`: on, every known spell's cooldown is cleared too.
    bool handleCooldownCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "No cooldowns", (Character c) => &c.cooldownCheat,
            (Character c) {
                foreach (spell; c.player.spells)
                    c.clearCooldownFor(spell);
            });
    }

    /// `.cheat god [on|off]`.
    bool handleGodModeCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "Damage immunity", (Character c) => &c.godModeCheat);
    }

    /// `.cheat power [on|off]`.
    bool handlePowerCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "Free casts", (Character c) => &c.powerCheat);
    }

    /// `.cheat triggerpass [on|off]`.
    bool handleTriggerpassCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "Skip area requirements", (Character c) => &c.triggerpassCheat);
    }
}
