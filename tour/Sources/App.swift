import SwiftUI
import UniformTypeIdentifiers

@main
struct MadoribaTourApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
    }
}

/// tour.json と splat ファイルを選んで開く。
///
/// 起動引数でも渡せるようにしてある（開発中に毎回選ぶのを避けるため）:
///   MadoribaTour <tour.json> <splat.ply|spz>
struct RootView: View {
    @State private var tour: Tour?
    @State private var splatURLs: [URL] = []
    @State private var message: String?

    var body: some View {
        Group {
            if let tour, !splatURLs.isEmpty {
                TourView(tour: tour, splatURLs: splatURLs)
            } else {
                picker
            }
        }
        .onAppear(perform: loadFromArguments)
    }

    private var picker: some View {
        VStack(spacing: 16) {
            Text("madoriba tour").font(.largeTitle)
            Text("tour.json と splat (.ply / .spz) を選んでください")
                .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("tour.json を選ぶ") { pick(json: true) }
                Button("splat を選ぶ") { pick(json: false) }
            }
            if tour != nil { Text("tour.json ✓").font(.caption) }
            if !splatURLs.isEmpty { Text("splat ✓ \(splatURLs.count) 件").font(.caption) }
        }
        .padding(40)
    }

    private func loadFromArguments() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for a in args {
            let url = URL(fileURLWithPath: a)
            if a.hasSuffix(".json") {
                tour = try? Tour.load(from: url)
                if tour == nil { message = "tour.json を読めませんでした: \(a)" }
            } else {
                splatURLs.append(url)
            }
        }
    }

    private func pick(json: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if json { panel.allowedContentTypes = [.json] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if json {
            do { tour = try Tour.load(from: url) }
            catch { message = "tour.json を読めませんでした: \(error.localizedDescription)" }
        } else {
            splatURLs = [url]
        }
    }
}
