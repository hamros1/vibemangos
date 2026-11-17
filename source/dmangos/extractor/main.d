/**
 * Entry point of the client data extractor.
 *
 * ---
 * extractor [-i CLIENT] [-o OUTPUT] [-e MASK]
 * ---
 *
 * Reads the 1.12 client's MPQ archives from `CLIENT/Data` and writes the
 * DBC files to `OUTPUT/dbc` and the terrain to `OUTPUT/maps`, as CMaNGOS's
 * `ad` does, and on request the buildings to `OUTPUT/vmaps`, as its
 * `vmap_extractor` and `vmap_assembler` do (the raw extraction stays in
 * `OUTPUT/Buildings`). Point the world server's `data_dir` (or mangosd's
 * `DataDir`) at `OUTPUT`.
 */
module dmangos.extractor.main;

import std.getopt : defaultGetoptPrinter, getopt, GetOptException, GetoptResult;
import std.stdio : stderr, writefln, writeln;

import dmangos.extractor.assembler;
import dmangos.extractor.dbc;
import dmangos.extractor.maps;
import dmangos.extractor.vmaps;
import dmangos.extractor.mmaps : buildMovementMaps;
import dmangos.log;

private enum usage = "dmangos client data extractor

Extracts the DBC files and the terrain of a 1.12 client into OUTPUT/dbc and OUTPUT/maps,
with -e 4 its buildings into OUTPUT/vmaps (by way of OUTPUT/Buildings), and with -e 8 movement
maps into OUTPUT/mmaps (from OUTPUT/maps and OUTPUT/vmaps), for the world server's data_dir.

Usage:
  extractor [-i CLIENT] [-o OUTPUT] [-e MASK]
";

/// What to extract, CMaNGOS's `-e` mask (`Extract`).
enum Extract : uint
{
    maps = 1,
    dbc = 2,
    vmaps = 4,
    mmaps = 8,
}

int main(string[] args)
{
    string input = ".", output = ".";
    uint extract = Extract.maps | Extract.dbc;
    uint[] mapIds;
    GetoptResult options;
    try
        options = getopt(args, "input|i", "Client directory, the one containing Data/ (default: .)", &input,
            "output|o", "Output directory; dbc/ and maps/ are created in it (default: .)", &output,
            "extract|e", "What to extract, added up: 1 maps, 2 DBC files, 4 vmaps, 8 movement maps (default: 3)",
                &extract,
            "map", "With -e 8: build only this map's movement maps (repeat for more)", &mapIds);
    catch (GetOptException e)
    {
        stderr.writeln(e.msg);
        return 2;
    }
    if (options.helpWanted || args.length > 1)
    {
        defaultGetoptPrinter(usage, options.options);
        return options.helpWanted ? 0 : 2;
    }

    try
    {
        if (extract == Extract.mmaps) // from what the other steps wrote: no archives needed
            return buildMmaps(output, mapIds);
        auto archives = openClientArchives(input);
        scope (exit)
            foreach (archive; archives)
                archive.close();

        writeln("Archives (newest first):");
        foreach (archive; archives)
            writefln("  %s", archive.name);
        if (extract & Extract.dbc)
        {
            const report = extractDbcFiles(archives, output);
            foreach (skipped; report.skipped)
                warning!"skipped %s"(skipped);
            writefln("Extracted %s DBC files to %s/dbc", report.extracted, output);
            foreach (archive, count; report.perArchive)
                writefln("  %4s from %s", count, archive);
        }
        if (extract & Extract.maps)
        {
            const report = extractMaps(archives, output, (string line) { writefln("  %s", line); });
            foreach (problem; report.problems)
                warning!"%s"(problem);
            writefln("Extracted %s tiles of %s maps to %s/maps", report.tiles, report.maps, output);
        }
        if (extract & Extract.vmaps)
        {
            auto vmapSources = openClientArchives(input, vmapArchives);
            scope (exit)
                foreach (archive; vmapSources)
                    archive.close();
            void delegate(string) print = (string line) { writefln("  %s", line); };
            const raw = extractVmapData(vmapSources, output, print);
            writefln("Extracted %s buildings and %s doodads, %s placements, to %s/Buildings", raw.wmos, raw.models,
                raw.spawns, output);
            if (raw.missing.length)
                writefln("  %s models placed but not in the archives (a few are expected)", raw.missing.length);
            const built = assembleVmaps(output, print);
            foreach (problem; built.problems)
                warning!"%s"(problem);
            writefln("Assembled %s maps, %s tiles and %s models to %s/vmaps", built.maps, built.tiles, built.models,
                output);
        }
        if (extract & Extract.mmaps)
            return buildMmaps(output, mapIds);
        return 0;
    }
    catch (Exception e)
    {
        error!"%s"(e.msg);
        return 1;
    }
}

/// Movement maps from OUTPUT/maps and OUTPUT/vmaps into OUTPUT/mmaps.
private int buildMmaps(string output, const(uint)[] mapIds)
{
    import core.time : MonoTime;

    const started = MonoTime.currTime;
    const report = buildMovementMaps(output, mapIds, (string line) { writefln("  %s", line); });
    foreach (problem; report.problems)
        warning!"%s"(problem);
    writefln("Built movement maps for %s tiles of %s maps to %s/mmaps (%s tiles with nothing walkable) in %s",
        report.tiles, report.maps, output, report.empty, MonoTime.currTime - started);
    return report.problems.length ? 1 : 0;
}
