/// Gameplay cheats.
module dmangos.world.gmcheat;

mixin template CheatCommands()
{
    import std.format : format;
    import dmangos.world.commands;
    import dmangos.world.defines : exploredZonesSize;
    import dmangos.world.updatefields;

private:
    bool handleShowCheatsCommand()
    {
        auto plyr = getSelectedChar(true);
        if (plyr is null)
            return true;
        greenSystemMessage("Testing toggles  ·  " ~ plyr.player.data.name);
        void status(string name, bool on)
        {
            systemMessage(format!"%s  %s%s|r"(name, on ? MSG_COLOR_GREEN : MSG_COLOR_GREY, on ? "On" : "Off"));
        }

        status("No cooldowns", plyr.cooldownCheat);
        status("Instant casts", plyr.castTimeCheat);
        status("Damage immunity", plyr.godModeCheat);
        status("Free casts", plyr.powerCheat);
        status("Skip area requirements", plyr.triggerpassCheat);
        return true;
    }

    bool handleTaxiCheatCommand(OnOff state)
    {
        auto chr = getSelectedChar(true);
        if (chr is null)
            return true;
        // The first message goes to the GM, the second to the player it is meant for.
        if (state == OnOff.on)
        {
            greenSystemMessage(format!"%s has all taxi nodes now."(chr.player.data.name));
            chr.systemMessage(format!"%s has given you all taxi nodes."(player.data.name));
        }
        else
        {
            greenSystemMessage(format!"%s has no more taxi nodes now."(chr.player.data.name));
            chr.systemMessage(format!"%s has deleted all your taxi nodes."(player.data.name));
        }
        chr.player.data.taxiMask[] = state == OnOff.on ? uint.max : 0u;
        return true;
    }

    bool handleExploreCheatCommand(OnOff state)
    {
        auto chr = getSelectedChar(true);
        if (chr is null)
        {
            chr = this;
            systemMessage("Targeting yourself.");
        }
        const name = chr.player.data.name;
        // The first message goes to the GM, the second to the player it is meant for.
        if (state == OnOff.on)
        {
            systemMessage(format!"%s has explored all zones now."(name));
            chr.systemMessage(format!"%s has explored all zones for you."(player.data.name));
            gmLog("explored all zones for player " ~ name);
        }
        else
        {
            systemMessage(format!"%s has no more explored zones."(name));
            chr.systemMessage(format!"%s has hidden all zones from you."(player.data.name));
            gmLog("hid all zones for player " ~ name);
        }
        foreach (i; 0 .. exploredZonesSize)
            chr.player.values.set!PLAYER_EXPLORED_ZONES_1(i, state == OnOff.on ? uint.max : 0u);
        chr.flushPlayerChanges();
        return true;
    }

    /// An omitted state flips the test flag. Explicit states can be applied repeatedly.
    bool toggleCheat(Nullable!OnOff state, string name, bool* delegate(Character) flag,
        void delegate(Character) whenOn = null)
    {
        auto target = getSelectedChar(true);
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

    bool handleCastTimeCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "Instant casts", (Character p) => &p.castTimeCheat);
    }

    bool handleCooldownCheatCommand(Nullable!OnOff state)
    {
        // On, every spell known has its cooldown cleared.
        return toggleCheat(state, "No cooldowns", (Character p) => &p.cooldownCheat,
            (Character p) {
                foreach (spell; p.player.spells)
                    p.clearCooldownFor(spell);
            });
    }

    bool handleGodModeCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "Damage immunity", (Character p) => &p.godModeCheat);
    }

    bool handlePowerCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "Free casts", (Character p) => &p.powerCheat);
    }

    bool handleTriggerpassCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "Skip area requirements", (Character p) => &p.triggerpassCheat);
    }

    // -----------------------------------------------------------------------
    // Cooldowns, auras, talents (`HandleClearCooldownsCommand`, `HandleRemoveAurasCommand`, ...)
    // -----------------------------------------------------------------------
}
