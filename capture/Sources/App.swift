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

    var body: some View {
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
