/**
 * Read-only access to MPQ archives (format version 0, as used by the 1.x client).
 *
 * The header, the encrypted hash and block tables and the file sectors are
 * read straight from the file on demand, so multi-gigabyte archives cost
 * almost no memory to open. Files may be stored plain, encrypted
 * (optionally with the "fix key" adjustment), as one unit or as sectors, and
 * compressed with zlib or PKWare DCL. Those are the encodings 1.12 uses for
 * its data files. Huffman, ADPCM and bzip2, used for sound files and by
 * later clients, are reported as unsupported.
 */
module dmangos.mpq.archive;

import std.algorithm.comparison : min;
import std.algorithm.iteration : map;
import std.array : array;
import std.exception : basicExceptionCtors, enforce;
import std.format : format;
import std.stdio : File;

import dmangos.mpq.crypt;
import dmangos.mpq.explode : explode;

/// Thrown for unreadable archives, missing files and unsupported encodings.
class MpqException : Exception
{
    mixin basicExceptionCtors;
}

/// Block flags (`MPQ_FILE_*`).
enum MpqFile : uint
{
    implode = 0x00000100,
    compress = 0x00000200,
    encrypted = 0x00010000,
    fixKey = 0x00020000,
    singleUnit = 0x01000000,
    deleteMarker = 0x02000000,
    sectorCrc = 0x04000000,
    exists = 0x80000000,
}

/// Compression types named in a sector's first byte.
private enum Compression : ubyte
{
    huffman = 0x01,
    zlib = 0x02,
    pkware = 0x08,
    bzip2 = 0x10,
    adpcmMono = 0x40,
    adpcmStereo = 0x80,
}

/// The header's signature, "MPQ\x1A", and that of the user data block that may precede it, "MPQ\x1B".
private enum uint headerMagic = 0x1A51504D, userDataMagic = 0x1B51504D;

private enum uint hashEntryEmpty = 0xFFFFFFFF, hashEntryDeleted = 0xFFFFFFFE;

private struct HashEntry
{
    uint nameA;
    uint nameB;
    ushort locale;
    ushort platform;
    uint blockIndex;
}

private struct BlockEntry
{
    uint offset;
    uint packedSize;
    uint unpackedSize;
    uint flags;
}

/// Where archive bytes come from: a file on disk, or memory in tests.
private interface ByteSource
{
    ubyte[] read(ulong offset, size_t length);
    @property ulong length();
    void close();
}

private final class FileSource : ByteSource
{
    private File file;

    this(string path)
    {
        file = File(path, "rb");
    }

    ubyte[] read(ulong offset, size_t length)
    {
        enforce!MpqException(offset + length <= this.length, format!"read past the end of %s"(file.name));
        auto buffer = new ubyte[length];
        file.seek(offset);
        enforce!MpqException(file.rawRead(buffer).length == length, "short read from " ~ file.name);
        return buffer;
    }

    @property ulong length()
    {
        return file.size;
    }

    void close()
    {
        file.close();
    }
}

private final class MemorySource : ByteSource
{
    private const(ubyte)[] bytes;

    this(const(ubyte)[] bytes)
    {
        this.bytes = bytes;
    }

    ubyte[] read(ulong offset, size_t length)
    {
        enforce!MpqException(offset + length <= bytes.length, "read past the end of the archive");
        return bytes[cast(size_t) offset .. cast(size_t)(offset + length)].dup;
    }

    @property ulong length()
    {
        return bytes.length;
    }

    void close()
    {
    }
}

/// One open archive. See the module documentation.
final class MpqArchive
{
    /// The path (or name) the archive was opened from.
    immutable string name;

    private ByteSource source;
    private ulong base;
    private uint sectorSize;
    private HashEntry[] hashes;
    private BlockEntry[] blocks;

    private this(ByteSource source, string name)
    {
        this.source = source;
        this.name = name;
        readHeader();
    }

