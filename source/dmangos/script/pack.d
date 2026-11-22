/**
 * A pack: the creatures a dungeon script counts together (the keepers of a ward, the adds of a
 * wave, a boss's guards). It remembers who belongs and who has died, as plain data saved with the
 * script, so "the last one fell" is known after a restart too. A creature seen twice (its cell
 * loaded again) is counted once.
 */
module dmangos.script.pack;

import dmangos.script.api : EntityRef;

/// See the module documentation. At most `capacity` members.
struct Pack(size_t capacity = 8)
{
    private EntityRef[capacity] members;
    private bool[capacity] dead_;
    private ubyte count;

    /// `who` belongs (a member already: nothing changes). False if the pack is full.
    bool add(EntityRef who)
    {
        if (has(who))
            return true;
        if (count == capacity)
            return false;
        members[count] = who;
        dead_[count] = false;
        ++count;
        return true;
    }

    /// `who` died; false if it is not a member.
    bool died(EntityRef who)
    {
        foreach (i; 0 .. count)
            if (members[i] == who)
            {
                dead_[i] = true;
                return true;
            }
        return false;
    }

    /// Whether `who` is a member.
    bool has(EntityRef who) const
    {
        foreach (i; 0 .. count)
            if (members[i] == who)
                return true;
        return false;
    }

    /// Where `who` is among the members (they keep the places they were added in); -1 if it is not one.
    ptrdiff_t indexOf(EntityRef who) const
    {
        foreach (i; 0 .. count)
            if (members[i] == who)
                return i;
        return -1;
    }

    /// How many members are alive.
    @property uint alive() const
    {
        uint n;
        foreach (i; 0 .. count)
            n += !dead_[i];
        return n;
    }

    /// How many members it has had.
    @property uint length() const
    {
        return count;
    }

    /// Whether it has members and every one of them is dead.
    @property bool allDead() const
    {
        return count > 0 && alive == 0;
    }

    /// Whether it has no members.
    @property bool empty() const
    {
        return count == 0;
    }

    /// No members any more.
    void clear()
    {
        count = 0;
    }

    /// Keeps the members, clearing the record of their deaths after an encounter reset.
    void reviveAll()
    {
        dead_[] = false;
    }

    /// Its living members.
    int opApply(scope int delegate(EntityRef) each) const
    {
        foreach (i; 0 .. count)
            if (!dead_[i])
                if (const r = each(members[i]))
                    return r;
        return 0;
    }
}

unittest
{
    Pack!2 p;
    assert(!p.allDead && p.empty);
    assert(p.add(EntityRef(1)) && p.add(EntityRef(1)) && p.add(EntityRef(2)) && !p.add(EntityRef(3)));
    assert(p.length == 2 && p.alive == 2);
    assert(p.died(EntityRef(1)) && !p.died(EntityRef(3)) && !p.allDead);
    EntityRef[] living;
    foreach (who; p)
        living ~= who;
    assert(living == [EntityRef(2)]);
    p.died(EntityRef(2));
    assert(p.allDead);
}
