# 開発環境セットアップ

対象: MacBook Pro M1 Max（復元エンジン）+ iPad Pro 2020 A12Z（撮影機）
関連: `docs/pipeline.md`

---

## ⚡ Phase 0 だけなら最小構成

まず `docs/pipeline.md` §9 の Phase 0（M1 Max のベンチマーク実測）を走らせるのが最初のゲート。
**これだけなら以下の 4 つで足りる**ので、全部を一度に用意する必要はない。

1. Xcode Command Line Tools
2. Homebrew
3. `uv` + Python 3.12（gsplat-mlx 用）
4. Mip-NeRF 360 データセットの `room` シーン

残りは Phase 1 以降で必要になったときに追加する。

---

## A. Mac 側（M1 Max）

### A-1. システム要件

| 項目 | 要件 | 備考 |
|---|---|---|
| macOS | **14 以上**（msplat の要件） | 現行 26.x なら問題なし |
| チップ | Apple Silicon | M1 Max = 該当 |
| メモリ | 32 GB 以上 | **M1 Max は構成上 32 GB か 64 GB しか存在しない** → 要件は自動的に満たす。確認不要 |
| 空きディスク | **100 GB 以上** | データセット ~10 GB、キャプチャ 200 MB/部屋、学習チェックポイント |

### A-2. 基盤ツール

```bash
xcode-select --install                      # Command Line Tools
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cmake zstd git-lfs
```

### A-3. Xcode

- **Xcode 26.x**（App Store または Apple Developer からダウンロード）
- iPadOS アプリと macOS 側ツールの両方で使用
- インストール後に一度起動してコンポーネントの追加インストールを済ませておく

### A-4. Python 環境（gsplat-mlx — 検証・研究用）

```bash
brew install uv                             # または curl -LsSf https://astral.sh/uv/install.sh | sh
git clone https://github.com/RobotFlow-Labs/gsplat-mlx.git
cd gsplat-mlx
uv venv .venv --python 3.12
source .venv/bin/activate
uv pip install -e ".[dev]"
```

要件: Python ≥ 3.10（3.12 推奨）/ MLX ≥ 0.31.0 / NumPy ≥ 1.24 / SciPy ≥ 1.10 / Pillow ≥ 9.0
**コンパイル不要**（純 Python + MLX の Metal バックエンド）。CUDA 関連は一切不要。

