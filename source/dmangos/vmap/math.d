/**
 * The 3D math of the vmaps: vectors, 3 x 3 rotation matrices, axis-aligned boxes and rays,
 * computed in `float` exactly as the G3D library that the standard vmap tools use computes them,
 * so that trees built and queried here match theirs.
 *
 * Only what the vmap code uses is here. A `Vector3` is three floats and an `AABox` six, as the
 * vmap files store them.
 */
module dmangos.vmap.math;

import std.math : abs, asin, atan2, cos, sin, sqrt;

/// The base tolerance of the fuzzy comparisons.
enum double fuzzyEpsilon = 0.00001;

/// The tolerance for comparing `a` with something of its magnitude.
double eps(double a) pure nothrow @nogc @safe
{
    const aa = abs(a) + 1.0;
    return aa == double.infinity ? fuzzyEpsilon : fuzzyEpsilon * aa;
}

/// Whether `a` and `b` are equal within `eps(a)`.
bool fuzzyEq(double a, double b) pure nothrow @nogc @safe
{
    return a == b || abs(a - b) <= eps(a);
}

/// Whether `a` and `b` differ by more than `eps(a)`.
bool fuzzyNe(double a, double b) pure nothrow @nogc @safe
{
    return !fuzzyEq(a, b);
}

/// A point or direction in 3D.
struct Vector3
{
    float x = 0, y = 0, z = 0;

    ///
    ref inout(float) opIndex(size_t i) inout return pure nothrow @nogc @safe
    in (i < 3)
    {
        return i == 0 ? x : i == 1 ? y : z;
    }

    ///
    Vector3 opBinary(string op)(const Vector3 v) const pure nothrow @nogc @safe
        if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        return Vector3(mixin("x " ~ op ~ " v.x"), mixin("y " ~ op ~ " v.y"), mixin("z " ~ op ~ " v.z"));
    }

    ///
    Vector3 opBinary(string op)(float k) const pure nothrow @nogc @safe
        if (op == "*" || op == "/")
    {
        return Vector3(mixin("x " ~ op ~ " k"), mixin("y " ~ op ~ " k"), mixin("z " ~ op ~ " k"));
    }

    ///
    Vector3 opBinaryRight(string op : "*")(float k) const pure nothrow @nogc @safe
    {
        return Vector3(k * x, k * y, k * z);
    }

    ///
    Vector3 opUnary(string op : "-")() const pure nothrow @nogc @safe
    {
        return Vector3(-x, -y, -z);
    }

    ///
    float dot(const Vector3 v) const pure nothrow @nogc @safe
    {
        return x * v.x + y * v.y + z * v.z;
    }

    ///
    Vector3 cross(const Vector3 v) const pure nothrow @nogc @safe
    {
        return Vector3(y * v.z - z * v.y, z * v.x - x * v.z, x * v.y - y * v.x);
    }

    /// The length, with a `float` square root.
    float magnitude() const pure nothrow @nogc @safe
    {
        return sqrt(x * x + y * y + z * z);
    }

    /// Component-wise minimum.
    Vector3 min(const Vector3 v) const pure nothrow @nogc @safe
    {
        return Vector3(x < v.x ? x : v.x, y < v.y ? y : v.y, z < v.z ? z : v.z);
    }

    /// Component-wise maximum.
    Vector3 max(const Vector3 v) const pure nothrow @nogc @safe
    {
        return Vector3(x > v.x ? x : v.x, y > v.y ? y : v.y, z > v.z ? z : v.z);
    }

    /// The axis of the largest component; ties go to the later axis.
    int primaryAxis() const pure nothrow @nogc @safe
    {
        const double nx = abs(x), ny = abs(y), nz = abs(z);
        if (nx > ny)
            return nx > nz ? 0 : 2;
        return ny > nz ? 1 : 2;
    }
}

