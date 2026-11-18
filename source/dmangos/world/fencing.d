/**
 * Fencing of the databases (docs/CLUSTER.md): a cluster node whose lease has lapsed must not
 * write anything, because by the time the coordinator gives its accounts and regions to other nodes it
 * has certainly stopped, and anything it wrote after that could overwrite theirs.
 *
 * `FencedDatabase` wraps the world server's `WorldDatabase` and forwards every call, except that while
 * `writesAllowed` says no, the calls that write (all those that return nothing) are dropped and
 * counted. It is generated from the interface (`std.typecons.AutoImplement`), so a method added there
 * is fenced without anyone remembering to.
 */
module dmangos.world.fencing;

import std.traits : ReturnType;
import std.typecons : AutoImplement;

import dmangos.world.database : WorldDatabase;

/// The part of `FencedDatabase` that is not generated.
abstract class FencedBase : WorldDatabase
{
    protected WorldDatabase inner;
    protected bool delegate() writesAllowed;
    /// Writes dropped while fenced.
    ulong refused;

    ///
    this(WorldDatabase inner, bool delegate() writesAllowed)
    {
        this.inner = inner;
        this.writesAllowed = writesAllowed;
    }

    /// Whether writes go through now.
    @property bool writesAllowedNow()
    {
        return writesAllowed();
    }

    protected void refuse(string what)
    {
        import dmangos.log : warning;

        if (refused++ % 100 == 0)
            warning!"fenced: this node's lease has lapsed, so '%s' was not written (%s writes refused so far)"(what,
                refused);
    }
}

// Every method of the interface: forwarded; one that returns nothing is a write, dropped while fenced.
private enum string forward(C, alias fun) = is(ReturnType!fun == void)
    ? "if (!writesAllowed()) return refuse(\"" ~ __traits(identifier, fun) ~ "\"); inner." ~ __traits(identifier, fun)
        ~ "(args);"
    : "return inner." ~ __traits(identifier, fun) ~ "(args);";

/// See the module documentation.
alias FencedDatabase = AutoImplement!(FencedBase, forward);

unittest
{
    import dmangos.world.database : MemoryWorldDatabase;
    import dmangos.world.testclient : newDatabase;

    auto inner = newDatabase();
    bool allowed = true;
    WorldDatabase db = new FencedDatabase(inner, () => allowed);
    db.setMuteTime(db.findAccount("PLAYER").get.id, 99);
    assert(db.findAccount("PLAYER").get.muteTime == 99, "writes go through while the lease holds");

    allowed = false;
    db.setMuteTime(db.findAccount("PLAYER").get.id, 7);
    assert(db.findAccount("PLAYER").get.muteTime == 99, "and are dropped once it lapsed");
    assert((cast(FencedBase) db).refused == 1);
    assert(!db.findAccount("PLAYER").isNull, "reads still work");
}
