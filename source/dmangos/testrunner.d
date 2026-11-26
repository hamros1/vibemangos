/**
 * The unit-test runner of the test binary (tools/harness/check.sh): the default one, but able to run a part of the
 * modules, so one change's tests, or one of several processes sharing the real-data run, need not run them all.
 *
 *   DMANGOS_TEST_MODULES  comma-separated module names or prefixes ending in '.' (dmangos.world.realscripts_raids,
 *                         dmangos.cluster.): only the modules they name
 *   DMANGOS_TEST_SHARD    i/n: only every n-th module with tests, from the i-th (0-based), after the filter above
 *   DMANGOS_TEST_TIMES    a file to append each module's name and seconds to
 *
 * Unset, every module runs, as with druntime's own runner, and the summary is druntime's.
 */
module dmangos.testrunner;

version (unittest):

import core.runtime : Runtime, UnitTestResult;

shared static this()
{
    Runtime.extendedModuleUnitTester = &runModules;
}

private UnitTestResult runModules()
{
    import core.time : MonoTime;
    import std.algorithm.iteration : filter, map, splitter;
    import std.algorithm.searching : any, endsWith, startsWith;
    import std.array : array;
    import std.conv : to;
    import std.process : environment;
    import std.stdio : File, stderr;
    import std.string : strip;

    const wanted = environment.get("DMANGOS_TEST_MODULES", "").splitter(',').map!strip.filter!(m => m.length).array;
    size_t shard, shards = 1;
    const s = environment.get("DMANGOS_TEST_SHARD", "");
    if (s.length)
    {
        auto parts = s.splitter('/').array;
        shard = parts[0].to!size_t;
        shards = parts[1].to!size_t;
    }
    const timesPath = environment.get("DMANGOS_TEST_TIMES", "");

    bool matches(string name, string pattern)
    {
        return pattern.endsWith(".") ? name.startsWith(pattern) : name == pattern;
    }

    foreach (pattern; wanted)
    {
        bool found;
        foreach (m; ModuleInfo)
            if (m !is null && m.unitTest !is null && matches(m.name, pattern))
            {
                found = true;
                break;
            }
        if (!found)
        {
            stderr.writeln("No unit-test module matches ", pattern);
            return UnitTestResult(1, 0, false, false);
        }
    }

    UnitTestResult result;
    size_t index;
    foreach (m; ModuleInfo)
    {
        if (m is null)
            continue;
        auto test = m.unitTest;
        if (test is null || (wanted.length && !wanted.any!(w => matches(m.name, w))))
            continue;
        if (index++ % shards != shard)
            continue;
        ++result.executed;
        const start = MonoTime.currTime;
        try
        {
            test();
            ++result.passed;
        }
        catch (Throwable error)
        {
            stderr.writeln(error);
        }
        if (timesPath.length)
            File(timesPath, "a").writefln("%s %.2f", m.name, (MonoTime.currTime - start).total!"msecs" / 1000.0);
    }
    result.runMain = false;
    result.summarize = true;
    return result;
}
