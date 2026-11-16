/**
 * The layout of CMaNGOS's `.map` terrain files (`GridMapDefines.h`), shared by the extractor that
 * writes them (`dmangos.extractor.maps`) and the world server that reads them
 * (`dmangos.world.terrain`).
 *
 * A file starts with a header of ten `uint`s: the magic "MAPS", the version "z1.4", then the
 * offset and size of the area, height, liquid and hole parts. Each part but the holes starts with
 * its own magic and flags; see the extractor for what follows them.
 */
module dmangos.mapfile;

/// The four-character codes, as the file stores them (`*(uint32*)"MAPS"`).
enum uint mapMagic = fourCC("MAPS"), mapVersionMagic = fourCC("z1.4"), mapAreaMagic = fourCC("AREA"),
    mapHeightMagic = fourCC("MHGT"), mapLiquidMagic = fourCC("MLIQ");

/// A code read as a little-endian `uint`, the way the C++ code casts the string.
uint fourCC(string code) pure @safe
in (code.length == 4)
{
    return code[0] | code[1] << 8 | code[2] << 16 | code[3] << 24;
}

enum : uint
{
    mapAreaNoArea = 0x0001,     /// `MAP_AREA_NO_AREA`: one area for the whole tile
    mapHeightNoHeight = 0x0001, /// `MAP_HEIGHT_NO_HEIGHT`: one height for the whole tile
    mapHeightAsInt16 = 0x0002,  /// `MAP_HEIGHT_AS_INT16`
    mapHeightAsInt8 = 0x0004,   /// `MAP_HEIGHT_AS_INT8`
    mapLiquidNoType = 0x01,     /// `MAP_LIQUID_NO_TYPE`: one liquid for the whole tile
    mapLiquidNoHeight = 0x02,   /// `MAP_LIQUID_NO_HEIGHT`: one liquid level for the whole tile
}

/// `MAP_LIQUID_TYPE_*`
enum : ubyte
{
    mapLiquidTypeMagma = 0x01,
    mapLiquidTypeOcean = 0x02,
    mapLiquidTypeSlime = 0x04,
    mapLiquidTypeWater = 0x08,
    mapLiquidTypeDeepWater = 0x10,
}