    /// Opens an archive file.
    static MpqArchive open(string path)
    {
        auto source = new FileSource(path);
        scope (failure)
            source.close();
        return new MpqArchive(source, path);
    }

    /// Opens an archive held in memory.
    static MpqArchive fromBytes(const(ubyte)[] bytes, string name = "(memory)")
    {
        return new MpqArchive(new MemorySource(bytes), name);
    }

    /// Releases the file. The archive cannot be used afterwards.
    void close()
    {
        source.close();
    }

    /// Whether the archive has `file` (and it is not a deletion marker).
    bool contains(scope const(char)[] file)
    {
        if (const block = find(file))
            return !(block.flags & MpqFile.deleteMarker);
        return false;
    }

    /// The unpacked size of `file`.
    uint sizeOf(scope const(char)[] file)
    {
        const block = find(file);
        enforce!MpqException(block !is null, format!"%s: no file '%s'"(name, file));
        return block.unpackedSize;
    }

    /// The names listed in the archive's `(listfile)`, or nothing if it has none.
    string[] listfile()
    {
        if (!contains("(listfile)"))
            return null;
        return splitList(cast(const(char)[]) read("(listfile)")).map!(line => line.idup).array;
    }

    /// Reads and decodes `file`.
    ubyte[] read(scope const(char)[] file)
    {
        const block = find(file);
        enforce!MpqException(block !is null && !(block.flags & MpqFile.deleteMarker),
            format!"%s: no file '%s'"(name, file));
        const flags = block.flags;
        enforce!MpqException((flags & MpqFile.exists) != 0, format!"%s: '%s' is not marked as existing"(name, file));
        if (block.unpackedSize == 0)
            return null;

        const encrypted = (flags & MpqFile.encrypted) != 0;
        const key = encrypted ? fileKey(file, block.offset, block.unpackedSize, (flags & MpqFile.fixKey) != 0) : 0;
        const start = base + block.offset;
        const compressed = (flags & (MpqFile.compress | MpqFile.implode)) != 0;

        if (flags & MpqFile.singleUnit)
        {
            auto data = source.read(start, block.packedSize);
            if (encrypted)
                decryptBlock(data, key);
            if (compressed && block.packedSize < block.unpackedSize)
                data = decompress(data, block.unpackedSize, flags, file);
            return data;
        }

        const sectors = (block.unpackedSize + sectorSize - 1) / sectorSize;
        ubyte[] output;
        output.reserve(block.unpackedSize);
        if (!compressed)
        {
            foreach (i; 0 .. sectors)
            {
                const length = min(sectorSize, block.unpackedSize - i * sectorSize);
                auto sector = source.read(start + i * sectorSize, length);
                if (encrypted)
                    decryptBlock(sector, key + i);
                output ~= sector;
            }
            return output;
        }

        const tableEntries = sectors + 1 + ((flags & MpqFile.sectorCrc) ? 1 : 0);
        auto table = source.read(start, tableEntries * 4);
        if (encrypted)
            decryptBlock(table, key - 1);
        foreach (i; 0 .. sectors)
        {
            const from = readWord(table, i), to = readWord(table, i + 1);
            enforce!MpqException(to >= from && to <= block.packedSize,
                format!"%s: corrupt sector table in '%s'"(name, file));
            auto sector = source.read(start + from, to - from);
            if (encrypted)
                decryptBlock(sector, key + i);
            const expected = min(sectorSize, block.unpackedSize - i * sectorSize);
            output ~= sector.length < expected ? decompress(sector, expected, flags, file) : sector;
        }
        enforce!MpqException(output.length == block.unpackedSize, format!"%s: '%s' unpacked to %s bytes, not %s"(name,
            file, output.length, block.unpackedSize));
        return output;
    }

private:
    void readHeader()
    {
        // The header starts on a 512-byte boundary, possibly after a user data block ("MPQ\x1B").
        for (ulong offset = 0; offset + 32 <= source.length; offset += 512)
        {
            const probe = source.read(offset, 16);
            const magic = readWord(probe, 0);
            if (magic == userDataMagic)
            {
                base = offset + readWord(probe, 2);
                break;
            }
            if (magic == headerMagic)
            {
                base = offset;
                break;
            }
            enforce!MpqException(offset + 512 + 32 <= source.length, name ~ ": not an MPQ archive");
        }

        const header = source.read(base, 32);
        enforce!MpqException(readWord(header, 0) == headerMagic, name ~ ": not an MPQ archive");
        const sectorShift = header[14] | header[15] << 8;
        sectorSize = 512u << sectorShift;
        const hashTablePos = readWord(header, 4), blockTablePos = readWord(header, 5);
        const hashCount = readWord(header, 6), blockCount = readWord(header, 7);
        enforce!MpqException(hashCount > 0, name ~ ": empty hash table");

        auto hashBytes = source.read(base + hashTablePos, hashCount * 16);
        decryptBlock(hashBytes, hashString("(hash table)", HashType.fileKey));
        hashes = new HashEntry[hashCount];
        foreach (i, ref entry; hashes)
            entry = HashEntry(readWord(hashBytes, i * 4), readWord(hashBytes, i * 4 + 1),
                cast(ushort) readWord(hashBytes, i * 4 + 2), cast(ushort)(readWord(hashBytes, i * 4 + 2) >> 16),
                readWord(hashBytes, i * 4 + 3));

        auto blockBytes = source.read(base + blockTablePos, blockCount * 16);
        decryptBlock(blockBytes, hashString("(block table)", HashType.fileKey));
        blocks = new BlockEntry[blockCount];
        foreach (i, ref entry; blocks)
            entry = BlockEntry(readWord(blockBytes, i * 4), readWord(blockBytes, i * 4 + 1),
                readWord(blockBytes, i * 4 + 2), readWord(blockBytes, i * 4 + 3));
    }

