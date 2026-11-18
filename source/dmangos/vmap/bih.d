/**
 * The bounding interval hierarchy (as in the Sunflow ray tracer):
 * the tree that finds, among many boxes, those a ray or a point meets. Maps index their placed
 * models with it, models their groups, and groups their triangles.
 *
 * The tree is an array of `uint`s: each node is three words, the first holding the split axis (two
 * bits), a BVH2 flag and the offset of its children, the other two the clip planes (as float bits),
 * or for a leaf the first object and the object count. Built and walked exactly as the vmap file
 * format has it, so trees built here and those in existing vmap files read the same both ways.
 */
module dmangos.vmap.bih;

import std.algorithm.comparison : max, min;
import std.exception : enforce;
import std.math : isNaN;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.vmap.math;

/// The deepest a tree goes.
enum maxStackSize = 64;

/// See the module documentation.
struct BIH
{
    uint[] tree = [3u << 30, 0, 0]; // an empty tree: one dummy leaf
    uint[] objects;
    AABox bounds;

    /// The objects indexed.
    @property size_t primCount() const pure nothrow @nogc @safe
    {
        return objects.length;
    }

    /**
     * A tree over `count` objects whose boxes `boundsOf` gives, at most `leafSize`
     * objects to a leaf.
     */
    void build(size_t count, scope AABox delegate(size_t) boundsOf, uint leafSize = 3)
    {
        if (count == 0)
        {
            this = BIH.init;
            return;
        }
        auto indices = new uint[count];
        auto primBounds = new AABox[count];
        bounds = boundsOf(0);
        foreach (i; 0 .. count)
        {
            indices[i] = cast(uint) i;
            primBounds[i] = boundsOf(i);
            bounds.merge(primBounds[i]);
        }
        uint[] built = [3u << 30, 0, 0];
        auto grid = Bound(bounds.lo, bounds.hi), node = grid;
        subdivide(0, cast(int) count - 1, built, indices, primBounds, leafSize, grid, node, 0, 1);
        objects = indices;
        tree = built;
    }

    /**
     * `hit(entry, maxDist)` for each object whose cell the ray crosses within
     * `maxDist`, nearest cells first; the callback shortens `maxDist` when it hits. With
     * `stopAtFirst`, the first hit ends the search.
     */
    void intersectRay(const Ray r, scope bool delegate(uint entry, ref float maxDist) hit, ref float maxDist,
        bool stopAtFirst = false) const
    {
        float intervalMin = -1, intervalMax = -1;
        const org = r.origin, dir = r.direction;
        Vector3 invDir;
        foreach (i; 0 .. 3)
        {
            invDir[i] = 1.0f / dir[i];
            if (fuzzyNe(dir[i], 0.0f))
            {
                float t1 = (bounds.lo[i] - org[i]) * invDir[i];
                float t2 = (bounds.hi[i] - org[i]) * invDir[i];
                if (t1 > t2)
                {
                    const t = t1;
                    t1 = t2;
                    t2 = t;
                }
                if (t1 > intervalMin)
                    intervalMin = t1;
                if (t2 < intervalMax || intervalMax < 0)
                    intervalMax = t2;
                if (intervalMax <= 0 || intervalMin >= maxDist)
                    return;
            }
        }
        if (intervalMin > intervalMax)
            return;
        intervalMin = max(intervalMin, 0.0f);
        intervalMax = min(intervalMax, maxDist);

        uint[3] offsetFront, offsetBack, offsetFront3, offsetBack3;
        foreach (i; 0 .. 3)
        {
            offsetFront[i] = floatBits(dir[i]) >> 31;
            offsetBack[i] = offsetFront[i] ^ 1;
            offsetFront3[i] = offsetFront[i] * 3;
            offsetBack3[i] = offsetBack[i] * 3;
            ++offsetFront[i];
            ++offsetBack[i];
        }

        StackNode[maxStackSize] stack;
        int stackPos = 0;
        int node = 0;
        while (true)
        {
            while (true)
            {
                const tn = tree[node];
                const axis = (tn & (3u << 30)) >> 30;
                const bvh2 = (tn & (1u << 29)) != 0;
                int offset = tn & ~(7u << 29);
                if (!bvh2)
                {
                    if (axis < 3)
                    {
                        const tf = (bitsFloat(tree[node + offsetFront[axis]]) - org[axis]) * invDir[axis];
                        const tb = (bitsFloat(tree[node + offsetBack[axis]]) - org[axis]) * invDir[axis];
                        if (tf < intervalMin && tb > intervalMax)
                            break; // the ray passes between the children
                        const back = offset + offsetBack3[axis];
                        node = back;
                        if (tf < intervalMin) // only the back child
                        {
                            intervalMin = tb >= intervalMin ? tb : intervalMin;
                            continue;
                        }
                        node = offset + offsetFront3[axis];
                        if (tb > intervalMax) // only the front child
                        {
                            intervalMax = tf <= intervalMax ? tf : intervalMax;
                            continue;
                        }
                        // Both: the back one later.
                        stack[stackPos] = StackNode(back, tb >= intervalMin ? tb : intervalMin, intervalMax);
                        ++stackPos;
                        intervalMax = tf <= intervalMax ? tf : intervalMax;
                    }
                    else
                    {
                        int n = tree[node + 1];
                        while (n > 0)
                        {
                            const hitObject = hit(objects[offset], maxDist);
                            if (stopAtFirst && hitObject)
                                return;
                            --n;
                            ++offset;
                        }
                        break;
                    }
                }
                else
                {
                    if (axis > 2)
                        return;
                    const tf = (bitsFloat(tree[node + offsetFront[axis]]) - org[axis]) * invDir[axis];
                    const tb = (bitsFloat(tree[node + offsetBack[axis]]) - org[axis]) * invDir[axis];
                    node = offset;
                    intervalMin = tf >= intervalMin ? tf : intervalMin;
                    intervalMax = tb <= intervalMax ? tb : intervalMax;
                    if (intervalMin > intervalMax)
                        break;
                }
            }
            do
            {
                if (stackPos == 0)
                    return;
                --stackPos;
                intervalMin = stack[stackPos].tnear;
                if (maxDist < intervalMin)
                    continue;
                node = stack[stackPos].node;
                intervalMax = stack[stackPos].tfar;
                break;
            }
            while (true);
        }
    }

