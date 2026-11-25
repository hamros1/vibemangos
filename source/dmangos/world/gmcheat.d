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
        uint active, inactive;
        void status(string name, bool on)
        {
            systemMessage(format!"%s%s: %s%s"(MSG_COLOR_LIGHTBLUE, name, on ? MSG_COLOR_LIGHTRED : MSG_COLOR_GREEN,
                on ? "Active" : "Inactive"));
            if (on)
                ++active;
            else
                ++inactive;
        }

        greenSystemMessage("Showing cheat status for: " ~ plyr.player.data.name);
        // Flying and stacking auras do not exist yet: never on.
        status("Cooldown", plyr.cooldownCheat);
        status("CastTime", plyr.castTimeCheat);
        status("GodMode", plyr.godModeCheat);
        status("Power", plyr.powerCheat);
        status("Fly", false);
        status("AuraStack", false);
        status("TriggerPass", plyr.triggerpassCheat);
        systemMessage(format!"%u cheats active, %u inactive."(active, inactive));
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
            systemMessage("Auto-targeting self.");
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

    /**
     * The shape of the cheat toggles: on, off, or (with nothing said) the other way; the GM and
     * the player told, and the GM log when it goes off for another.
     */
    bool toggleCheat(Nullable!OnOff state, string name, string logLine, bool* delegate(Character) flag,
        void delegate(Character) whenOn = null)
    {
        auto plyr = getSelectedChar(true);
        if (plyr is null)
            return true;
        auto on = flag(plyr);
        if (state.isNull)
            state = *on ? OnOff.off : OnOff.on;
        if (state.get == OnOff.on)
        {
            *on = true;
            if (whenOn !is null)
                whenOn(plyr);
            blueSystemMessage(format!"activated the %s cheat on %s."(name, plyr.player.data.name));
            plyr.greenSystemMessage(format!"activated the %s cheat on you."(name));
        }
        else
        {
            *on = false;
            blueSystemMessage(format!"deactivated the %s cheat on %s."(name, plyr.player.data.name));
            plyr.greenSystemMessage(format!"deactivated the %s cheat on you."(name));
            if (plyr !is this)
                gmLog(format!"%s on %s set to %s"(logLine, plyr.player.data.name, state.get));
        }
        return true;
    }

    bool handleCastTimeCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "cast time", "god cast time", (Character p) => &p.castTimeCheat);
    }

    bool handleCooldownCheatCommand(Nullable!OnOff state)
    {
        // On, every spell known has its cooldown cleared.
        return toggleCheat(state, "cooldown", "cooldown cheat", (Character p) => &p.cooldownCheat,
            (Character p) {
                foreach (spell; p.player.spells)
                    p.clearCooldownFor(spell);
            });
    }

    bool handleGodModeCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "god mode", "god mode cheat", (Character p) => &p.godModeCheat);
    }

    bool handlePowerCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "power", "power cheat", (Character p) => &p.powerCheat);
    }

    bool handleTriggerpassCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "triggerpass", "triggerpass cheat", (Character p) => &p.triggerpassCheat);
    }

    // -----------------------------------------------------------------------
    // Cooldowns, auras, talents (`HandleClearCooldownsCommand`, `HandleRemoveAurasCommand`, ...)
    // -----------------------------------------------------------------------
}
