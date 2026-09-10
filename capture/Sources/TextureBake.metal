#include <metal_stdlib>
using namespace metal;

// テクスチャ焼き込みの GPU 実装。
//
// Mac 側の numpy 実装では 605 フレームの投影・合成に 53 秒かかっていた。
// 各テクセルの処理は完全に独立なので、GPU と相性が良い。
//
// このパイプライン固有の利点として、遮蔽判定に LiDAR 深度マップをそのまま使える。
// 通常のテクスチャ焼き込みはカメラごとにメッシュを深度レンダリングして
// 可視判定するが、ここでは実測深度と比較するだけで済む。

struct BakeUniforms {
    float4x4 worldToCamera;   // ARKit world -> OpenCV カメラ座標
    float fx, fy, cx, cy;     // video 解像度基準の内部パラメータ
    uint videoWidth, videoHeight;
    uint depthWidth, depthHeight;
    uint atlasSize;
    float depthTolerance;     // 実測深度との許容差(m)
    float minFacing;          // 正対度の下限
    float viewExponent;       // 大きいほど「最良の1視点」に近づき鮮鋭になる
    float sharpness;          // フレームのシャープネス（中央値で正規化済み）
    uint confidenceMin;
};

// 1 フレーム分を全テクセルに投影して重み付き加算する。
kernel void bakeFrame(texture2d<float, access::read>       rgb        [[texture(0)]],
                      texture2d<float, access::read>       depth      [[texture(1)]],
                      texture2d<uint,  access::read>       confidence [[texture(2)]],
                      device const float3                 *positions  [[buffer(0)]],
                      device const float3                 *normals    [[buffer(1)]],
                      device const uchar                  *valid      [[buffer(2)]],
                      device float                        *accum      [[buffer(3)]],  // RGB * w
                      device float                        *weight     [[buffer(4)]],
                      constant BakeUniforms               &u          [[buffer(5)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.atlasSize || gid.y >= u.atlasSize) return;
    uint idx = gid.y * u.atlasSize + gid.x;
    if (valid[idx] == 0) return;

    float3 world = positions[idx];
    float4 cam4 = u.worldToCamera * float4(world, 1.0);
    float3 cam = cam4.xyz;
    if (cam.z <= 0.05) return;

    float uu = u.fx * cam.x / cam.z + u.cx;
    float vv = u.fy * cam.y / cam.z + u.cy;
    if (uu < 0 || uu >= float(u.videoWidth) || vv < 0 || vv >= float(u.videoHeight)) return;

    // 正対度。カメラから見て面が寝ているほど信用しない。
    float3 n = (u.worldToCamera * float4(normals[idx], 0.0)).xyz;
    float3 dir = normalize(cam);
    float facing = -dot(n, dir);
    if (facing <= u.minFacing) return;

    // LiDAR 深度で遮蔽を判定する
    uint dx = min(uint(uu * float(u.depthWidth) / float(u.videoWidth)), u.depthWidth - 1);
    uint dy = min(uint(vv * float(u.depthHeight) / float(u.videoHeight)), u.depthHeight - 1);
    uint conf = confidence.read(uint2(dx, dy)).r;
    if (conf < u.confidenceMin) return;
    float measured = depth.read(uint2(dx, dy)).r;
    if (!isfinite(measured) || fabs(measured - cam.z) >= u.depthTolerance) return;

    uint ix = min(uint(uu), u.videoWidth - 1);
    uint iy = min(uint(vv), u.videoHeight - 1);
    float3 color = rgb.read(uint2(ix, iy)).rgb * 255.0;

    // 1 テクセル 1 スレッドで、各スレッドは自分の idx にしか書かない。
    // 競合は起こり得ないので atomic は不要。
    // （float の atomic 加算は Apple7 / A14 以降でないと保証されず、
    //   A12Z では正しく動かない。実際にこれでアトラスがノイズになった。）
    float w = pow(facing, u.viewExponent) / max(cam.z, 0.2) * u.sharpness;
    accum[idx * 3 + 0] += color.r * w;
    accum[idx * 3 + 1] += color.g * w;
    accum[idx * 3 + 2] += color.b * w;
    weight[idx] += w;
}

// 重み付き和を割って最終的なテクスチャにする。
kernel void resolveAtlas(device const float   *accum   [[buffer(0)]],
                         device const float   *weight  [[buffer(1)]],
                         device uchar4        *outTex  [[buffer(2)]],
                         constant uint        &size    [[buffer(3)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size || gid.y >= size) return;
    uint idx = gid.y * size + gid.x;
    float w = weight[idx];
    if (w <= 0.0) {
        outTex[idx] = uchar4(0, 0, 0, 0);   // 未着色。alpha=0 で穴埋め対象を示す
        return;
    }
    float3 c = float3(accum[idx * 3 + 0], accum[idx * 3 + 1], accum[idx * 3 + 2]) / w;
    float3 q = clamp(c, 0.0, 255.0);
    outTex[idx] = uchar4(uchar(q.r), uchar(q.g), uchar(q.b), 255);
}

// 未着色テクセルを近傍から埋める。
//
// UV チャートの縁は、テクスチャ補間時に隣のチャートの色を拾って継ぎ目として
// 見えるため、少なくとも数テクセルは外側へ広げておく必要がある。
kernel void dilateAtlas(device const uchar4 *src  [[buffer(0)]],
                        device uchar4       *dst  [[buffer(1)]],
                        constant uint       &size [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size || gid.y >= size) return;
    uint idx = gid.y * size + gid.x;
    uchar4 here = src[idx];
    if (here.a != 0) { dst[idx] = here; return; }

    float3 sum = float3(0);
    float count = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nx = int(gid.x) + dx, ny = int(gid.y) + dy;
            if (nx < 0 || ny < 0 || nx >= int(size) || ny >= int(size)) continue;
            uchar4 s = src[uint(ny) * size + uint(nx)];
            if (s.a == 0) continue;
            sum += float3(s.rgb);
            count += 1;
        }
    }
    if (count > 0) {
        float3 m = sum / count;
        dst[idx] = uchar4(uchar(m.r), uchar(m.g), uchar(m.b), 255);
    } else {
        dst[idx] = uchar4(0, 0, 0, 0);
    }
}

