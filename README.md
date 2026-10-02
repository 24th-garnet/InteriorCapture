# InteriorCapture

LiDAR 搭載の iPhone / iPad で**内装をスキャン**し、`.mdr` バンドルとして取り出す
撮影アプリ。Scaniverse 相当の体験を、端末だけで完結させることを目指している。

バンドルを**使う**側（平面図・編集・3D・歩行・DXF）は別リポジトリにある。

**<https://github.com/24th-garnet/CaptureVisualizer>**

## 構成

| ハード | 役割 |
|---|---|
| iPad Pro 2020（A12Z, LiDAR） | 撮影機。ARKit のポーズ・LiDAR 深度・RGB を記録 |
| MacBook Pro M1 Max | 復元エンジン。Metal ネイティブの 3DGS 学習 |

**A12Z での on-device 3DGS は狙わない**（Niantic 自身が Scaniverse で iPad Pro 2020 を splat 非対応にしている）。
iPad はキャプチャに専念し、復元は Mac に寄せる二段構成。

## 設計の核心

高速化の本質は 3DGS の最適化ではなく **SfM（COLMAP）の排除**にある。
ARKit がカメラポーズと intrinsics を確定値で返すため、通常パイプラインで支配的な SfM が丸ごと不要になり、
LiDAR 点群が「密でメートル正解な初期値」と「depth supervision の教師」を同時に供給する。

内装は 3DGS にとって本来最悪の被写体（白壁・無地・鏡・ガラス）だが、LiDAR + ARKit を持つと最良のケースに反転する。

### 二段出力

| | 出力 | 待ち時間 |
|---|---|---|
| Tier 1 | ARKit ライブメッシュ + 間取り | 0 秒（撮影完了と同時） |
| Tier 2a | 3DGS 7K iter プレビュー | 2〜3 分（要実測） |
| Tier 2b | 3DGS 30K iter 最終 | 15〜20 分（裏で差し替え） |

## ディレクトリ

```
capture/   madoriba-capture — iPhone / iPad 撮影アプリ（Swift）
spec/      MDR バンドル仕様（撮影アプリと Mac 側の唯一の契約）
tour/      旧ツアービューア（3DGS を畳んだ時点で停止）
tools/     ベンチマーク・変換スクリプト
docs/      設計ドキュメント
vendor/    外部リポジトリ（gitignore 済み）
```

Mac 側（平面図・編集・3D・DXF）は別リポジトリへ移した。

**<https://github.com/24th-garnet/CaptureVisualizer>**

このリポジトリは `.mdr` バンドルを**作る**側だけを持つ。バンドルを**使う**側は
すべて CaptureVisualizer にある。

## ドキュメント

| | |
|---|---|
| [docs/pipeline.md](docs/pipeline.md) | **開発パイプライン仕様**。まずこれを読む |
| [docs/setup.md](docs/setup.md) | 開発環境セットアップ手順 |
| [docs/scaniverse-research.md](docs/scaniverse-research.md) | Scaniverse の一次調査（内装スキャン重点） |

## 現在地

**Phase 0: M1 Max のベンチマーク実測**（`docs/pipeline.md` §9）

「7K iter で 2〜3 分」は msplat の M4 Max 実測値（74 秒）からの換算に過ぎない。
これを実測に置き換えないと、iteration 数・ガウシアン上限・部屋分割の粒度が決められない。最初の意思決定ゲート。
