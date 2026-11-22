/// Bounds and collision meshes for placed game objects.
module dmangos.vmap.gameobjectmodels;

import dmangos.bytes : ByteReader;
import dmangos.vmap.maptree : ModelCache;
import dmangos.vmap.math : AABox, Matrix3, Ray, Vector3, readBox;
import dmangos.vmap.model : WorldModel;

/// Static display data from the extractor's game object model list.
final class GameObjectModels
{
    private struct Display
    {
        string name;
        AABox bounds;
    }

    private ModelCache models;
    private Display[uint] displays;

    this(const(ubyte)[] data, ModelCache models)
    {
        import std.algorithm.searching : canFind;
        import std.exception : enforce;
        import std.math : isFinite;

        this.models = models;
        auto reader = ByteReader(data);
        while (!reader.empty)
        {
            const display = reader.read!uint;
            const length = reader.read!uint;
            enforce(length > 0 && length <= 500, "invalid game object model name length");
            const name = reader.readString(length);
            enforce(!name.canFind('/') && !name.canFind('\\'), "game object model name must be a file name");
            const bounds = readBox(reader);
            bool valid = true;
            foreach (axis; 0 .. 3)
                valid &= isFinite(bounds.lo[axis]) && isFinite(bounds.hi[axis]) && bounds.lo[axis] <= bounds.hi[axis];
            if (valid)
                displays[display] = Display(name, bounds);
        }
    }

    static GameObjectModels load(string directory, ModelCache models)
    {
        import dmangos.log : warning;
        import dmangos.vmap.model : gameObjectModels;
        import std.file : exists, read;
        import std.path : buildPath;

        const path = buildPath(directory, gameObjectModels);
        if (!exists(path))
            return null;
        try
            return new GameObjectModels(cast(const(ubyte)[]) read(path), models);
        catch (Exception e)
            warning!"could not read game object collision data %s: %s"(path, e.msg);
        return null;
    }

    GameObjectShape place(uint displayId, Vector3 at, float[4] rotation, float scale)
    {
        import std.math : isFinite;

        const entry = displayId in displays;
        if (entry is null || !isFinite(scale) || scale <= 0)
            return GameObjectShape.init;
        foreach (axis; 0 .. 3)
            if (!isFinite(at[axis]))
                return GameObjectShape.init;
        float norm = 0;
        foreach (component; rotation)
            norm += component * component;
        if (!isFinite(norm) || norm <= 0)
            return GameObjectShape.init;
        const transform = Matrix3.fromQuaternion(rotation[0], rotation[1], rotation[2], rotation[3]);
        auto model = models.acquire(entry.name);
        if (model is null)
            return GameObjectShape.init;
        auto shape = GameObjectShape(model, at, transform.inverse(), 1.0f / scale);
        shape.bounds = AABox(Vector3(float.infinity, float.infinity, float.infinity),
            Vector3(-float.infinity, -float.infinity, -float.infinity));
        foreach (x; [entry.bounds.lo.x, entry.bounds.hi.x])
            foreach (y; [entry.bounds.lo.y, entry.bounds.hi.y])
                foreach (z; [entry.bounds.lo.z, entry.bounds.hi.z])
                    shape.bounds.merge(at + (transform * Vector3(x, y, z)) * scale);
        foreach (axis; 0 .. 3)
            if (!isFinite(shape.bounds.lo[axis]) || !isFinite(shape.bounds.hi[axis]))
                return GameObjectShape.init;
        return shape;
    }
}

/// The shape of one game object, in world coordinates.
struct GameObjectShape
{
    private WorldModel model;
    private Vector3 position;
    private Matrix3 inverseRotation;
    private float inverseScale;
    AABox bounds;

    bool opCast(B : bool)() const
    {
        return model !is null;
    }

    bool intersects(const Ray ray, float distance) const
    {
        if (model is null || ray.intersectionTime(bounds) > distance)
            return false;
        const local = Ray((inverseRotation * (ray.origin - position)) * inverseScale,
            inverseRotation * ray.direction);
        float localDistance = distance * inverseScale;
        return model.intersectRay(local, localDistance, true);
    }
}
