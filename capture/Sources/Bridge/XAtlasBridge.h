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
@end

@interface MDRXAtlas : NSObject

/// メッシュの UV を展開する。
/// @param positions 頂点座標 (vertexCount * 3)
/// @param indices 三角形インデックス (indexCount)
/// @param resolution 目標とするアトラスの一辺（テクセル）
+ (nullable MDRAtlasResult *)parametrizePositions:(const float *)positions
                                      vertexCount:(NSUInteger)vertexCount
                                          indices:(const uint32_t *)indices
                                       indexCount:(NSUInteger)indexCount
                                       resolution:(uint32_t)resolution
    NS_SWIFT_NAME(parametrize(positions:vertexCount:indices:indexCount:resolution:));
@end

NS_ASSUME_NONNULL_END