    /// The block of `file`, preferring the locale-neutral entry, or null.
    const(BlockEntry)* find(scope const(char)[] file) const
    {
        const nameA = hashString(file, HashType.nameA), nameB = hashString(file, HashType.nameB);
        const startIndex = hashString(file, HashType.tableOffset) % hashes.length;
        const(BlockEntry)* fallback;
        size_t index = startIndex;
        do
        {
            const entry = hashes[index];
            if (entry.blockIndex == hashEntryEmpty)
                break;
            if (entry.nameA == nameA && entry.nameB == nameB && entry.blockIndex != hashEntryDeleted
                && entry.blockIndex < blocks.length)
            {
                if (entry.locale == 0)
                    return &blocks[entry.blockIndex];
                if (fallback is null)
                    fallback = &blocks[entry.blockIndex];
            }
            index = (index + 1) % hashes.length;
        }
        while (index != startIndex);
        return fallback;
    }

    ubyte[] decompress(ubyte[] data, size_t expected, uint flags, scope const(char)[] file)
    {
        import std.zlib : uncompress, ZlibException;

        if (flags & MpqFile.implode)
            return explode(data, expected);

        enforce!MpqException(data.length > 0, format!"%s: empty compressed sector in '%s'"(name, file));
        const mask = data[0];
        ubyte[] payload = data[1 .. $];
        const unsupported = mask & ~(Compression.zlib | Compression.pkware);
        enforce!MpqException(!unsupported, format!"%s: '%s' uses an unsupported compression (0x%02X)"(name, file,
            mask));
        if (mask & Compression.pkware)
            payload = explode(payload, expected);
        if (mask & Compression.zlib)
        {
            try
                payload = cast(ubyte[]) uncompress(payload, expected);
            catch (ZlibException e)
                throw new MpqException(format!"%s: '%s' has corrupt zlib data: %s"(name, file, e.msg));
        }
        return payload;
    }

}

