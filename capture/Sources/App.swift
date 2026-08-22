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
            CaptureView()
                .preferredColorScheme(.dark)
        }
    }
}
