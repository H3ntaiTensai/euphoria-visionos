import RealityKit
import SwiftUI

/// Converts backgrounds and event CGs into spatial scenes with visionOS' on-device
/// generation, keeping the most recent few in memory (generated scenes can't be saved).
///
/// One picture is generated at a time, from a prioritized queue: the picture on screen
/// first, then the story's upcoming pictures in order. Each lookahead replaces the
/// previous one, so predictions that no longer apply are dropped rather than generated.
@MainActor @Observable
final class SpatialSceneLibrary {
    static let shared = SpatialSceneLibrary()
    typealias Spatial3DImage = ImagePresentationComponent.Spatial3DImage

    /// False when this device cannot generate spatial scenes (for example, the simulator).
    private(set) var isSupported = true
    @ObservationIgnored private var ready: [URL: Spatial3DImage] = [:]
    /// Pictures that produced no scene; not tried again this session.
    @ObservationIgnored private var unavailable: Set<URL> = []
    @ObservationIgnored private var recent: [URL] = []
    /// Pictures someone is waiting to see, oldest request first.
    @ObservationIgnored private var visible: [URL] = []
    /// The story's next pictures, nearest first.
    @ObservationIgnored private var upcoming: [URL] = []
    @ObservationIgnored private var working: URL?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var waiters: [URL: [Int: CheckedContinuation<Spatial3DImage?, Never>]] = [:]
    @ObservationIgnored private var nextWaiter = 0
    @ObservationIgnored private var failures = 0
    /// Kept in memory: the picture on screen, the lookahead, and a few recent ones.
    private let capacity = 12

    /// The scene for a picture on screen, generating it ahead of everything else.
    /// Returns nil when unavailable, or when the caller stops waiting.
    func scene(for url: URL) async -> Spatial3DImage? {
        if let image = ready[url] {
            touch(url)
            return image
        }
        guard isSupported, !unavailable.contains(url) else { return nil }
        let id = nextWaiter
        nextWaiter += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[url, default: [:]][id] = continuation
                if working != url, !visible.contains(url) { visible.append(url) }
                upcoming.removeAll { $0 == url }
                start()
            }
        } onCancel: {
            Task { @MainActor in self.stopWaiting(url, id) }
        }
    }

    /// The story's next pictures, nearest first; replaces the previous lookahead.
    func lookahead(_ urls: [URL]) {
        guard isSupported, Settings.shared.spatialScenes else { return }
        upcoming = urls.filter { ready[$0] == nil && !unavailable.contains($0) && $0 != working && !visible.contains($0) }
        for url in urls where ready[url] != nil { touch(url) }
        start()
    }

    /// Kept for callers that queue a picture or two (the gallery viewer).
    func prefetch(_ urls: [URL]) {
        guard isSupported, Settings.shared.spatialScenes else { return }
        for url in urls where ready[url] == nil && !unavailable.contains(url) && url != working
            && !visible.contains(url) && !upcoming.contains(url) {
            upcoming.append(url)
        }
        start()
    }

    private func stopWaiting(_ url: URL, _ id: Int) {
        guard let continuation = waiters[url]?.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        if waiters[url]?.isEmpty ?? true {
            waiters[url] = nil
            visible.removeAll { $0 == url }
        }
    }

    private func start() {
        guard worker == nil, !visible.isEmpty || !upcoming.isEmpty else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while isSupported, let url = visible.first ?? upcoming.first {
            visible.removeAll { $0 == url }
            upcoming.removeAll { $0 == url }
            working = url
            let image = ready[url] == nil ? await generate(url) : ready[url]
            if image == nil { unavailable.insert(url) }
            working = nil
            for continuation in (waiters.removeValue(forKey: url) ?? [:]).values {
                continuation.resume(returning: image)
            }
        }
        if !isSupported {
            // Nothing more can be generated: release everyone still waiting.
            for continuation in waiters.values.flatMap(\.values) { continuation.resume(returning: nil) }
            waiters = [:]
            visible = []
            upcoming = []
        }
        worker = nil
    }

    private func generate(_ url: URL) async -> Spatial3DImage? {
        #if DEBUG
        // `-simulateSpatial 2.5`: pretend each generation takes that long (the simulator
        // can't generate scenes), to check the queue's order in Documents/debug.log.
        let simulated = UserDefaults.standard.double(forKey: "simulateSpatial")
        if simulated > 0 {
            debugLog("Spatial queue: generating \(url.lastPathComponent) (waiting: \(visible.map(\.lastPathComponent)), next: \(upcoming.map(\.lastPathComponent)))")
            try? await Task.sleep(for: .seconds(simulated))
            return nil
        }
        #endif
        do {
            let started = Date.now
            let image = try await Spatial3DImage(contentsOf: url)
            try await image.generate()
            guard ImagePresentationComponent.supportedViewingModes(for: image).contains(.spatial3D) else {
                return nil
            }
            failures = 0
            debugLog("Spatial scene ready: \(url.lastPathComponent) in \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s")
            ready[url] = image
            touch(url)
            return image
        } catch {
            // Generation is unavailable on some hardware and in the simulator;
            // after repeated failures, stop trying and keep the art flat.
            debugLog("Spatial scene failed: \(url.lastPathComponent) \(error)")
            failures += 1
            if failures >= 2 { isSupported = false }
            return nil
        }
    }

    private func touch(_ url: URL) {
        recent.removeAll { $0 == url }
        recent.append(url)
        while recent.count > capacity {
            ready[recent.removeFirst()] = nil
        }
    }

    /// Pictures that become spatial scenes: full-screen backgrounds and event CGs,
    /// not the solid color plates or the panoramas and tall pictures that pan.
    nonisolated static func isEligible(_ name: String) -> Bool {
        let key = (name as NSString).lastPathComponent.lowercased()
        guard key.hasPrefix("bg_") || key.hasPrefix("ev_") else { return false }
        guard let image = ArtLibrary.shared.image(name) else { return false }
        return abs(image.size.width / image.size.height - Screen.size.width / Screen.size.height) < 0.02
    }
}