// UV 空間で三角形をラスタライズし、各テクセルの world 座標と法線を求める。
//
// 三角形ごとに 1 スレッドを割り当て、そのバウンディングボックスを走査する。
// 三角形は十数テクセルしか覆わないので、走査量は小さい。
struct RasterUniforms {
    uint atlasSize;
    uint triangleCount;
};

kernel void rasterizeAtlas(device const float3 *positions [[buffer(0)]],  // 展開後の頂点
                           device const float2 *uvs       [[buffer(1)]],
                           device const uint   *indices   [[buffer(2)]],
                           device float3       *outPos    [[buffer(3)]],
                           device float3       *outNrm    [[buffer(4)]],
                           device uchar        *outValid  [[buffer(5)]],
                           constant RasterUniforms &u     [[buffer(6)]],
                           uint tid [[thread_position_in_grid]])
{
    if (tid >= u.triangleCount) return;
    uint i0 = indices[tid * 3 + 0], i1 = indices[tid * 3 + 1], i2 = indices[tid * 3 + 2];

    float S = float(u.atlasSize);
    float2 a = uvs[i0] * S, b = uvs[i1] * S, c = uvs[i2] * S;
    float3 pa = positions[i0], pb = positions[i1], pc = positions[i2];
    float3 nrm = normalize(cross(pb - pa, pc - pa));

    float det = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
    if (fabs(det) < 1e-9) return;

    int x0 = max(0, int(floor(min(min(a.x, b.x), c.x))));
    int x1 = min(int(u.atlasSize), int(ceil(max(max(a.x, b.x), c.x))));
    int y0 = max(0, int(floor(min(min(a.y, b.y), c.y))));
    int y1 = min(int(u.atlasSize), int(ceil(max(max(a.y, b.y), c.y))));

    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            float px = float(x) + 0.5, py = float(y) + 0.5;
            float w0 = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / det;
            float w1 = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / det;
            float w2 = 1.0 - w0 - w1;
            // 継ぎ目のにじみを防ぐため、わずかに外側まで塗る
            if (w0 < -0.002 || w1 < -0.002 || w2 < -0.002) continue;
            uint idx = uint(y) * u.atlasSize + uint(x);
            outPos[idx] = w0 * pa + w1 * pb + w2 * pc;
            outNrm[idx] = nrm;
            outValid[idx] = 1;
        }
    }
}