/// Splits a `(listfile)` into names: one per line, `;` also separates, blanks ignored.
const(char)[][] splitList(const(char)[] text) pure @safe
{
    const(char)[][] names;
    size_t start;
    foreach (i; 0 .. text.length + 1)
    {
        if (i == text.length || text[i] == '\n' || text[i] == '\r' || text[i] == ';')
        {
            if (i > start)
                names ~= text[start .. i];
            start = i + 1;
        }
    }
    return names;
}

// ---------------------------------------------------------------------------
// A small archive writer, for tests.
// ---------------------------------------------------------------------------

version (unittest)
{
    /// A file to put into a test archive.
    struct TestFile
    {
        string name;
        const(ubyte)[] data;
        uint flags; /// `MpqFile` bits: compress, encrypted, fixKey, singleUnit; or `preImploded` (see below)
        const(ubyte)[] imploded; /// already PKWare-compressed data, stored with MPQ_FILE_IMPLODE as one unit
    }

    /// Builds an MPQ archive the way Blizzard's tools lay them out, with zlib for compressed files.
    ubyte[] buildArchive(const(TestFile)[] files, ushort sectorShift = 3)
    {
        import std.bitmanip : nativeToLittleEndian;
        import std.zlib : compress;

        const sectorSize = 512u << sectorShift;
        ubyte[] body;
        BlockEntry[] blockTable;
        void put32(ref ubyte[] buffer, uint value)
        {
            buffer ~= nativeToLittleEndian(value)[];
        }

        foreach (file; files)
        {
            const offset = cast(uint)(32 + body.length);
            uint flags = file.flags | MpqFile.exists;
            ubyte[] stored;
            if (file.imploded.length)
            {
                flags |= MpqFile.implode | MpqFile.singleUnit;
                stored = file.imploded.dup;
            }
            else if (flags & MpqFile.singleUnit)
            {
                stored = file.data.dup;
                if (flags & MpqFile.compress)
                {
                    auto packed = cast(ubyte[]) compress(file.data);
                    if (packed.length + 1 < file.data.length)
                        stored = [ubyte(Compression.zlib)] ~ packed;
                }
            }
            else
            {
                const count = (file.data.length + sectorSize - 1) / sectorSize;
                ubyte[][] sectors;
                foreach (i; 0 .. count)
                {
                    auto plain = file.data[i * sectorSize .. min((i + 1) * sectorSize, file.data.length)].dup;
                    if (flags & MpqFile.compress)
                    {
                        auto packed = cast(ubyte[]) compress(plain);
                        if (packed.length + 1 < plain.length)
                            plain = [ubyte(Compression.zlib)] ~ packed;
                    }
                    sectors ~= plain;
                }
                const key = fileKey(file.name, offset, cast(uint) file.data.length, (flags & MpqFile.fixKey) != 0);
                if (flags & MpqFile.encrypted)
                    foreach (i, ref sector; sectors)
                        encryptBlock(sector, cast(uint)(key + i));
                if (flags & MpqFile.compress)
                {
                    ubyte[] table;
                    uint position = cast(uint)((count + 1) * 4);
                    put32(table, position);
                    foreach (sector; sectors)
                    {
                        position += cast(uint) sector.length;
                        put32(table, position);
                    }
                    if (flags & MpqFile.encrypted)
                        encryptBlock(table, key - 1);
                    stored = table;
                }
                foreach (sector; sectors)
                    stored ~= sector;
            }
            if ((flags & MpqFile.singleUnit) && (flags & MpqFile.encrypted))
                encryptBlock(stored, fileKey(file.name, offset, cast(uint) file.data.length,
                    (flags & MpqFile.fixKey) != 0));
            blockTable ~= BlockEntry(offset, cast(uint) stored.length, cast(uint) file.data.length, flags);
            body ~= stored;
        }

        uint hashCount = 16;
        while (hashCount < files.length * 2)
            hashCount *= 2;
        auto hashTable = new HashEntry[hashCount];
        hashTable[] = HashEntry(hashEntryEmpty, hashEntryEmpty, 0xFFFF, 0xFFFF, hashEntryEmpty);
        foreach (i, file; files)
        {
            auto index = hashString(file.name, HashType.tableOffset) % hashCount;
            while (hashTable[index].blockIndex != hashEntryEmpty)
                index = (index + 1) % hashCount;
            hashTable[index] = HashEntry(hashString(file.name, HashType.nameA), hashString(file.name, HashType.nameB),
                0, 0, cast(uint) i);
        }

        ubyte[] hashBytes, blockBytes;
        foreach (entry; hashTable)
        {
            put32(hashBytes, entry.nameA);
            put32(hashBytes, entry.nameB);
            put32(hashBytes, entry.locale | entry.platform << 16);
            put32(hashBytes, entry.blockIndex);
        }
        foreach (entry; blockTable)
        {
            put32(blockBytes, entry.offset);
            put32(blockBytes, entry.packedSize);
            put32(blockBytes, entry.unpackedSize);
            put32(blockBytes, entry.flags);
        }
        encryptBlock(hashBytes, hashString("(hash table)", HashType.fileKey));
        encryptBlock(blockBytes, hashString("(block table)", HashType.fileKey));

        ubyte[] header;
        put32(header, headerMagic);
        put32(header, 32);
        const hashPos = cast(uint)(32 + body.length);
        const blockPos = cast(uint)(hashPos + hashBytes.length);
        put32(header, cast(uint)(blockPos + blockBytes.length));
        header ~= [ubyte(0), 0, cast(ubyte) sectorShift, cast(ubyte)(sectorShift >> 8)];
        put32(header, hashPos);
        put32(header, blockPos);
        put32(header, hashCount);
        put32(header, cast(uint) blockTable.length);
        return header ~ body ~ hashBytes ~ blockBytes;
    }
}

