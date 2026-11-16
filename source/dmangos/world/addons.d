/**
 * The addon list in `CMSG_AUTH_SESSION`, and the `SMSG_ADDON_INFO` reply.
 *
 * The client sends a zlib-compressed list of its addons, and a reply must
 * come back before it continues. As in CMaNGOS's default anticheat
 * (`Anticheat.hpp`, `ReadAddonInfo`), every addon is accepted. Addons
 * whose CRC differs from Blizzard's standard one get the public key the
 * client checks addon signatures with.
 *
 * Each entry is `name\0`, `uint8` flags, `uint32` CRC, `uint32` unknown.
 * CMaNGOS reads it shifted by one byte and compares against `0x1C776D01`;
 * that is the same standard CRC, `0x4C1C776D`, read correctly here.
 */
module dmangos.world.addons;

import std.exception : enforce;

import dmangos.bytes;
import dmangos.hex : hexLiteral;

/// CRC of Blizzard's own signed addons.
enum uint standardAddonCrc = 0x4C1C776D;

/// Largest uncompressed addon list accepted (CMaNGOS: `0xFFFFF`).
enum maxAddonDataSize = 0xFFFFF;

/// The addon-signing public key sent for non-standard addons, decoded at compile time.
static immutable ubyte[256] addonPublicKey = hexLiteral!(
    "C35B5084B93E32428CD0C748FA0E5D545AA30E14BA9E0DB95D8BEEB684934575FF31FE2F643F3D6D07D9449B40855934"
    ~ "4E10E1E74369EF7C16FCB4ED1B9528A82376513157302B790850101C4A1A2CC88B8F052D223DDB5A247A0F1350378F5A"
    ~ "CC9E04440E8701D4A315941634C6C2C3FB49FEE1F9DA8C503CBE2CBB57ED46B9AD8BC6DF0ED60FBE80B38B1E77CFAD22"
    ~ "CFB74BCFFBF06B11452D7A8118F2927E98565D5E69720A0D030A85A2859CCBFB566E8F44BB8F0222686397BC85BAA8F7"
    ~ "B540683C77866F4BD788CA8AD7CE36F0456ED564790F17FC64DD106FF3F5E0A6C3FB1B8C29EF8EE534CBD12ACE79C39A"
    ~ "0D36EA01E0AA912054F072D81EC789D2");

/// One addon the client reported.
struct ClientAddon
{
    string name;
    ubyte flags;
    uint crc;
    uint unknown;
}

/**
 * Decodes the addon block at the end of `CMSG_AUTH_SESSION`.
 *
 * Throws: `PacketException` if it is empty, oversized or not valid zlib
 * data. A real client never sends that, and CMaNGOS disconnects.
 */
ClientAddon[] parseAddons(const(ubyte)[] block)
{
    import std.zlib : uncompress, ZlibException;

    auto reader = ByteReader(block);
    const size = reader.read!uint;
    enforce!PacketException(size > 0 && size <= maxAddonDataSize, "addon data has an invalid size");

    ubyte[] unpacked;
    try
        unpacked = cast(ubyte[]) uncompress(reader.readBytes(reader.remaining), size);
    catch (ZlibException e)
        throw new PacketException("addon data is not valid zlib: " ~ e.msg);
    enforce!PacketException(unpacked.length == size, "addon data has the wrong uncompressed size");

    auto entries = ByteReader(unpacked);
    ClientAddon[] addons;
    while (!entries.empty)
    {
        ClientAddon addon;
        addon.name = entries.readCString();
        addon.flags = entries.read!ubyte;
        addon.crc = entries.read!uint;
        addon.unknown = entries.read!uint;
        addons ~= addon;
    }
    return addons;
}

/// The body of `SMSG_ADDON_INFO` accepting every addon in `addons`.
ubyte[] buildAddonInfo(const(ClientAddon)[] addons)
{
    ByteWriter writer;
    foreach (ref addon; addons)
    {
        writer.put(ubyte(2)); // addon state: enabled
        writer.put(ubyte(1)); // "uses CRC" block follows
        const needsKey = addon.crc != standardAddonCrc;
        writer.put(needsKey);
        if (needsKey)
            writer.putBytes(addonPublicKey[]);
        writer.put(uint(0));
        writer.put(ubyte(0)); // no URL
    }
    return writer.release();
}

/// Builds an addon block as the client does: entry list, zlib-compressed, size first (tests, the load generator).
ubyte[] makeAddonBlock(const(ClientAddon)[] addons)
{
    import std.zlib : compress;

    ByteWriter entries;
    foreach (ref addon; addons)
    {
        entries.putCString(addon.name);
        entries.put(addon.flags);
        entries.put(addon.crc);
        entries.put(addon.unknown);
    }
    ByteWriter block;
    block.put(cast(uint) entries.length);
    block.putBytes(cast(const(ubyte)[]) compress(entries.data));
    return block.release();
}

unittest
{
    import std.exception : assertThrown;

    static assert(addonPublicKey[0] == 0xC3 && addonPublicKey[$ - 1] == 0xD2);

    const addons = [
        ClientAddon("Blizzard_AuctionUI", 1, standardAddonCrc, 0),
        ClientAddon("MyAddon", 1, 0x12345678, 0),
    ];
    const parsed = parseAddons(makeAddonBlock(addons));
    assert(parsed == addons);

    const reply = buildAddonInfo(parsed);
    // Standard addon: 2, 1, 0, uint32 0, 0 (8 bytes). Custom addon: 2, 1, 1, key, uint32 0, 0 (264 bytes).
    assert(reply.length == 8 + 264);
    assert(reply[0 .. 3] == [2, 1, 0] && reply[8 .. 11] == [2, 1, 1]);
    assert(reply[11 .. 11 + 256] == addonPublicKey[]);

    const ubyte[8] garbage = [5, 0, 0, 0, 1, 2, 3, 4];
    assertThrown!PacketException(parseAddons(garbage[]));
    const ubyte[4] empty = [0, 0, 0, 0];
    assertThrown!PacketException(parseAddons(empty[]));
}
