#import "XAtlasBridge.h"
#include "xatlas.h"
#include <vector>

@implementation MDRAtlasResult {
    std::vector<uint32_t> _mapping;
    std::vector<uint32_t> _indices;
    std::vector<float> _uvs;
}

- (instancetype)initWithMapping:(std::vector<uint32_t> &&)mapping
                        indices:(std::vector<uint32_t> &&)indices
                            uvs:(std::vector<float> &&)uvs
                     chartCount:(NSUInteger)chartCount {
    if ((self = [super init])) {
        _mapping = std::move(mapping);
        _indices = std::move(indices);
        _uvs = std::move(uvs);
        _chartCount = chartCount;
    }
    return self;
}

- (NSUInteger)vertexCount { return _mapping.size(); }
- (NSUInteger)indexCount { return _indices.size(); }
- (const uint32_t *)vertexMapping { return _mapping.data(); }
- (const uint32_t *)indices { return _indices.data(); }
- (const float *)uvs { return _uvs.data(); }
@end

@implementation MDRXAtlas

+ (MDRAtlasResult *)parametrizePositions:(const float *)positions
                             vertexCount:(NSUInteger)vertexCount
                                 indices:(const uint32_t *)indices
                              indexCount:(NSUInteger)indexCount
                              resolution:(uint32_t)resolution {
    if (vertexCount == 0 || indexCount == 0) return nil;

    xatlas::Atlas *atlas = xatlas::Create();

    xatlas::MeshDecl decl;
    decl.vertexCount = (uint32_t)vertexCount;
    decl.vertexPositionData = positions;
    decl.vertexPositionStride = sizeof(float) * 3;
    decl.indexCount = (uint32_t)indexCount;
    decl.indexData = indices;
    decl.indexFormat = xatlas::IndexFormat::UInt32;

    if (xatlas::AddMesh(atlas, decl) != xatlas::AddMeshError::Success) {
        xatlas::Destroy(atlas);
        return nil;
    }

    xatlas::PackOptions pack;
    // アトラスを 1 枚に収める。複数枚になると GLB 側でマテリアルが増えて扱いが面倒。
    pack.resolution = resolution;
    pack.maxChartSize = resolution - 2;
    pack.bruteForce = false;
    pack.padding = 2;   // チャート境界のにじみを防ぐ

    xatlas::Generate(atlas, xatlas::ChartOptions(), pack);

    if (atlas->meshCount == 0) {
        xatlas::Destroy(atlas);
        return nil;
    }

    const xatlas::Mesh &mesh = atlas->meshes[0];
    std::vector<uint32_t> mapping(mesh.vertexCount);
    std::vector<float> uvs(mesh.vertexCount * 2);
    const float w = (float)atlas->width;
    const float h = (float)atlas->height;
    for (uint32_t i = 0; i < mesh.vertexCount; i++) {
        mapping[i] = mesh.vertexArray[i].xref;
        uvs[i * 2 + 0] = mesh.vertexArray[i].uv[0] / w;
        uvs[i * 2 + 1] = mesh.vertexArray[i].uv[1] / h;
    }
    std::vector<uint32_t> outIndices(mesh.indexArray, mesh.indexArray + mesh.indexCount);
    NSUInteger charts = atlas->chartCount;

    xatlas::Destroy(atlas);
    return [[MDRAtlasResult alloc] initWithMapping:std::move(mapping)
                                           indices:std::move(outIndices)
                                               uvs:std::move(uvs)
                                        chartCount:charts];
}
@end