    /// `hit(entry)` for each object whose cell holds the point.
    void intersectPoint(const Vector3 p, scope void delegate(uint entry) hit) const
    {
        if (!bounds.contains(p))
            return;
        StackNode[maxStackSize] stack;
        int stackPos = 0;
        int node = 0;
        while (true)
        {
            while (true)
            {
                const tn = tree[node];
                const axis = (tn & (3u << 30)) >> 30;
                const bvh2 = (tn & (1u << 29)) != 0;
                int offset = tn & ~(7u << 29);
                if (!bvh2)
                {
                    if (axis < 3)
                    {
                        const tl = bitsFloat(tree[node + 1]), tr = bitsFloat(tree[node + 2]);
                        if (tl < p[axis] && tr > p[axis])
                            break; // between the children
                        const right = offset + 3;
                        node = right;
                        if (tl < p[axis])
                            continue;
                        node = offset; // left
                        if (tr > p[axis])
                            continue;
                        stack[stackPos++].node = right; // both
                    }
                    else
                    {
                        int n = tree[node + 1];
                        while (n > 0)
                        {
                            hit(objects[offset]);
                            --n;
                            ++offset;
                        }
                        break;
                    }
                }
                else
                {
                    if (axis > 2)
                        return;
                    const tl = bitsFloat(tree[node + 1]), tr = bitsFloat(tree[node + 2]);
                    node = offset;
                    if (tl > p[axis] || tr < p[axis])
                        break;
                }
            }
            if (stackPos == 0)
                return;
            --stackPos;
            node = stack[stackPos].node;
        }
    }

    /// The tree as a vmap file stores it: its bounds, its nodes, its objects.
    void write(ref ByteWriter w) const
    {
        putBox(w, bounds);
        w.put(cast(uint) tree.length);
        foreach (word; tree)
            w.put(word);
        w.put(cast(uint) objects.length);
        foreach (o; objects)
            w.put(o);
    }

    /// ditto
    static BIH read(ref ByteReader r)
    {
        BIH b;
        b.bounds = readBox(r);
        b.tree = new uint[r.read!uint];
        foreach (ref word; b.tree)
            word = r.read!uint;
        b.objects = new uint[r.read!uint];
        foreach (ref o; b.objects)
            o = r.read!uint;
        return b;
    }

private:
    struct StackNode
    {
        uint node;
        float tnear = 0;
        float tfar = 0;
    }

