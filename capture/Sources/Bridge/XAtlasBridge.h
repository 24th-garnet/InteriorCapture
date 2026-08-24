#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// xatlas（C++）を Swift から使うための薄いブリッジ。
///
/// xatlas は依存のない単一ファイルの C++ ライブラリで、iOS でもそのまま通る。
/// メッシュを chart に分割し、UV を展開してアトラスに詰める。
@interface MDRAtlasResult : NSObject
/// 展開後の頂点数。UV の継ぎ目で元の頂点が複製されるため入力より増える。
@property (nonatomic, readonly) NSUInteger vertexCount;
@property (nonatomic, readonly) NSUInteger indexCount;
/// 各出力頂点が元メッシュのどの頂点由来かを示す索引（vertexCount 個）。
@property (nonatomic, readonly) const uint32_t *vertexMapping;
/// 三角形インデックス（indexCount 個）。
@property (nonatomic, readonly) const uint32_t *indices;
/// UV 座標。0..1 に正規化済み（vertexCount * 2 個）。
@property (nonatomic, readonly) const float *uvs;
@property (nonatomic, readonly) NSUInteger chartCount;
/// xatlas が実際に生成したアトラスの寸法。**要求した resolution とは一致しない。**
/// xatlas は resolution を上限ではなく目安として扱い、収まらなければ大きくする。
@property (nonatomic, readonly) NSUInteger atlasWidth;
@property (nonatomic, readonly) NSUInteger atlasHeight;
/// アトラスのページ数。2 以上なら 1 枚のテクスチャには収まっていない。
@property (nonatomic, readonly) NSUInteger atlasCount;
@end

@interface MDRXAtlas : NSObject

/// メッシュの UV を展開する。
/// @param positions 頂点座標。連続する 3 float が xyz。
/// @param stride 頂点 1 個あたりのバイト数。**Swift の SIMD3<Float> は 16 バイト**
///   なので 12 ではなく 16 を渡すこと。取り違えると座標が総崩れになる。
/// @param indices 三角形インデックス (indexCount)
/// @param resolution 目標とするアトラスの一辺（テクセル）
+ (nullable MDRAtlasResult *)parametrizePositions:(const void *)positions
                                      vertexCount:(NSUInteger)vertexCount
                                           stride:(NSUInteger)stride
                                          indices:(const uint32_t *)indices
                                       indexCount:(NSUInteger)indexCount
                                       resolution:(uint32_t)resolution
    NS_SWIFT_NAME(parametrize(positions:vertexCount:stride:indices:indexCount:resolution:));
@end

NS_ASSUME_NONNULL_END