/// A 3 x 3 matrix, row major.
struct Matrix3
{
    float[3][3] elt = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];

    ///
    this(float e00, float e01, float e02, float e10, float e11, float e12, float e20, float e21, float e22)
        pure nothrow @nogc @safe
    {
        elt = [[e00, e01, e02], [e10, e11, e12], [e20, e21, e22]];
    }

    /// `Matrix3(const Quat&)`: the rotation of a quaternion (x, y, z, w), normalized first.
    static Matrix3 fromQuaternion(float qx, float qy, float qz, float qw) pure nothrow @nogc @safe
    {
        const float k = 1.0f / sqrt(qx * qx + qy * qy + qz * qz + qw * qw); // the quaternion made a unit one
        qx *= k;
        qy *= k;
        qz *= k;
        qw *= k;
        const float xx = 2.0f * qx * qx, xy = 2.0f * qx * qy, xz = 2.0f * qx * qz, xw = 2.0f * qx * qw;
        const float yy = 2.0f * qy * qy, yz = 2.0f * qy * qz, yw = 2.0f * qy * qw;
        const float zz = 2.0f * qz * qz, zw = 2.0f * qz * qw;
        return Matrix3(1.0f - yy - zz, xy - zw, xz + yw,
            xy + zw, 1.0f - xx - zz, yz - xw,
            xz - yw, yz + xw, 1.0f - xx - yy);
    }

    /// Yaw about z, then pitch about y, then roll about x (radians).
    static Matrix3 fromEulerAnglesZYX(float yaw, float pitch, float roll) pure nothrow @nogc @safe
    {
        float c = cos(yaw), s = sin(yaw);
        const z = Matrix3(c, -s, 0, s, c, 0, 0, 0, 1);
        c = cos(pitch);
        s = sin(pitch);
        const y = Matrix3(c, 0, s, 0, 1, 0, -s, 0, c);
        c = cos(roll);
        s = sin(roll);
        const x = Matrix3(1, 0, 0, 0, c, -s, 0, s, c);
        return z * (y * x);
    }

    /// Matrix product.
    Matrix3 opBinary(string op : "*")(const Matrix3 m) const pure nothrow @nogc @safe
    {
        Matrix3 p;
        foreach (r; 0 .. 3)
            foreach (c; 0 .. 3)
                p.elt[r][c] = elt[r][0] * m.elt[0][c] + elt[r][1] * m.elt[1][c] + elt[r][2] * m.elt[2][c];
        return p;
    }

    /// Matrix times column vector.
    Vector3 opBinary(string op : "*")(const Vector3 v) const pure nothrow @nogc @safe
    {
        Vector3 p;
        foreach (r; 0 .. 3)
            p[r] = elt[r][0] * v.x + elt[r][1] * v.y + elt[r][2] * v.z;
        return p;
    }

    /// Row vector times matrix (`operator*(const Vector3&, const Matrix3&)`).
    Vector3 opBinaryRight(string op : "*")(const Vector3 v) const pure nothrow @nogc @safe
    {
        Vector3 p;
        foreach (r; 0 .. 3)
            p[r] = v.x * elt[0][r] + v.y * elt[1][r] + v.z * elt[2][r];
        return p;
    }

    /// The inverse, by cofactors; the zero matrix if singular (tolerance 1e-6).
    Matrix3 inverse() const pure nothrow @nogc @safe
    {
        Matrix3 i;
        i.elt[0][0] = elt[1][1] * elt[2][2] - elt[1][2] * elt[2][1];
        i.elt[0][1] = elt[0][2] * elt[2][1] - elt[0][1] * elt[2][2];
        i.elt[0][2] = elt[0][1] * elt[1][2] - elt[0][2] * elt[1][1];
        i.elt[1][0] = elt[1][2] * elt[2][0] - elt[1][0] * elt[2][2];
        i.elt[1][1] = elt[0][0] * elt[2][2] - elt[0][2] * elt[2][0];
        i.elt[1][2] = elt[0][2] * elt[1][0] - elt[0][0] * elt[1][2];
        i.elt[2][0] = elt[1][0] * elt[2][1] - elt[1][1] * elt[2][0];
        i.elt[2][1] = elt[0][1] * elt[2][0] - elt[0][0] * elt[2][1];
        i.elt[2][2] = elt[0][0] * elt[1][1] - elt[0][1] * elt[1][0];
        const float det = elt[0][0] * i.elt[0][0] + elt[0][1] * i.elt[1][0] + elt[0][2] * i.elt[2][0];
        if (abs(det) <= 1e-06f)
            return Matrix3(0, 0, 0, 0, 0, 0, 0, 0, 0);
        const float invDet = 1.0 / det;
        foreach (ref row; i.elt)
            row[] *= invDet;
        return i;
    }

    /// The angles (radians) whose X, then Y, then Z rotations make this one.
    void toEulerAnglesXYZ(out float xAngle, out float yAngle, out float zAngle) const pure nothrow @nogc @safe
    {
        enum float halfPi = 1.5707963267948966;
        if (elt[0][2] < 1.0f)
        {
            if (elt[0][2] > -1.0f)
            {
                xAngle = atan2(-elt[1][2], elt[2][2]);
                yAngle = aSin(elt[0][2]);
                zAngle = atan2(-elt[0][1], elt[0][0]);
            }
            else
            {
                xAngle = -atan2(elt[1][0], elt[1][1]);
                yAngle = -halfPi;
                zAngle = 0;
            }
        }
        else
        {
            xAngle = atan2(elt[1][0], elt[1][1]);
            yAngle = halfPi;
            zAngle = 0;
        }
    }

    /// Arc sine, whose out-of-range answers have their signs swapped (kept, so results match the vmap tools').
    private static double aSin(double value) pure nothrow @nogc @safe
    {
        enum double halfPi = 1.5707963267948966;
        if (-1.0 < value)
            return value < 1.0 ? asin(value) : -halfPi;
        return halfPi;
    }
}