    struct Bound
    {
        Vector3 lo, hi;
    }

    static void createNode(ref uint[] tree, int nodeIndex, uint left, uint right)
    {
        tree[nodeIndex + 0] = (3u << 30) | left;
        tree[nodeIndex + 1] = right - left + 1;
    }

    /// Splits the objects from `left` to `right` into a node's children, recursively, down to leaves.
    static void subdivide(int left, int right, ref uint[] tree, uint[] indices, const AABox[] primBounds,
        uint maxPrims, ref Bound gridBox, ref Bound nodeBox, int nodeIndex, int depth)
    {
        if (right - left + 1 <= cast(int) maxPrims || depth >= maxStackSize)
        {
            createNode(tree, nodeIndex, left, right);
            return;
        }
        int axis = -1, rightOrig;
        float clipL, clipR;
        float prevClip = float.nan;
        float split = float.nan;
        bool wasLeft = true;
        while (true)
        {
            const prevAxis = axis;
            const prevSplit = split;
            const d = gridBox.hi - gridBox.lo;
            enforce(d.x >= 0 && d.y >= 0 && d.z >= 0, "negative node extents");
            foreach (i; 0 .. 3)
                enforce(!(nodeBox.hi[i] < gridBox.lo[i] || nodeBox.lo[i] > gridBox.hi[i]), "invalid node overlap");
            axis = d.primaryAxis;
            split = 0.5f * (gridBox.lo[axis] + gridBox.hi[axis]);
            clipL = -float.infinity;
            clipR = float.infinity;
            rightOrig = right;
            float nodeL = float.infinity, nodeR = -float.infinity;
            for (int i = left; i <= right;)
            {
                const obj = indices[i];
                const minb = primBounds[obj].lo[axis], maxb = primBounds[obj].hi[axis];
                const center = (minb + maxb) * 0.5f;
                if (center <= split)
                {
                    ++i;
                    if (clipL < maxb)
                        clipL = maxb;
                }
                else
                {
                    const t = indices[i];
                    indices[i] = indices[right];
                    indices[right] = t;
                    --right;
                    if (clipR > minb)
                        clipR = minb;
                }
                nodeL = min(nodeL, minb);
                nodeR = max(nodeR, maxb);
            }
            // Empty space on both sides: a BVH2 node cuts it off.
            if (nodeL > nodeBox.lo[axis] && nodeR < nodeBox.hi[axis])
            {
                const nodeBoxW = nodeBox.hi[axis] - nodeBox.lo[axis];
                const nodeNewW = nodeR - nodeL;
                if (1.3f * nodeNewW < nodeBoxW)
                {
                    const nextIndex = cast(int) tree.length;
                    tree ~= [0u, 0, 0];
                    tree[nodeIndex + 0] = (axis << 30) | (1u << 29) | nextIndex;
                    tree[nodeIndex + 1] = floatBits(nodeL);
                    tree[nodeIndex + 2] = floatBits(nodeR);
                    nodeBox.lo[axis] = nodeL;
                    nodeBox.hi[axis] = nodeR;
                    subdivide(left, rightOrig, tree, indices, primBounds, maxPrims, gridBox, nodeBox, nextIndex,
                        depth + 1);
                    return;
                }
            }
            if (right == rightOrig)
            {
                // Everything on the left.
                if (prevAxis == axis && fuzzyEq(prevSplit, split))
                {
                    createNode(tree, nodeIndex, left, right);
                    return;
                }
                if (clipL <= split)
                {
                    gridBox.hi[axis] = split;
                    prevClip = clipL;
                    wasLeft = true;
                    continue;
                }
                gridBox.hi[axis] = split;
                prevClip = float.nan;
            }
            else if (left > right)
            {
                // Everything on the right.
                right = rightOrig;
                if (prevAxis == axis && fuzzyEq(prevSplit, split))
                {
                    createNode(tree, nodeIndex, left, right);
                    return;
                }
                if (clipR >= split)
                {
                    gridBox.lo[axis] = split;
                    prevClip = clipR;
                    wasLeft = false;
                    continue;
                }
                gridBox.lo[axis] = split;
                prevClip = float.nan;
            }
            else
            {
                // A real split; first a node for the empty space found before, if any.
                if (prevAxis != -1 && !isNaN(prevClip))
                {
                    const nextIndex = cast(int) tree.length;
                    tree ~= [0u, 0, 0];
                    if (wasLeft)
                    {
                        tree[nodeIndex + 0] = (prevAxis << 30) | nextIndex;
                        tree[nodeIndex + 1] = floatBits(prevClip);
                        tree[nodeIndex + 2] = floatBits(float.infinity);
                    }
                    else
                    {
                        tree[nodeIndex + 0] = (prevAxis << 30) | (nextIndex - 3);
                        tree[nodeIndex + 1] = floatBits(-float.infinity);
                        tree[nodeIndex + 2] = floatBits(prevClip);
                    }
                    ++depth;
                    nodeIndex = nextIndex;
                }
                break;
            }
        }
        int nextIndex = cast(int) tree.length;
        const nl = right - left + 1;
        const nr = rightOrig - (right + 1) + 1;
        if (nl > 0)
            tree ~= [0u, 0, 0];
        else
            nextIndex -= 3;
        if (nr > 0)
            tree ~= [0u, 0, 0];
        tree[nodeIndex + 0] = (axis << 30) | nextIndex;
        tree[nodeIndex + 1] = floatBits(clipL);
        tree[nodeIndex + 2] = floatBits(clipR);
        Bound gridBoxL = gridBox, gridBoxR = gridBox, nodeBoxL = nodeBox, nodeBoxR = nodeBox;
        gridBoxL.hi[axis] = gridBoxR.lo[axis] = split;
        nodeBoxL.hi[axis] = clipL;
        nodeBoxR.lo[axis] = clipR;
        if (nl > 0)
            subdivide(left, right, tree, indices, primBounds, maxPrims, gridBoxL, nodeBoxL, nextIndex, depth + 1);
        if (nr > 0)
            subdivide(right + 1, rightOrig, tree, indices, primBounds, maxPrims, gridBoxR, nodeBoxR, nextIndex + 3,
                depth + 1);
    }
}

