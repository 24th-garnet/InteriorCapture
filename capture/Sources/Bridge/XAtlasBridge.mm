#import "XAtlasBridge.h"
#include "xatlas.h"
#include <os/proc.h>
#include <thread>
#include <mach/mach_time.h>

// 段階ごとの時間と残メモリ。xatlas の進捗コールバックは任意のスレッドから
// 呼ばれるが、ここで触るのは単調増加の観測値だけなので素朴に書く。
namespace {
struct Probe {
    double start[4] = {-1, -1, -1, -1};
    double end[4] = {0, 0, 0, 0};
    uint64_t minAvail = UINT64_MAX;
    double t0 = 0;
};

double nowSec() {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

bool onProgress(xatlas::ProgressCategory cat, int pct, void *user) {
    Probe *p = (Probe *)user;
    int i = (int)cat;
    if (i < 0 || i > 3) return true;
    double t = nowSec() - p->t0;
    if (p->start[i] < 0) p->start[i] = t;
    p->end[i] = t;
    uint64_t avail = os_proc_available_memory();
    if (avail > 0 && avail < p->minAvail) p->minAvail = avail;
    return true;
}
}  // namespace
#include <vector>
#include <cmath>

@implementation MDRAtlasResult {
    std::vector<uint32_t> _mapping;
    std::vector<uint32_t> _indices;
    std::vector<float> _uvs;
}

- (instancetype)initWithMapping:(std::vector<uint32_t> &&)mapping
                        indices:(std::vector<uint32_t> &&)indices
                            uvs:(std::vector<float> &&)uvs
                     chartCount:(NSUInteger)chartCount
                          width:(NSUInteger)width
                         height:(NSUInteger)height
                     atlasCount:(NSUInteger)atlasCount
                          probe:(const Probe &)probe
                availableBefore:(uint64_t)availableBefore
                 availableAfter:(uint64_t)availableAfter {
    if ((self = [super init])) {
        _addMeshSec = probe.start[0] < 0 ? 0 : probe.end[0] - probe.start[0];
        _computeChartsSec = probe.start[1] < 0 ? 0 : probe.end[1] - probe.start[1];
        _packChartsSec = probe.start[2] < 0 ? 0 : probe.end[2] - probe.start[2];
        _buildOutputSec = probe.start[3] < 0 ? 0 : probe.end[3] - probe.start[3];
        _hardwareConcurrency = std::thread::hardware_concurrency();
        _availableMemoryBefore = availableBefore;
        _availableMemoryAfter = availableAfter;
        _availableMemoryMin = probe.minAvail == UINT64_MAX ? 0 : probe.minAvail;
        _mapping = std::move(mapping);
        _indices = std::move(indices);
        _uvs = std::move(uvs);
        _chartCount = chartCount;
        _atlasWidth = width;
        _atlasHeight = height;
        _atlasCount = atlasCount;
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

+ (MDRAtlasResult *)parametrizePositions:(const void *)positions
                             vertexCount:(NSUInteger)vertexCount
                                  stride:(NSUInteger)stride
                                 indices:(const uint32_t *)indices
                              indexCount:(NSUInteger)indexCount
                              resolution:(uint32_t)resolution {
    auto vertexAt = [positions, stride](uint32_t i) -> const float * {
        return (const float *)((const uint8_t *)positions + (size_t)i * stride);
    };
    if (vertexCount == 0 || indexCount == 0) return nil;

    Probe probe;
    probe.t0 = nowSec();
    const uint64_t availBefore = os_proc_available_memory();

    xatlas::Atlas *atlas = xatlas::Create();
    xatlas::SetProgressCallback(atlas, onProgress, &probe);

    xatlas::MeshDecl decl;
    decl.vertexCount = (uint32_t)vertexCount;
    decl.vertexPositionData = positions;
    decl.vertexPositionStride = (uint32_t)stride;
    decl.indexCount = (uint32_t)indexCount;
    decl.indexData = indices;
    decl.indexFormat = xatlas::IndexFormat::UInt32;

    if (xatlas::AddMesh(atlas, decl) != xatlas::AddMeshError::Success) {
        xatlas::Destroy(atlas);
        return nil;
    }

    // **resolution 指定では寸法を制御できない。**
    // xatlas は resolution から texelsPerUnit を推定するだけで、結果の寸法は
    // 保証されない。同じ設定でも 2360 になったり 4958 になったりする（実測）。
    // アトラスが想定より大きくなると 1 テクセルの実面積が小さくなり、
    // 同じフレーム数では埋まらないテクセルが増えて黒抜けになる
    // （4958 のとき 1 テクセル 1.89mm で未着色 17.3%）。
    //
    // 表面積から texelsPerUnit を直接求めれば寸法を制御できる。
    //   texelsPerUnit = sqrt(目標テクセル数 * 充填率 / 表面積)
    // 充填率は実測で概ね 85%。0.9 倍して安全側に寄せる。
    double area = 0.0;
    for (NSUInteger t = 0; t + 2 < indexCount; t += 3) {
        const float *a = vertexAt(indices[t]);
        const float *b = vertexAt(indices[t + 1]);
        const float *c = vertexAt(indices[t + 2]);
        double ux = b[0]-a[0], uy = b[1]-a[1], uz = b[2]-a[2];
        double vx = c[0]-a[0], vy = c[1]-a[1], vz = c[2]-a[2];
        double cx = uy*vz - uz*vy, cy = uz*vx - ux*vz, cz = ux*vy - uy*vx;
        area += 0.5 * sqrt(cx*cx + cy*cy + cz*cz);
    }

    xatlas::PackOptions pack;
    if (area > 1e-6) {
        pack.texelsPerUnit = (float)(sqrt((double)resolution * resolution * 0.80 / area) * 0.9);
    } else {
        pack.resolution = resolution;
    }
    pack.bruteForce = false;
    pack.padding = 2;   // チャート境界のにじみを防ぐ

    // **チャート成長の反復を止める。** 既定の 1 回でも展開時間が倍になるのに、
    // 得られる品質差がない。実測（179,022 面）:
    //
    //   既定      20.5s  テクセル密度のばらつき 0.93〜1.02 倍  1テクセル 4.68mm
    //   反復なし   9.9s  同 0.93〜1.01 倍                     同 4.85mm
    //
    // 焼き込み時間の 97% が UV 展開なので、ここが唯一のレバーになる。
    // チャートを粗くまとめる方向（maxCost / 各種 weight）は逆効果だった。
    xatlas::ChartOptions chart;
    chart.maxIterations = 0;
    xatlas::Generate(atlas, chart, pack);

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
    NSUInteger aw = atlas->width, ah = atlas->height, ac = atlas->atlasCount;

    xatlas::Destroy(atlas);
    const uint64_t availAfter = os_proc_available_memory();
    return [[MDRAtlasResult alloc] initWithMapping:std::move(mapping)
                                           indices:std::move(outIndices)
                                               uvs:std::move(uvs)
                                        chartCount:charts
                                             width:aw
                                            height:ah
                                        atlasCount:ac
                                             probe:probe
                                   availableBefore:availBefore
                                    availableAfter:availAfter];
}
@end