/// An axis-aligned box.
struct AABox
{
    Vector3 lo, hi;

    /// Grows the box to hold `b` too.
    void merge(const AABox b) pure nothrow @nogc @safe
    {
        lo = lo.min(b.lo);
        hi = hi.max(b.hi);
    }

    /// ditto
    void merge(const Vector3 p) pure nothrow @nogc @safe
    {
        lo = lo.min(p);
        hi = hi.max(p);
    }

    /// Whether the point is inside or on the box.
    bool contains(const Vector3 p) const pure nothrow @nogc @safe
    {
        return p.x >= lo.x && p.y >= lo.y && p.z >= lo.z && p.x <= hi.x && p.y <= hi.y && p.z <= hi.z;
    }

    /// The box moved by `v`.
    AABox opBinary(string op : "+")(const Vector3 v) const pure nothrow @nogc @safe
    {
        return AABox(lo + v, hi + v);
    }
}

/// A ray: an origin and a unit direction.
struct Ray
{
    Vector3 origin, direction;

    /**
     * The distance at which the ray enters the box (0 from inside it), or `float.infinity` if it
     * misses.
     */
    float intersectionTime(const AABox box) const pure nothrow @nogc @trusted
    {
        bool inside = true;
        Vector3 location;
        Vector3 maxT = Vector3(-1, -1, -1);
        foreach (i; 0 .. 3)
        {
            if (origin[i] < box.lo[i])
            {
                location[i] = box.lo[i];
                inside = false;
                if (*cast(const uint*)&direction[i]) // any bit set, -0 too
                    maxT[i] = (box.lo[i] - origin[i]) / direction[i];
            }
            else if (origin[i] > box.hi[i])
            {
                location[i] = box.hi[i];
                inside = false;
                if (*cast(const uint*)&direction[i])
                    maxT[i] = (box.hi[i] - origin[i]) / direction[i];
            }
        }
        if (inside)
            return 0; // inside: the box is hit at once
        int plane = 0;
        if (maxT[1] > maxT[plane])
            plane = 1;
        if (maxT[2] > maxT[plane])
            plane = 2;
        if (*cast(const uint*)&maxT[plane] & 0x8000_0000) // a negative time: the box is behind
            return float.infinity;
        foreach (i; 0 .. 3)
            if (i != plane)
            {
                location[i] = origin[i] + maxT[plane] * direction[i];
                if (location[i] < box.lo[i] || location[i] > box.hi[i])
                    return float.infinity;
            }
        return (location - origin).magnitude();
    }
}

