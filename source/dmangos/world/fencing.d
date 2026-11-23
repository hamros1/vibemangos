/**
 * Fencing of the databases (docs/CLUSTER.md): a cluster node whose lease has lapsed must not
 * write anything, because by the time the coordinator gives its accounts and regions to other nodes it
 * has certainly stopped, and anything it wrote after that could overwrite theirs.
 *
 * `FencedDatabase` wraps the world server's `WorldDatabase` and forwards every call, except that while
 * `writesAllowed` says no, writes (identified by the database interface) are dropped and
 * counted. It is generated from the interface (`std.typecons.AutoImplement`), so a method added there
 * is fenced without anyone remembering to.
 */
module dmangos.world.fencing;

import std.traits : hasUDA, ReturnType;
import std.typecons : AutoImplement;

import dmangos.world.database : DatabaseRead, DatabaseWrite, WorldDatabase;

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

// Void methods default to writes. A result alone cannot distinguish reads from synchronous writes.
private template forward(C, alias fun)
{
    enum reads = hasUDA!(fun, DatabaseRead);
    enum writes = hasUDA!(fun, DatabaseWrite);
    enum returnsVoid = is(ReturnType!fun == void);
    static assert(!(reads && writes) && (returnsVoid || reads || writes),
        __traits(identifier, fun) ~ " must declare its database access");

    enum name = __traits(identifier, fun);
    static if (reads)
        enum guard = "";
    else static if (returnsVoid)
        enum guard = "if (!writesAllowed()) return refuse(\"" ~ name ~ "\"); ";
    else
        enum guard = "if (!writesAllowed()) { refuse(\"" ~ name ~ "\"); return typeof(return).init; } ";
    enum forward = guard ~ "return inner." ~ name ~ "(args);";
}

/// See the module documentation.
alias FencedDatabase = AutoImplement!(FencedBase, forward);

unittest
{
    import dmangos.world.gameobject : GameObjectSpawn;
    import dmangos.world.database : MemoryWorldDatabase;
    import dmangos.world.auctionhouse : AuctionRecord;
    import dmangos.world.testclient : newDatabase;

    auto inner = newDatabase();
    bool allowed = true;
    WorldDatabase db = new FencedDatabase(inner, () => allowed);
    db.setMuteTime(db.findAccount("PLAYER").get.id, 99);
    assert(db.findAccount("PLAYER").get.muteTime == 99, "writes go through while the lease holds");

    AuctionRecord auction;
    auction.id = 1;
    inner.insertAuction(auction);
    assert(db.reserveTemporaryCounters(1, 1024).get == 0);

    allowed = false;
    db.setMuteTime(db.findAccount("PLAYER").get.id, 7);
    assert(db.findAccount("PLAYER").get.muteTime == 99, "and are dropped once it lapsed");
    assert((cast(FencedBase) db).refused == 1);
    const spawn = GameObjectSpawn.init;
    assert(db.createGameObjectSpawn(spawn) == 0 && inner.gameObjectSpawnRows.length == 0);
    assert(!db.bidOnAuction(auction.id, 0, 0, 7, 10));
    assert(!db.deleteAuction(auction.id, 0));
    assert(db.auctionById(auction.id).get.bid == 0);
    assert(db.reserveTemporaryCounters(1, 1024).isNull);
    assert(!db.findAccount("PLAYER").isNull, "reads still work");
}
