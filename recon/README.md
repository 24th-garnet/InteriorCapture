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

# 3. 学習
../vendor/msplat/build/msplat scene -n 7000 -o scene/splat.ply
```

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
