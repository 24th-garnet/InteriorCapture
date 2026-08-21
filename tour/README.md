# tour — madoriba-tour（ツアービューア）

仕様: [`docs/pipeline.md`](../docs/pipeline.md) §8

## 設計原則

**3DGS は撮影軌跡から離れた視点で破綻する。これを弱点ではなく制約として設計に取り込む。**

- 移動は **station point に制約**（Matterport 方式）。station 間はカメラ補間で遷移し、各 station では自由に見回す
- 結果として、常に「撮影視点の近傍」しか描画しない = 3DGS が最も得意な条件だけを使う
- 描画は splat、衝突判定・床・dollhouse は mesh

## 土台候補

[MetalSplatter](https://github.com/scier/MetalSplatter) — PLY / SPZ / .splat を直接読める。iOS / macOS / visionOS 対応。

## 撮影 UX への跳ね返り

station point は「部屋の中央をツアー導線どおりに歩くパス」上に置く。
このパスは Scaniverse 流の外周 3 パス（水平／天井／床）に**追加で**必要。
撮影ガイドとビューア設計は不可分。
