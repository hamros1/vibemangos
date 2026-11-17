// dmangos's C interface to Recast and Detour (thirdparty/recastnavigation, zlib licence):
// building a map tile's navigation mesh from its triangles (the extractor), and loading tiles
// and finding paths over them (the world server). See source/dmangos/navigation.d.
//
// Coordinates are Recast's: x and z across, y up. The D side converts from the world's.

#include <cstring>
#include <new>

#include "Recast.h"
#include "DetourAlloc.h"
#include "DetourNavMesh.h"
#include "DetourNavMeshBuilder.h"
#include "DetourNavMeshQuery.h"

extern "C" {

// What a tile is built with (MoveMapGen's MapBuilder::buildMoveMapTile).
struct dmBuildConfig
{
    float cellSize;            // cs and ch: yards per cell
    float walkableSlope;       // degrees
    int walkableHeight;        // cells
    int walkableClimb;         // cells
    int walkableRadius;        // cells
    int subTileCells;          // cells per side of the pieces a tile is built in
    float maxSimplificationError;
    int minRegionArea;         // cells
    int mergeRegionArea;       // cells
    float detailSampleDist;    // yards
    float detailSampleMaxError;
    float bmin[3], bmax[3];    // the tile, in yards; y is filled from the triangles
    int tileX, tileY;          // its place in the navigation mesh
};

// Builds one tile's navigation mesh data (dtCreateNavMeshData) from triangles: `verts` holds
// `nverts` points (x, y, z), `tris` `ntris` triples of indexes, `areas` an area per triangle (0: not
// walkable). Steep triangles of a walkable area are made unwalkable here. The area becomes the
// polygon's area and its flags (1 << (area - 1)). Returns 0 and sets *data (dmnav_free it) and
// *size, or a negative step number on failure; 1 if the tile has nothing walkable.
int dmnav_build_tile(const dmBuildConfig* c, const float* verts, int nverts, const int* tris,
    const unsigned char* areas, int ntris, unsigned char** data, int* size)
{
    *data = nullptr;
    *size = 0;
    rcContext ctx(false);

    float bmin[3], bmax[3];
    rcCalcBounds(verts, nverts, bmin, bmax);
    bmin[0] = c->bmin[0]; bmin[2] = c->bmin[2];
    bmax[0] = c->bmax[0]; bmax[2] = c->bmax[2];

    unsigned char* walkable = new (std::nothrow) unsigned char[ntris > 0 ? ntris : 1];
    if (!walkable)
        return -1;
    std::memcpy(walkable, areas, ntris);
    rcClearUnwalkableTriangles(&ctx, c->walkableSlope, verts, nverts, tris, ntris, walkable);

    const int border = c->walkableRadius + 3;
    const int tileCells = int((bmax[0] - bmin[0]) / c->cellSize + 0.5f);
    const int pieces = (tileCells + c->subTileCells - 1) / c->subTileCells;
    rcPolyMesh** meshes = new rcPolyMesh*[pieces * pieces]();
    rcPolyMeshDetail** details = new rcPolyMeshDetail*[pieces * pieces]();
    int built = 0;
    int result = 0;

    for (int py = 0; py < pieces && result == 0; ++py)
        for (int px = 0; px < pieces && result == 0; ++px)
        {
            rcConfig cfg;
            std::memset(&cfg, 0, sizeof(cfg));
            cfg.cs = c->cellSize;
            cfg.ch = c->cellSize;
            cfg.walkableSlopeAngle = c->walkableSlope;
            cfg.walkableHeight = c->walkableHeight;
            cfg.walkableClimb = c->walkableClimb;
            cfg.walkableRadius = c->walkableRadius;
            cfg.maxEdgeLen = c->subTileCells + 1;
            cfg.maxSimplificationError = c->maxSimplificationError;
            cfg.minRegionArea = c->minRegionArea;
            cfg.mergeRegionArea = c->mergeRegionArea;
            cfg.maxVertsPerPoly = DT_VERTS_PER_POLYGON;
            cfg.tileSize = c->subTileCells;
            cfg.borderSize = border;
            cfg.detailSampleDist = c->detailSampleDist;
            cfg.detailSampleMaxError = c->detailSampleMaxError;
            cfg.width = cfg.tileSize + 2 * border;
            cfg.height = cfg.tileSize + 2 * border;
            const float piece = c->subTileCells * c->cellSize;
            cfg.bmin[0] = bmin[0] + px * piece - border * c->cellSize;
            cfg.bmin[1] = bmin[1];
            cfg.bmin[2] = bmin[2] + py * piece - border * c->cellSize;
            cfg.bmax[0] = bmin[0] + (px + 1) * piece + border * c->cellSize;
            cfg.bmax[1] = bmax[1];
            cfg.bmax[2] = bmin[2] + (py + 1) * piece + border * c->cellSize;

            rcHeightfield* solid = rcAllocHeightfield();
            if (!solid || !rcCreateHeightfield(&ctx, *solid, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch))
            {
                rcFreeHeightField(solid);
                result = -2;
                break;
            }
            if (!rcRasterizeTriangles(&ctx, verts, nverts, tris, walkable, ntris, *solid, cfg.walkableClimb))
            {
                rcFreeHeightField(solid);
                result = -3;
                break;
            }
            rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *solid);
            rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *solid);
            rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *solid);

            rcCompactHeightfield* chf = rcAllocCompactHeightfield();
            const bool compact = chf && rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *solid, *chf);
            rcFreeHeightField(solid);
            if (!compact)
            {
                rcFreeCompactHeightfield(chf);
                result = -4;
                break;
            }
            if (!rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf) || !rcBuildDistanceField(&ctx, *chf)
                || !rcBuildRegions(&ctx, *chf, cfg.borderSize, cfg.minRegionArea, cfg.mergeRegionArea))
            {
                rcFreeCompactHeightfield(chf);
                result = -5;
                break;
            }
            rcContourSet* contours = rcAllocContourSet();
            if (!contours || !rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *contours))
            {
                rcFreeContourSet(contours);
                rcFreeCompactHeightfield(chf);
                result = -6;
                break;
            }
            rcPolyMesh* mesh = rcAllocPolyMesh();
            if (!mesh || !rcBuildPolyMesh(&ctx, *contours, cfg.maxVertsPerPoly, *mesh))
            {
                rcFreePolyMesh(mesh);
                rcFreeContourSet(contours);
                rcFreeCompactHeightfield(chf);
                result = -7;
                break;
            }
            rcPolyMeshDetail* detail = rcAllocPolyMeshDetail();
            if (!detail || !rcBuildPolyMeshDetail(&ctx, *mesh, *chf, cfg.detailSampleDist, cfg.detailSampleMaxError, *detail))
            {
                rcFreePolyMeshDetail(detail);
                rcFreePolyMesh(mesh);
                rcFreeContourSet(contours);
                rcFreeCompactHeightfield(chf);
                result = -8;
                break;
            }
            rcFreeContourSet(contours);
            rcFreeCompactHeightfield(chf);
            meshes[built] = mesh;
            details[built] = detail;
            ++built;
        }

    rcPolyMesh* merged = nullptr;
    rcPolyMeshDetail* mergedDetail = nullptr;
    if (result == 0)
    {
        merged = rcAllocPolyMesh();
        mergedDetail = rcAllocPolyMeshDetail();
        if (!merged || !mergedDetail || !rcMergePolyMeshes(&ctx, meshes, built, *merged)
            || !rcMergePolyMeshDetails(&ctx, details, built, *mergedDetail))
            result = -9;
    }
    for (int i = 0; i < built; ++i)
    {
        rcFreePolyMesh(meshes[i]);
        rcFreePolyMeshDetail(details[i]);
    }
    delete[] meshes;
    delete[] details;
    delete[] walkable;

    if (result == 0 && merged->npolys == 0)
        result = 1;
    if (result == 0)
    {
        for (int i = 0; i < merged->npolys; ++i)
            merged->flags[i] = merged->areas[i] ? (unsigned short)(1u << (merged->areas[i] - 1)) : 0;

        dtNavMeshCreateParams p;
        std::memset(&p, 0, sizeof(p));
        p.verts = merged->verts;
        p.vertCount = merged->nverts;
        p.polys = merged->polys;
        p.polyAreas = merged->areas;
        p.polyFlags = merged->flags;
        p.polyCount = merged->npolys;
        p.nvp = merged->nvp;
        p.detailMeshes = mergedDetail->meshes;
        p.detailVerts = mergedDetail->verts;
        p.detailVertsCount = mergedDetail->nverts;
        p.detailTris = mergedDetail->tris;
        p.detailTriCount = mergedDetail->ntris;
        p.walkableHeight = c->walkableHeight * c->cellSize;
        p.walkableRadius = c->walkableRadius * c->cellSize;
        p.walkableClimb = c->walkableClimb * c->cellSize;
        p.tileX = c->tileX;
        p.tileY = c->tileY;
        p.tileLayer = 0;
        rcVcopy(p.bmin, merged->bmin);
        rcVcopy(p.bmax, merged->bmax);
        p.cs = c->cellSize;
        p.ch = c->cellSize;
        p.buildBvTree = true;
        if (!dtCreateNavMeshData(&p, data, size))
            result = -10;
    }
    rcFreePolyMesh(merged);
    rcFreePolyMeshDetail(mergedDetail);
    return result;
}

