import SwiftUI
import UIKit

@main
struct EuphoriaApp: App {
    @State private var engine = StoryEngine()

    var body: some Scene {
        Window("Euphoria", id: "game") {
            GameView(engine: engine)
        }
        .windowStyle(.plain)
        .defaultSize(WindowAspectLock.defaultSize)
        .windowResizability(.contentMinSize)
    }
}

/// Keeps the window at the original's 4:3 shape while the person resizes it.
/// visionOS restricts resizing to the window's current aspect ratio, so this
/// asks for an exact 4:3 size together with the uniform restriction.
struct WindowAspectLock: UIViewRepresentable {
    static let defaultSize = CGSize(width: 1440, height: 1080)
    static let minimumSize = CGSize(width: 960, height: 720)
    static let maximumSize = CGSize(width: 2880, height: 2160)

    func makeUIView(context: Context) -> LockView { LockView() }
    func updateUIView(_ uiView: LockView, context: Context) {}

    final class LockView: UIView {
        private weak var lockedScene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene, scene !== lockedScene else { return }
            lockedScene = scene
            let current = scene.effectiveGeometry.coordinateSpace.bounds.size
            let preferences = UIWindowScene.GeometryPreferences.Vision(
                size: WindowAspectLock.size(fitting: current),
                minimumSize: WindowAspectLock.minimumSize,
                maximumSize: WindowAspectLock.maximumSize,
                resizingRestrictions: .uniform)
            scene.requestGeometryUpdate(preferences) { error in
                debugLog("Window aspect lock failed: \(error.localizedDescription)")
            }
        }
    }

    /// The largest 4:3 size within the current one, kept within the limits.
    static func size(fitting current: CGSize) -> CGSize {
        guard current.width > 0, current.height > 0 else { return defaultSize }
        let width = min(current.width, current.height * 4 / 3)
        let clamped = min(max(width, minimumSize.width), maximumSize.width)
        return CGSize(width: clamped, height: clamped * 3 / 4)
    }
}

/// Logs to the console, and in Debug builds to Documents/debug.log.
func debugLog(_ message: String) {
    NSLog("%@", message)
    #if DEBUG
    let url = URL.documentsDirectory.appending(path: "debug.log")
    let line = "\(Date.now.formatted(.iso8601)) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
    #endif
}
