/**
 * Extracts the client's DBC files.
 *
 * The archives `model`, `dbc`, `terrain`, `patch` and `patch-2` are opened
 * from the client's `Data` folder. Files are looked up newest archive
 * first, so patches win. Every `.dbc` named in an archive's `(listfile)` is
 * copied unchanged into `<output>/dbc/`, the layout dmangos's `data_dir`
 * expects.
 *
 * A patch entry of one byte or less (a "removed" placeholder)
 * is skipped with a warning instead of being written as an empty file.
 * Every extracted file is also checked to be a complete DBC.
 */
module dmangos.extractor.dbc;

import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, write;
import std.format : format;
import std.path : buildPath;
import std.string : toUpper;

import dmangos.dbc : dbcMagic;
import dmangos.mpq.archive;
import dmangos.mpq.crypt : readWord;

/// Archives searched, oldest first.
immutable string[] clientArchives = ["model.MPQ", "dbc.MPQ", "terrain.MPQ", "patch.MPQ", "patch-2.MPQ"];

/// What an extraction did.
struct ExtractionReport
{
    string[] archives;        /// archives opened, newest first
    size_t extracted;         /// files written
    size_t[string] perArchive; /// files taken from each archive
    string[] skipped;         /// names not written, with the reason
}

/// Opens those of `names` (oldest first) the client has, newest first.
MpqArchive[] openClientArchives(string clientDir, const(string)[] names = clientArchives)
{
    const data = buildPath(clientDir, "Data");
    enforce(exists(data),
        format!"'%s' has no Data folder; point the extractor at the client's main directory"(clientDir));
    MpqArchive[] archives;
    foreach_reverse (archive; names)
    {
        const path = buildPath(data, archive);
        if (exists(path))
            archives ~= MpqArchive.open(path);
    }
    enforce(archives.length, format!"no client archives found in '%s'"(data));
    return archives;
}

/// Extracts every DBC file named in the archives' listfiles from `archives` (newest first) into `<outputDir>/dbc`.
ExtractionReport extractDbcFiles(MpqArchive[] archives, string outputDir)
{
    import std.algorithm.searching : find;
    import std.range.primitives : empty, front;
    import std.uni : sicmp;

    ExtractionReport report;
    foreach (archive; archives)
        report.archives ~= archive.name;

    // The union of all listfiles, case-insensitively, keeping the newest archive's spelling.
    string[string] names;
    foreach (archive; archives)
        foreach (name; archive.listfile())
            if (name.length > 4 && sicmp(name[$ - 4 .. $], ".dbc") == 0)
                names.require(name.toUpper, name);

    const directory = buildPath(outputDir, "dbc");
    mkdirRecurse(directory);

    auto sorted = names.values;
    sorted.sort();
    foreach (name; sorted)
    {
        auto holders = archives.find!(archive => archive.contains(name));
        if (holders.empty)
        {
            report.skipped ~= name ~ ": listed but not present";
            continue;
        }
        auto source = holders.front;
        if (source.sizeOf(name) <= 1)
        {
            report.skipped ~= name ~ ": placeholder in " ~ source.name;
            continue;
        }

        const data = source.read(name);
        if (const problem = dbcProblem(data))
        {
            report.skipped ~= name ~ ": " ~ problem;
            continue;
        }
        write(buildPath(directory, baseName(name)), data);
        ++report.extracted;
        ++report.perArchive.require(source.name);
    }
    return report;
}

/// Why `data` is not a complete DBC file, or null if it is.
string dbcProblem(const(ubyte)[] data) pure @safe
{
    if (data.length < 20 || readWord(data, 0) != dbcMagic)
        return "not a DBC file";
    const expected = 20 + ulong(readWord(data, 1)) * readWord(data, 3) + readWord(data, 4);
    if (expected != data.length)
        return format!"truncated or padded: %s bytes, header says %s"(data.length, expected);
    return null;
}

/// The file name without directories (either slash).
string baseName(string name) pure nothrow @nogc @safe
{
    size_t start;
    foreach (i, c; name)
        if (c == '\\' || c == '/')
            start = i + 1;
    return name[start .. $];
}

unittest
{
    import std.file : read, remove, rmdirRecurse, tempDir;
    import std.string : representation;
    import dmangos.dbc : buildDbc;

    const uint[][] mapRows = [[0, 0], [1, 0]];
    const map = buildDbc("ni", mapRows);
    const oldSpell = buildDbc("n", [[1u]]);
    const newSpell = buildDbc("n", [[1u], [2u]]);

    // The base archive has Map and an old Spell; the patch replaces Spell and "removes" Gone.dbc.
    const base = MpqArchive.fromBytes(buildArchive([
        TestFile("(listfile)", "DBFilesClient\\Map.dbc\r\nDBFilesClient\\Spell.dbc\r\nInterface\\x.blp\r\n"
            .representation),
        TestFile("DBFilesClient\\Map.dbc", map, MpqFile.compress),
        TestFile("DBFilesClient\\Spell.dbc", oldSpell, MpqFile.compress),
        TestFile("DBFilesClient\\Broken.dbc", [1, 2, 3, 4, 5]),
    ]), "dbc.MPQ");
    const patch = MpqArchive.fromBytes(buildArchive([
        TestFile("(listfile)", "DBFilesClient\\spell.dbc;DBFilesClient\\Gone.dbc;DBFilesClient\\Broken.dbc"
            .representation),
        TestFile("DBFilesClient\\Spell.dbc", newSpell, MpqFile.compress | MpqFile.encrypted),
        TestFile("DBFilesClient\\Gone.dbc", [0]),
    ]), "patch.MPQ");

    const output = buildPath(tempDir, "dmangos-extract-test");
    scope (exit)
        if (exists(output))
            rmdirRecurse(output);

    const report = extractDbcFiles([cast() patch, cast() base], output);
    assert(report.extracted == 2);
    assert(read(buildPath(output, "dbc", "Map.dbc")) == map);
    assert(read(buildPath(output, "dbc", "spell.dbc")) == newSpell, "the patch wins, with its spelling");
    const size_t[string] expectedSources = ["dbc.MPQ": 1, "patch.MPQ": 1];
    assert(report.perArchive == expectedSources);
    assert(report.skipped.length == 2); // the placeholder and the broken file
    assert(!exists(buildPath(output, "dbc", "Gone.dbc")) && !exists(buildPath(output, "dbc", "Broken.dbc")));

    assert(dbcProblem(map) is null && dbcProblem(map[0 .. $ - 1]) !is null);
    assert(baseName("DBFilesClient\\Spell.dbc") == "Spell.dbc");
}
