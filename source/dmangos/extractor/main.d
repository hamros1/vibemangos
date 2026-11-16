/**
 * Entry point of the client data extractor.
 *
 * ---
 * extractor [-i CLIENT] [-o OUTPUT]
 * ---
 *
 * Reads the 1.12 client's MPQ archives from `CLIENT/Data` and writes the
 * DBC files to `OUTPUT/dbc`. Point the world server's `data_dir` (or
 * mangosd's `DataDir`) at `OUTPUT`.
 */
module dmangos.extractor.main;

import std.getopt : defaultGetoptPrinter, getopt, GetOptException, GetoptResult;
import std.stdio : stderr, writefln, writeln;

import dmangos.extractor.dbc;
import dmangos.log;

private enum usage = "dmangos client data extractor

Extracts the DBC files from a 1.12 client into OUTPUT/dbc, for the world server's data_dir.

Usage:
  extractor [-i CLIENT] [-o OUTPUT]
";

int main(string[] args)
{
    string input = ".", output = ".";
    GetoptResult options;
    try
        options = getopt(args, "input|i", "Client directory, the one containing Data/ (default: .)", &input,
            "output|o", "Output directory; dbc/ is created in it (default: .)", &output);
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
        auto archives = openClientArchives(input);
        scope (exit)
            foreach (archive; archives)
                archive.close();

        writeln("Archives (newest first):");
        foreach (archive; archives)
            writefln("  %s", archive.name);
        const report = extractDbcFiles(archives, output);
        foreach (skipped; report.skipped)
            warning!"skipped %s"(skipped);
        writefln("Extracted %s DBC files to %s/dbc", report.extracted, output);
        foreach (archive, count; report.perArchive)
            writefln("  %4s from %s", count, archive);
        return 0;
    }
    catch (Exception e)
    {
        error!"%s"(e.msg);
        return 1;
    }
}
