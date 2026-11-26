/**
 * Weather: each zone with a `game_weather` row has its weather, which
 * changes now and then (`Weather.regenerate`, every `weatherChangeInterval`) by the season's
 * chances of rain, snow and storms; the players in the zone see it (`SMSG_WEATHER`), and a player
 * entering a zone gets its weather, or fine weather where it has none.
 */
module dmangos.world.weather;

import std.random : Random, uniform, uniform01;

/// The kinds of weather.
enum WeatherType : uint
{
    fine = 0,
    rain = 1,
    snow = 2,
    storm = 3,
}

/// A season's chances (percent) of each.
struct SeasonChances
{
    ubyte rain, snow, storm;
}

/// A zone's chances in spring, summer, fall and winter.
alias ZoneChances = SeasonChances[4];

/// Milliseconds between changes: 10 minutes.
enum int weatherChangeInterval = 600_000;

/// The season of a time: spring from about the 20th of March (`tm_yday - 78`), 91 days each.
uint seasonOf(long unixTime)
{
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : LocalTime;

    const yday = SysTime.fromUnixTime(unixTime, LocalTime()).dayOfYear - 1;
    return ((yday - 78 + 365) / 91) % 4;
}

/// One zone's weather.
struct Weather
{
    WeatherType type;
    float grade = 0;
    int timer = weatherChangeInterval;
    ZoneChances chances;
    bool permanent;

    /// A new weather, perhaps; true if it changed.
    bool regenerate(ref Random random, uint season)
    {
        enum float third = 0.33333334f, twoThirds = 0.6666667f;
        if (permanent)
            return false;
        const oldType = type;
        const oldGrade = grade;
        const u = uniform(0, 100, random);
        if (u < 30)
            return false;
        if (u < 60 && grade < third) // get fair
        {
            type = WeatherType.fine;
            grade = 0;
        }
        if (u < 60 && type != WeatherType.fine) // get better
        {
            grade -= third;
            return true;
        }
        if (u < 90 && type != WeatherType.fine) // get worse
        {
            grade += third;
            return true;
        }
        if (type != WeatherType.fine)
        {
            if (grade < third)
            {
                grade = 0.9999f; // go nuts
                return true;
            }
            if (grade > twoThirds && uniform(0, 100, random) < 50)
            {
                grade -= twoThirds;
                return true;
            }
            type = WeatherType.fine; // clear up
            grade = 0;
        }
        const c = chances[season];
        const chance1 = uint(c.rain), chance2 = chance1 + c.snow, chance3 = chance2 + c.storm;
        const rnd = uniform!"[]"(1u, 100u, random);
        type = rnd <= chance1 ? WeatherType.rain : rnd <= chance2 ? WeatherType.snow
            : rnd <= chance3 ? WeatherType.storm : WeatherType.fine;
        if (type == WeatherType.fine)
            grade = 0;
        else if (u < 90)
            grade = uniform01(random) * 0.3333f;
        else if (uniform(0, 100, random) < 50)
            grade = uniform01(random) * 0.3333f + 0.3334f;
        else
            grade = uniform01(random) * 0.3333f + 0.6667f;
        normalize();
        return type != oldType || grade != oldGrade;
    }

    /// Keeps the grade strictly between 0 and 1.
    void normalize()
    {
        if (grade >= 1)
            grade = 0.9999f;
        else if (grade < 0)
            grade = 0.0001f;
    }

    /// The 1.12 sound of it.
    uint sound() const
    {
        static uint pick(float grade, uint light, uint medium, uint heavy)
        {
            return grade < 0.40f ? light : grade < 0.70f ? medium : heavy;
        }

        final switch (type)
        {
        case WeatherType.rain:
            return grade < 0.27f ? 0 : pick(grade, 8533, 8534, 8535);
        case WeatherType.snow:
            return pick(grade, 8536, 8537, 8538);
        case WeatherType.storm:
            return pick(grade, 8556, 8557, 8558);
        case WeatherType.fine:
            return 0;
        }
    }

    /// `SMSG_WEATHER`'s body: type, grade, sound, and a smooth change.
    ubyte[] packet()
    {
        normalize();
        return weatherPacket(type, grade, sound);
    }
}

/// `SMSG_WEATHER`'s body.
ubyte[] weatherPacket(WeatherType type, float grade, uint sound)
{
    import dmangos.bytes : ByteWriter;

    ByteWriter w;
    w.put(uint(type));
    w.put(grade);
    w.put(sound);
    w.put(ubyte(0)); // 0: a smooth change
    return w.data.dup;
}

/// Fine weather at once (no sound, an instant change).
ubyte[] fineWeatherPacket()
{
    import dmangos.bytes : ByteWriter;

    ByteWriter w;
    w.put(uint(WeatherType.fine));
    w.put(0.0f);
    w.put(uint(0));
    w.put(ubyte(0));
    return w.data.dup;
}

unittest
{
    auto random = Random(7);
    Weather w;
    w.chances[0] = SeasonChances(100, 0, 0); // spring: rain whenever it changes from fine
    bool rained;
    foreach (_; 0 .. 50)
        if (w.regenerate(random, 0) && w.type == WeatherType.rain)
            rained = true;
    assert(rained && (w.type == WeatherType.fine || w.type == WeatherType.rain));
    w.normalize(); // as before each send
    assert(w.grade >= 0 && w.grade < 1);
    Weather heavy = {type: WeatherType.snow, grade: 0.8f};
    import std.conv : text;

    assert(heavy.sound == 8538, text(heavy.sound));
    assert(heavy.packet.length == 13, text(heavy.packet.length));
    Weather calm;
    calm.permanent = true;
    assert(!calm.regenerate(random, 0));
    assert(fineWeatherPacket().length == 13);
    assert(seasonOf(0) < 4);
}

/// A zone with chances gets weather when a player is in it, and its changes reach that player.
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.weatherservice : WeatherHost;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const zone = anduin.session.character.data.zone;
    ZoneChances rainy;
    foreach (ref season; rainy)
        season = SeasonChances(100, 0, 0);
    context.data.weatherChances[zone] = rainy;
    assert(context.weather.packetFor(zone).length == 13);
    auto weather = context.services.local!WeatherHost().weatherOf(zone);
    assert(weather !is null);
    assert(context.weather.packetFor(zone + 1000) == fineWeatherPacket(), "no row: fine");
    auto now = MonoTime.currTime;
    context.update(now);
    bool heard;
    foreach (_; 0 .. 40)
    {
        weather.timer = 0;
        now += 10.msecs;
        context.update(now);
        if (opcodesOf(anduin.read()).canFind(Opcode.SMSG_WEATHER))
            heard = true;
    }
    assert(heard, "a change in the zone");
}