// Frees what dmnav_build_tile returned.
void dmnav_free(void* p)
{
    dtFree(p);
}

// A navigation mesh of tiles `tileWidth` square from `origin`; null on failure.
void* dmnav_mesh_create(const float* origin, float tileWidth, int maxTiles, int maxPolys)
{
    dtNavMeshParams params;
    std::memset(&params, 0, sizeof(params));
    rcVcopy(params.orig, origin);
    params.tileWidth = tileWidth;
    params.tileHeight = tileWidth;
    params.maxTiles = maxTiles;
    params.maxPolys = maxPolys;
    dtNavMesh* mesh = dtAllocNavMesh();
    if (!mesh || dtStatusFailed(mesh->init(&params)))
    {
        dtFreeNavMesh(mesh);
        return nullptr;
    }
    return mesh;
}

void dmnav_mesh_free(void* mesh)
{
    dtFreeNavMesh(static_cast<dtNavMesh*>(mesh));
}

// Adds a tile (a copy of `data`); 0 on success.
int dmnav_mesh_add_tile(void* mesh, const unsigned char* data, int size)
{
    unsigned char* copy = static_cast<unsigned char*>(dtAlloc(size, DT_ALLOC_PERM));
    if (!copy)
        return -1;
    std::memcpy(copy, data, size);
    const dtStatus status = static_cast<dtNavMesh*>(mesh)->addTile(copy, size, DT_TILE_FREE_DATA, 0, nullptr);
    if (dtStatusFailed(status))
    {
        dtFree(copy);
        return -2;
    }
    return 0;
}