/// `floatToRawIntBits`
uint floatBits(float f) pure nothrow @nogc @trusted
{
    return *cast(uint*)&f;
}

/// `intBitsToFloat`
float bitsFloat(uint i) pure nothrow @nogc @trusted
{
    return *cast(float*)&i;
}

unittest
{
    import std.math : isClose, PI;

    // A quarter turn about z takes x to y; its inverse takes it back.
    const m = Matrix3.fromEulerAnglesZYX(PI / 2, 0, 0);
    const v = m * Vector3(1, 0, 0);
    assert(isClose(v.y, 1, 0, 1e-6) && isClose(v.x, 0, 0, 1e-6));
    const back = m.inverse() * v;
    assert(isClose(back.x, 1, 0, 1e-6) && isClose(back.y, 0, 0, 1e-6));
    assert(isClose((Vector3(1, 0, 0) * m.inverse()).y, 1, 0, 1e-6), "a row vector times the inverse is rotated forward");

    // Decomposed into X, Y and Z angles, a rotation is rebuilt as Rx * Ry * Rz.
    const original = Matrix3.fromEulerAnglesZYX(0.3f, 0.2f, 0.1f);
    float x, y, z;
    original.toEulerAnglesXYZ(x, y, z);
    const rx = Matrix3(1, 0, 0, 0, cos(x), -sin(x), 0, sin(x), cos(x));
    const ry = Matrix3(cos(y), 0, sin(y), 0, 1, 0, -sin(y), 0, cos(y));
    const rz = Matrix3(cos(z), -sin(z), 0, sin(z), cos(z), 0, 0, 0, 1);
    const rebuilt = rx * (ry * rz);
    foreach (r; 0 .. 3)
        foreach (c; 0 .. 3)
            assert(isClose(rebuilt.elt[r][c], original.elt[r][c], 0, 1e-5));

    // A quaternion of a half turn about z.
    const q = Matrix3.fromQuaternion(0, 0, 1, 0);
    assert(isClose((q * Vector3(1, 0, 0)).x, -1, 0, 1e-6));

    // Rays and boxes.
    const box = AABox(Vector3(0, 0, 0), Vector3(1, 1, 1));
    assert(isClose(Ray(Vector3(-2, 0.5f, 0.5f), Vector3(1, 0, 0)).intersectionTime(box), 2));
    assert(Ray(Vector3(-2, 0.5f, 0.5f), Vector3(-1, 0, 0)).intersectionTime(box) == float.infinity);
    assert(Ray(Vector3(0.5f, 0.5f, 0.5f), Vector3(0, 0, 1)).intersectionTime(box) == 0);
    assert(Ray(Vector3(-2, 3, 0.5f), Vector3(1, 0, 0)).intersectionTime(box) == float.infinity);
    assert(Vector3(1, -5, 2).primaryAxis == 1 && Vector3(3, 3, 3).primaryAxis == 2);
    assert(fuzzyEq(1, 1.000001) && fuzzyNe(1, 1.1));
}

// ---------------------------------------------------------------------------
// Reading and writing, as the vmap files store them
// ---------------------------------------------------------------------------

import dmangos.bytes : ByteReader, ByteWriter;

/// Three little-endian floats.
void putVector(ref ByteWriter w, const Vector3 v)
{
    w.put(v.x);
    w.put(v.y);
    w.put(v.z);
}

/// ditto
Vector3 readVector(ref ByteReader r)
{
    Vector3 v;
    v.x = r.read!float;
    v.y = r.read!float;
    v.z = r.read!float;
    return v;
}

/// Low corner, then high corner.
void putBox(ref ByteWriter w, const AABox b)
{
    putVector(w, b.lo);
    putVector(w, b.hi);
}

/// ditto
AABox readBox(ref ByteReader r)
{
    const lo = readVector(r);
    return AABox(lo, readVector(r));
}