/// A picture shown flat at once, then as a spatial scene behind the window once
/// visionOS has generated it. The flat picture stays underneath for transitions.
struct SpatialPicture: View {
    let name: String
    var settings = Settings.shared
    @Environment(\.physicalMetrics) private var metrics
    @State private var spatial: SpatialSceneLibrary.Spatial3DImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = ArtLibrary.shared.image(name) {
                    Image(uiImage: image).resizable()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(showsSpatial ? 0 : 1)
                }
                RealityView { content in
                    let root = Entity()
                    root.name = "scene"
                    content.add(root)
                } update: { content in
                    guard let root = content.entities.first else { return }
                    if showsSpatial, let spatial {
                        if root.components[ImagePresentationComponent.self] == nil || root.name != name {
                            root.name = name
                            var component = ImagePresentationComponent(spatial3DImage: spatial)
                            component.desiredViewingMode = .spatial3D
                            root.components.set(component)
                        }
                        // Sized to the window, as the game draws it.
                        let height = Float(metrics.convert(proxy.size.height, to: .meters))
                        if var component = root.components[ImagePresentationComponent.self],
                           abs(component.screenHeight - height) > 0.0001 {
                            component.screenHeight = height
                            root.components.set(component)
                        }
                        root.position = .zero
                    } else {
                        root.components.remove(ImagePresentationComponent.self)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                // Taps belong to the story; the scene is a 3D object that would take them.
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.6), value: showsSpatial)
        }
        .task(id: TaskKey(name: name, enabled: settings.spatialScenes)) {
            spatial = nil
            guard settings.spatialScenes, let url = StoryLibrary.shared.assetURL(name) else { return }
            // Pictures that flash by (skipping, quick cuts) aren't worth generating.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            spatial = await SpatialSceneLibrary.shared.scene(for: url)
        }
    }

    private var showsSpatial: Bool { settings.spatialScenes && spatial != nil }

    private struct TaskKey: Equatable {
        let name: String
        let enabled: Bool
    }
}
