import ARKit
import SwiftUI

@main
struct MadoribaCaptureApp: App {
    init() {
        // A12Z は発熱でスロットリングしやすい。撮影中に画面が落ちると
        // トラッキングが切れるので、スリープを止める。
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}


/// 2 つのスキャン方式を切り替える。
///
/// ARWorldTrackingConfiguration と RoomCaptureSession は同時に走らせられないので、
/// 1 回のスキャンで両方を得ることはできない。同じ部屋を別々に撮って比較する。
struct RootView: View {
    enum Mode: String, CaseIterable {
        case mdr = "MDR (3DGS用)"
        case roomplan = "RoomPlan (構造)"
    }

    @State private var mode: Mode = .mdr

    /// LiDAR が載っているか。**これが無いと何も撮れない。**
    ///
    /// 面の再構成（`sceneReconstruction`）は LiDAR 必須で、iPhone は Pro 系、
    /// iPad は Pro と一部の Air にしか載っていない。
    ///
    /// **App Store では絞れない。** `UIRequiredDeviceCapabilities` に LiDAR に
    /// 対応するキーが無く（`arkit` は ARKit 対応の可否、
    /// `iphone-ipad-minimum-performance-a12` はチップ世代）、非搭載機の
    /// インストールを止める手段が用意されていない。だからここで止める。
    private static let hasLiDAR =
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

    var body: some View {
        if RootView.hasLiDAR { capture } else { UnsupportedView() }
    }

    private var capture: some View {
        ZStack(alignment: .top) {
            switch mode {
            case .mdr:
                CaptureView()
            case .roomplan:
                if #available(iOS 16.0, *) {
                    RoomPlanView()
                } else {
                    Text("RoomPlan には iOS 16 以降が必要です")
                }
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            .padding(.top, 8)
        }
    }
}


/// LiDAR が無い機種に出す画面。
///
/// **撮影の UI を出さない。** 以前は警告を重ねて録画ボタンだけ止めていたが、
/// 撮れないものを撮れるように見せる意味がない。過去プロジェクトだけは開ける
/// ようにしておく（他の端末で撮ったバンドルをファイル App 経由で入れた場合に
/// 見られる）。
struct UnsupportedView: View {
    @State private var showLibrary = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("この端末では撮影できません")
                .font(.title3.weight(.semibold))
            Text("madoriba capture は LiDAR スキャナを使って室内の面を\n"
                 + "再構成します。搭載機種でのみ動作します。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Label("iPhone 12 Pro / Pro Max 以降の Pro 系", systemImage: "iphone")
                Label("iPad Pro（2020 以降）、iPad Air の一部", systemImage: "ipad")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("過去プロジェクトを見る") { showLibrary = true }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(32)
        .sheet(isPresented: $showLibrary) { ScanListView() }
    }
}