unittest
{
    import std.algorithm.searching : canFind;

    // A row of unit boxes along x, one every two yards.
    AABox[] boxes;
    foreach (i; 0 .. 20)
        boxes ~= AABox(Vector3(2 * i, 0, 0), Vector3(2 * i + 1, 1, 1));
    BIH tree;
    tree.build(boxes.length, i => boxes[i]);
    assert(tree.primCount == 20 && tree.bounds.hi.x == 39);

    // A ray along the row meets the boxes in order; the callback says which it hit.
    uint[] seen;
    float maxDist = 100;
    bool hitBox(uint entry, ref float dist)
    {
        const t = Ray(Vector3(-5, 0.5f, 0.5f), Vector3(1, 0, 0)).intersectionTime(boxes[entry]);
        seen ~= entry;
        if (t < dist)
        {
            dist = t;
            return true;
        }
        return false;
    }

    tree.intersectRay(Ray(Vector3(-5, 0.5f, 0.5f), Vector3(1, 0, 0)), &hitBox, maxDist, true);
    assert(maxDist == 5 && seen.canFind(0u), "the first box, 5 yards on");

    // A point finds the box it is in.
    uint[] inside;
    tree.intersectPoint(Vector3(14.5f, 0.5f, 0.5f), (uint entry) { inside ~= entry; });
    assert(inside.canFind(7u));
    inside = null;
    tree.intersectPoint(Vector3(15.5f, 0.5f, 0.5f), (uint entry) {
        if (boxes[entry].contains(Vector3(15.5f, 0.5f, 0.5f)))
            inside ~= entry;
    });
    assert(inside.length == 0, "between boxes");

    // Written and read back, the same tree.
    ByteWriter w;
    tree.write(w);
    auto r = ByteReader(w.data);
    const copy = BIH.read(r);
    assert(copy.tree == tree.tree && copy.objects == tree.objects && copy.bounds == tree.bounds && r.empty);

    BIH empty;
    empty.build(0, i => AABox.init);
    assert(empty.tree == [3u << 30, 0, 0] && empty.primCount == 0);
}