// MARK: - 頂点カラー
//
// **UV 展開（xatlas）を丸ごと省くための経路。**
//
// 展開はこの端末で焼き込み時間の 97%（実測 55 秒のうち 54.5 秒）を占める。
// 色を頂点に持たせればアトラスが不要になり、投影だけで済む。
// 色の解像度はメッシュの辺の長さ（実測で約 2cm）に落ちる。
//
// `atlasSize` を頂点数として使う。専用の uniform を増やさないため。

kernel void bakeFrameVertex(texture2d<float, access::read>       rgb        [[texture(0)]],
                            texture2d<float, access::read>       depth      [[texture(1)]],
                            texture2d<uint,  access::read>       confidence [[texture(2)]],
                            device const float3                 *positions  [[buffer(0)]],
                            device const float3                 *normals    [[buffer(1)]],
                            device float                        *accum      [[buffer(2)]],  // RGB * w
                            device float                        *weight     [[buffer(3)]],
                            constant BakeUniforms               &u          [[buffer(4)]],
                            uint gid [[thread_position_in_grid]])
{
    if (gid >= u.atlasSize) return;   // atlasSize = 頂点数

    float4 cam4 = u.worldToCamera * float4(positions[gid], 1.0);
    float3 cam = cam4.xyz;
    if (cam.z <= 0.05) return;

    float uu = u.fx * cam.x / cam.z + u.cx;
    float vv = u.fy * cam.y / cam.z + u.cy;
    if (uu < 0 || uu >= float(u.videoWidth) || vv < 0 || vv >= float(u.videoHeight)) return;

    float3 n = (u.worldToCamera * float4(normals[gid], 0.0)).xyz;
    float3 dir = normalize(cam);
    float facing = -dot(n, dir);
    if (facing <= u.minFacing) return;

    uint dx = min(uint(uu * float(u.depthWidth) / float(u.videoWidth)), u.depthWidth - 1);
    uint dy = min(uint(vv * float(u.depthHeight) / float(u.videoHeight)), u.depthHeight - 1);
    uint conf = confidence.read(uint2(dx, dy)).r;
    if (conf < u.confidenceMin) return;
    float measured = depth.read(uint2(dx, dy)).r;
    if (!isfinite(measured) || fabs(measured - cam.z) >= u.depthTolerance) return;

    uint ix = min(uint(uu), u.videoWidth - 1);
    uint iy = min(uint(vv), u.videoHeight - 1);
    float3 color = rgb.read(uint2(ix, iy)).rgb * 255.0;

    // 1 頂点 1 スレッド。自分の gid にしか書かないので atomic は不要
    // （A12Z では float の atomic 加算が保証されない）。
    float w = pow(facing, u.viewExponent) / max(cam.z, 0.2) * u.sharpness;
    accum[gid * 3 + 0] += color.r * w;
    accum[gid * 3 + 1] += color.g * w;
    accum[gid * 3 + 2] += color.b * w;
    weight[gid] += w;
}

// 重み付き和を割って頂点カラーにする。**どのフレームからも見えなかった
// 頂点は隣から埋められない**（アトラスと違って近傍の概念がない）ので、
// 灰色を入れて `unfilled` として数える。
kernel void resolveVertexColors(device const float   *accum  [[buffer(0)]],
                                device const float   *weight [[buffer(1)]],
                                device uchar4        *outCol [[buffer(2)]],
                                constant uint        &count  [[buffer(3)]],
                                uint gid [[thread_position_in_grid]])
{
    if (gid >= count) return;
    float w = weight[gid];
    if (w <= 0.0) {
        outCol[gid] = uchar4(128, 128, 128, 0);   // alpha=0 が未着色の印
        return;
    }
    float3 c = float3(accum[gid * 3 + 0], accum[gid * 3 + 1], accum[gid * 3 + 2]) / w;
    float3 q = clamp(c, 0.0, 255.0);
    outCol[gid] = uchar4(uchar(q.r), uchar(q.g), uchar(q.b), 255);
}
