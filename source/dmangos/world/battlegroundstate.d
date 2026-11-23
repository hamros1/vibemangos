/// Fields that move with a running battleground. Clock values are relative to the snapshot time.
module dmangos.world.battlegroundstate;

import core.time : Duration, MonoTime, hnsecs;
import dmangos.bytes : ByteReader, ByteWriter;
import std.traits : isAssociativeArray, isDynamicArray, isStaticArray, KeyType, OriginalType, ValueType;

package struct BattlegroundState
{
    MonoTime now;
    ByteWriter* writer;
    ByteReader* reader;

    void transfer(Fields...)(ref Fields fields)
    {
        static foreach (i, Field; Fields)
            transferField(fields[i]);
    }

    private void transferField(T)(ref T value)
    {
        static if (is(T == MonoTime))
        {
            long time = long.min;
            if (writer !is null && value != MonoTime.init)
                time = (value - now).total!"hnsecs";
            transferField(time);
            if (reader !is null)
                value = time == long.min ? MonoTime.init : now + time.hnsecs;
        }
        else static if (is(T == Duration))
        {
            long time = value.total!"hnsecs";
            transferField(time);
            if (reader !is null)
                value = time.hnsecs;
        }
        else static if (is(T == string))
        {
            if (writer !is null)
            {
                writer.put(cast(uint) value.length);
                writer.putBytes(cast(const(ubyte)[]) value);
            }
            else
                value = reader.readString(reader.read!uint).idup;
        }
        else static if (is(T == enum))
        {
            auto number = cast(OriginalType!T) value;
            transferField(number);
            if (reader !is null)
                value = cast(T) number;
        }
        else static if (isStaticArray!T)
        {
            foreach (ref item; value)
                transferField(item);
        }
        else static if (isDynamicArray!T)
        {
            if (writer !is null)
                writer.put(cast(uint) value.length);
            else
                value.length = readCount();
            foreach (ref item; value)
                transferField(item);
        }
        else static if (isAssociativeArray!T)
        {
            if (writer !is null)
            {
                writer.put(cast(uint) value.length);
                foreach (key, ref item; value)
                    transfer(key, item);
            }
            else
            {
                const count = readCount();
                value = null;
                foreach (_; 0 .. count)
                {
                    KeyType!T key;
                    ValueType!T item;
                    transfer(key, item);
                    value[key] = item;
                }
            }
        }
        else static if (is(T == struct))
        {
            foreach (ref field; value.tupleof)
                transferField(field);
        }
        else if (writer !is null)
            writer.put(value);
        else
            value = reader.read!T;
    }

    private uint readCount()
    {
        import std.exception : enforce;

        const count = reader.read!uint;
        enforce(count <= reader.remaining, "battleground state ends early");
        return count;
    }
}