### A-5. Rust 環境（Brush — 本番組み込み用）

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup update                               # Rust 1.88 以上が必要
cargo install rerun-cli                     # 学習中の可視化に使う
git clone https://github.com/ArthurBrussee/brush.git
cd brush && cargo run --release -- --help
```

Brush は **COLMAP 形式と Nerfstudio 形式**を入力に取る → `docs/pipeline.md` §5.5 で COLMAP text model を吐く設計と噛み合う。
`--with-viewer` を付けると学習中の様子を UI で見られる（デバッグに有用）。

### A-6. msplat（速度上限の把握用・Phase 0）

```bash
git clone https://github.com/rayanht/msplat.git
```

要件: macOS 14+ / Apple Silicon。全パイプラインが fused Metal compute shader。
COLMAP / Nerfstudio / Polycam 形式に対応。

### A-7. SPZ（出力形式）

```bash
git clone https://github.com/nianticlabs/spz.git
cd spz && pip install .                     # Python バインディング（nanobind）
```

libz / libzstd が無ければ CMake の FetchContent が自動取得するので、事前準備は基本不要。
単発の変換なら **ブラウザ版ユーティリティ** `nianticlabs.github.io/spz` でも PLY ⇄ SPZ できる。

### A-8. ビューア（結果確認用）

```bash
git clone https://github.com/scier/MetalSplatter.git
```

**PLY / SPZ / .splat を直接読める**ので、こちらの出力形式（SPZ）とそのまま繋がる。
iOS / macOS / visionOS 対応で、`SampleApp` が同梱。§8 のツアービューアの土台候補でもある。

メッシュ確認用に Blender か MeshLab があると便利（`brew install --cask blender` / `meshlab`）。

### A-9. Phase 0 用データセット

**Mip-NeRF 360 データセットの `room` シーン**。
msplat の公表値（M4 Max で 7K iter = 74 秒）と直接比較するために、同じシーンを使うことが重要。
全シーンだと ~10 GB なので、`room` だけ落とせば十分。

### A-10. 任意：COLMAP（検証用ベースライン）

```bash
brew install colmap
```

本パイプラインは SfM を排除するので**本番では使わない**が、Phase 2 で
「ARKit ポーズ vs COLMAP ポーズ」の比較検証をしたいときの基準として持っておくと安心。

---

## B. iPad Pro 2020 側

| 項目 | 要件 | 備考 |
|---|---|---|
| iPadOS | **16 以上が必須** | `ARFrame.exifData`（露出補正に使う）が iOS 16+。現行 26.x で問題なし。iPadOS 27 でもサポート継続 |
| 空きストレージ | **10 GB 以上** | Mac 切断時のローカルスプール用。1 部屋 ~200 MB |
| ケース | **外す** | A12Z の発熱対策。Scaniverse の公式 Tips にもある |
| ケーブル | **USB-C**（iPad Pro 2020 は USB-C） | 有線デプロイ・デバッグ用 |
| その他 | レンズ清拭クロス | 地味だが効く。Scaniverse Tips 記載 |

撮影は歩き回るので、落下防止のストラップかハンドグリップがあると安全。

---

## C. アカウント

### C-1. Apple Developer Program（$99/年）— **推奨**

無料プロビジョニングでも実機ビルドは可能だが、以下の制約がある:
- **アプリが 7 日で失効**（毎週再ビルドが必要）
- 同時に入れられるアプリが 3 本まで

数か月スパンのプロジェクトでは有料アカウントの方が確実に安い（時間換算で）。

### C-2. GitHub アカウント

上記リポジトリの clone に必要（public なので閲覧のみなら不要だが、issue を追うため推奨）。

---

## D. ネットワーク環境 ← **見落としやすい落とし穴**

`docs/pipeline.md` §4 のストリーミング転送は **Bonjour / mDNS** に依存する。

- **企業ネットワークやゲスト Wi-Fi は mDNS をブロックし、クライアント分離でピア間通信を切ることが多い** → 動かない
- 対策 A: **自宅ルータなど mDNS が通る普通の LAN** を使う（開発時はこれが一番楽）
- 対策 B: Network.framework の `includePeerToPeer = true` を使うと **AWDL 経由**になり、インフラ側の Wi-Fi に依存せず直接繋がる。堅牢だが実装がやや複雑

**Info.plist に必要な記述**（iOS 14+ のローカルネットワーク許可）:
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>スキャンデータを Mac に転送するために使用します</string>
<key>NSBonjourServices</key>
<array><string>_madoriba._tcp</string></array>
```
初回起動時に許可ダイアログが出る。**一度拒否すると設定アプリからしか戻せない**ので、開発中に誤爆したら要注意。

Mac 側もファイアウォールで受信接続がブロックされていないか確認（システム設定 → ネットワーク → ファイアウォール）。

---

## E. リポジトリ一覧（まとめて clone する場合）

```bash
mkdir -p ~/projects/madoriba/vendor && cd ~/projects/madoriba/vendor
git clone https://github.com/RobotFlow-Labs/gsplat-mlx.git   # 検証・研究
git clone https://github.com/ArthurBrussee/brush.git         # 本番候補
git clone https://github.com/rayanht/msplat.git              # 速度上限の把握
git clone https://github.com/nianticlabs/spz.git             # 出力形式
git clone https://github.com/scier/MetalSplatter.git         # ビューア
```

---

## F. プロジェクト自体の初期化

**`InteriorCapture`（旧 `scaniverse_mimic`）はまだ git リポジトリになっていない。** 最初にやる:

```bash
cd ~/projects/madoriba/InteriorCapture
git init
```

`.gitignore` に最低限入れるもの:
```
*.mdr/          # キャプチャバンドル（1部屋 200MB）
vendor/         # 外部リポジトリ
*.ply
*.spz
.venv/
target/         # Rust
build*/         # CMake
.DS_Store
```

キャプチャデータとチェックポイントは Git に入れない。必要なら別途 git-lfs か外部ストレージ。

---

## G. 用意できたかのチェックリスト

**Phase 0 開始に必要（最小）**
- [ ] Xcode Command Line Tools
- [ ] Homebrew
- [ ] uv + Python 3.12 + gsplat-mlx
- [ ] Mip-NeRF 360 `room` シーン
- [ ] 空きディスク 100 GB

**Phase 1（iPad キャプチャ）から必要**
- [ ] Xcode 26.x
- [ ] Apple Developer Program
- [ ] iPad Pro 2020（iPadOS 16+、ケースを外す、空き 10 GB）
- [ ] USB-C ケーブル

**Phase 2 以降**
- [ ] Rust 1.88+ / rustup / rerun-cli / Brush
- [ ] msplat
- [ ] spz
- [ ] MetalSplatter
- [ ] Blender または MeshLab
- [ ] （任意）COLMAP

**Phase 4（ストリーミング転送）から必要**
- [ ] mDNS が通る LAN 環境
- [ ] Mac のファイアウォール設定確認