unittest
{
    import std.exception : assertThrown;
    import std.string : representation;

    auto big = new ubyte[10_000];
    foreach (i, ref b; big)
        b = cast(ubyte)(i % 7 == 0 ? i : 0x41); // compressible, but not trivially
    auto random = new ubyte[5000];
    uint state = 12345;
    foreach (ref b; random)
        b = cast(ubyte)((state = state * 1103515245 + 12345) >> 16); // incompressible

    const files = [
        TestFile("(listfile)", "DBFilesClient\\Map.dbc\r\nDBFilesClient\\Spell.dbc;Sound\\x.wav\r\n".representation),
        TestFile("DBFilesClient\\Map.dbc", big, MpqFile.compress),
        TestFile("DBFilesClient\\Spell.dbc", big, MpqFile.compress | MpqFile.encrypted | MpqFile.fixKey),
        TestFile("Plain\\Random.bin", random, MpqFile.encrypted),
        TestFile("Single\\Unit.txt", big, MpqFile.singleUnit | MpqFile.compress | MpqFile.encrypted),
        TestFile("Imploded\\Example.txt", "AIAIAIAIAIAIA".representation, 0,
            [0x00, 0x04, 0x82, 0x24, 0x25, 0x8F, 0x80, 0x7F]),
    ];
    auto archive = MpqArchive.fromBytes(buildArchive(files));

    assert(archive.listfile() == ["DBFilesClient\\Map.dbc", "DBFilesClient\\Spell.dbc", "Sound\\x.wav"]);
    assert(archive.read("DBFilesClient\\Map.dbc") == big);
    assert(archive.read("dbfilesclient/SPELL.DBC") == big, "names are case-insensitive, either slash");
    assert(archive.read("Plain\\Random.bin") == random);
    assert(archive.read("Single\\Unit.txt") == big);
    assert(archive.read("Imploded\\Example.txt") == "AIAIAIAIAIAIA".representation);
    assert(archive.sizeOf("DBFilesClient\\Map.dbc") == big.length);
    assert(archive.contains("DBFilesClient\\Map.dbc") && !archive.contains("Sound\\x.wav"));
    assertThrown!MpqException(archive.read("Missing.dbc"));
    assertThrown!MpqException(MpqArchive.fromBytes(new ubyte[600]));
}