// Removes the tile at (tileX, tileY), if there is one.
void dmnav_mesh_remove_tile(void* mesh, int tileX, int tileY)
{
    dtNavMesh* m = static_cast<dtNavMesh*>(mesh);
    const dtTileRef ref = m->getTileRefAt(tileX, tileY, 0);
    if (ref)
        m->removeTile(ref, nullptr, nullptr);
}

// A query over `mesh` (one per thread); null on failure.
void* dmnav_query_create(void* mesh, int maxNodes)
{
    dtNavMeshQuery* query = dtAllocNavMeshQuery();
    if (!query || dtStatusFailed(query->init(static_cast<dtNavMesh*>(mesh), maxNodes)))
    {
        dtFreeNavMeshQuery(query);
        return nullptr;
    }
    return query;
}

void dmnav_query_free(void* query)
{
    dtFreeNavMeshQuery(static_cast<dtNavMeshQuery*>(query));
}

// The way from `start` to `end` over polygons with any of `include` and none of `exclude`, as at
// most `maxPoints` corners in `points` (x, y, z each), the first `start` and the last `end` or
// the nearest place to it that can be reached. Returns the number of corners; 0 if either end is
// off the mesh (within `extents` of it). *partial says whether the end could not be reached.
int dmnav_find_path(void* query, const float* start, const float* end, const float* extents,
    unsigned short include, unsigned short exclude, float* points, int maxPoints, int* partial)
{
    enum { maxPolys = 1024 };
    dtNavMeshQuery* q = static_cast<dtNavMeshQuery*>(query);
    dtQueryFilter filter;
    filter.setIncludeFlags(include);
    filter.setExcludeFlags(exclude);
    *partial = 0;

    dtPolyRef startRef = 0, endRef = 0;
    float startPoint[3], endPoint[3];
    if (dtStatusFailed(q->findNearestPoly(start, extents, &filter, &startRef, startPoint)) || !startRef)
        return 0;
    if (dtStatusFailed(q->findNearestPoly(end, extents, &filter, &endRef, endPoint)) || !endRef)
        return 0;

    dtPolyRef polys[maxPolys];
    int polyCount = 0;
    const dtStatus found = q->findPath(startRef, endRef, startPoint, endPoint, &filter, polys, &polyCount, maxPolys);
    if (dtStatusFailed(found) || polyCount == 0)
        return 0;
    float target[3];
    rcVcopy(target, endPoint);
    if (polys[polyCount - 1] != endRef)
    {
        *partial = 1;
        bool overPoly = false;
        q->closestPointOnPoly(polys[polyCount - 1], endPoint, target, &overPoly);
    }
    int count = 0;
    if (dtStatusFailed(q->findStraightPath(startPoint, target, polys, polyCount, points, nullptr, nullptr,
            &count, maxPoints, 0)))
        return 0;
    return count;
}

// The height of the mesh at (x, z) nearest `point` (within `extents`); 0 if none, 1 with *height.
int dmnav_height(void* query, const float* point, const float* extents, unsigned short include, float* height)
{
    dtNavMeshQuery* q = static_cast<dtNavMeshQuery*>(query);
    dtQueryFilter filter;
    filter.setIncludeFlags(include);
    dtPolyRef ref = 0;
    float nearest[3];
    if (dtStatusFailed(q->findNearestPoly(point, extents, &filter, &ref, nearest)) || !ref)
        return 0;
    *height = nearest[1];
    return 1;
}

}
