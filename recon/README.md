# recon — madoriba-recon（macOS 復元パイプライン）

MDR バンドルを COLMAP モデル + LiDAR 初期点群に変換し、3DGS を学習する。

仕様: [`docs/pipeline.md`](../docs/pipeline.md) §5〜§7 / [`spec/mdr-v1.md`](../spec/mdr-v1.md)

## セットアップ

```bash
cd recon
uv venv .venv --python 3.12
uv pip install -e . --python .venv/bin/python
uv pip install pytest --python .venv/bin/python
.venv/bin/python -m pytest tests/ -q
```

conda の base 環境が有効だと `python` / `pip` の指す先が紛らわしくなるので、
`conda deactivate` してから作業する。

## 使い方

```bash
# 1. 座標変換の検証（学習前に必ず通す）
mdr2colmap verify room-xxxx.mdr --overlay /tmp/overlay

# 2. COLMAP モデル + 初期点群を書き出す
mdr2colmap convert room-xxxx.mdr -o scene

# 3. サーバ側パイプライン（前処理 + 3DGS を一括、実測 282 秒）
mdr2colmap server room-xxxx.mdr -o scene/ \
  --brush ../vendor/brush/target/release/brush

# 4. 間取り（メッシュから壁線・寸法を抽出）
mdr2colmap floorplan room-xxxx.mdr -o plan/

# 5. ツアーを開く
open -n -a MadoribaTour.app --args scene/tour.json scene/gs/*.ply
```

## 学習解像度は 640 固定

本アプリは **640 のみに対応する**。実測では 960 で +0.21 dB、1920 で +0.42 dB
改善するが、960 は 5 分要件を 53 秒超過する。ツアービューアで実際に動かして
確認した結果、640 で品質は十分と判断した。高解像度への対応は後付けの課題として
切り離している。

| 学習解像度 | 時間 | PSNR | 5 分要件 |
|---|---|---|---|
| **640（採用）** | **262 秒** | 22.47 | ○ |
| 960 | 333 秒 | 22.75 | × 53 秒超過 |
| 1920 | 712 秒 | 22.95 | × 大幅超過 |

ガウシアン数は動作確認済みの 50 万を既定にしている。**25 万でも目視で
区別できず（PSNR 差 0.04 dB）81 秒速く、ファイルも半分**になるので、
`--max-splats 250000` で切り替えられる。

## 二段構成

| | 実測 | 用途 |
|---|---|---|
| **Tier 1** テクスチャ付きメッシュ | **25〜63 秒** (PSNR 16.2) | 間取り・寸法・即時確認 |
| **Tier 2** 3DGS | **250 秒** (PSNR 23.3) | 写実的なツアー |

Tier 1 が Scaniverse（60〜90 秒）を上回っており、撮影直後の成果物はこちらで賄う。
先行実装 PRESTAGELiDAR が「再構築に時間がかかりすぎる」ため却下された経緯への回答。

学習設定の根拠と、採用しなかった施策の実測は
[`docs/pipeline.md`](../docs/pipeline.md) §6.3〜6.4 を参照。

## 検証を先に走らせる理由

学習に数分かけてから「なんか変」と気づくのを避けるため。
`verify` は**別フレーム間**で再投影誤差を測る。

同じフレームの深度を非投影してそのフレームに投影し返すのは往復なので、
world 変換が間違っていても誤差が打ち消えて通ってしまう。
フレーム A の点をフレーム B に投影して初めてポーズが検証される。

座標変換が正しければ数 cm、間違っていればメートル単位でずれるので判定は明快に分かれる。

## 出力形式の制約（実装で判明）

| | |
|---|---|
| `cameras.bin` / `images.bin` | **バイナリ必須。** msplat のディスパッチャが `cameras.bin` の存在で形式を判定するため、テキストは受け付けない |
| `points3D.ply` | 点群は `points3D.bin` が無ければ PLY にフォールバックする。可変長トラックを持つバイナリを書かずに済む |
| カメラ台数 | **1 フレーム = 1 台。** ARKit が intrinsics を毎フレーム再計算するため、共通化すると再投影誤差になる |
| カメラモデル | PINHOLE。ARKit は非線形レンズ歪みを補正済みなので歪み係数は不要 |

## モジュール

| | |
|---|---|
| `mdr.py` | MDR バンドルの読み込み。ARKit の生値を素直に numpy に載せるだけ |
| `colmap.py` | **座標変換の集約点。** ARKit → COLMAP の規約変換と COLMAP 書き出し |
| `pointcloud.py` | 深度の非投影 → ボクセル平均 → 外れ値除去 |
| `verify.py` | 再投影による座標変換の検証 |

座標変換を `colmap.py` に集約し、capture（iPadOS）側では一切変換しない。
capture 側で変換すると、バグが見つかったときに再撮影が必要になる。

## 学習実装

| 用途 | 実装 |
|---|---|
| 検証・研究 | gsplat-mlx（上流 gsplat と API 互換） |
| 本番組み込み | Brush（Rust、COLMAP/Nerfstudio 形式を入力に取る） |
| 速度上限の把握 | msplat（全 fused Metal shader） |

**本番採用は Phase 0 のベンチ実測後に確定する。**
前段が COLMAP 形式を吐くので、学習実装は差し替え可能。
