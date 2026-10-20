import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import RealityKit
import SwiftUI

/// A picture to turn into a spatial scene, with the camera tint it is shown under
/// (the sepia of flashbacks), which is baked into the picture the scene is made from.
struct SpatialSource: Hashable, Sendable {
    let url: URL
    var tint: Tint?

    init?(_ name: String, tint: Tint? = nil) {
        guard let url = StoryLibrary.shared.assetURL(name) else { return nil }
        self.url = url
        self.tint = tint
    }

    var label: String { url.lastPathComponent + (tint == nil ? "" : " (tinted)") }
}

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
    @ObservationIgnored private var ready: [SpatialSource: Spatial3DImage] = [:]
    /// Pictures that produced no scene; not tried again this session.
    @ObservationIgnored private var unavailable: Set<SpatialSource> = []
    @ObservationIgnored private var recent: [SpatialSource] = []
    /// Pictures someone is waiting to see, oldest request first.
    @ObservationIgnored private var visible: [SpatialSource] = []
    /// The story's next pictures, nearest first.
    @ObservationIgnored private var upcoming: [SpatialSource] = []
    @ObservationIgnored private var working: SpatialSource?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var waiters: [SpatialSource: [Int: CheckedContinuation<Spatial3DImage?, Never>]] = [:]
    @ObservationIgnored private var nextWaiter = 0
    @ObservationIgnored private var failures = 0
    /// Set once a scene has been generated: the device can make them, so later failures
    /// are about one picture and never turn the feature off.
    @ObservationIgnored private var hasSucceeded = false
    /// Kept in memory: the picture on screen, the lookahead, and a few recent ones.
    private let capacity = 12

    /// The scene for a picture on screen, generating it ahead of everything else.
    /// Returns nil when unavailable, or when the caller stops waiting.
    func scene(for source: SpatialSource) async -> Spatial3DImage? {
        if let image = ready[source] {
            touch(source)
            return image
        }
        guard isSupported, !unavailable.contains(source) else { return nil }
        let id = nextWaiter
        nextWaiter += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[source, default: [:]][id] = continuation
                if working != source, !visible.contains(source) { visible.append(source) }
                upcoming.removeAll { $0 == source }
                start()
            }
        } onCancel: {
            Task { @MainActor in self.stopWaiting(source, id) }
        }
    }

    /// A scene that is already generated, for showing it with no wait at all.
    func readyScene(for source: SpatialSource) -> Spatial3DImage? {
        guard let image = ready[source] else { return nil }
        touch(source)
        return image
    }

    /// The story's next pictures, nearest first; replaces the previous lookahead.
    func lookahead(_ sources: [SpatialSource]) {
        guard isSupported, Settings.shared.spatialScenes else { return }
        upcoming = sources.filter { ready[$0] == nil && !unavailable.contains($0) && $0 != working && !visible.contains($0) }
        for source in sources where ready[source] != nil { touch(source) }
        start()
    }

    /// Kept for callers that queue a picture or two (the gallery viewer, a loaded save).
    func prefetch(_ sources: [SpatialSource]) {
        guard isSupported, Settings.shared.spatialScenes else { return }
        for source in sources where ready[source] == nil && !unavailable.contains(source) && source != working
            && !visible.contains(source) && !upcoming.contains(source) {
            upcoming.append(source)
        }
        start()
    }

    private func stopWaiting(_ source: SpatialSource, _ id: Int) {
        guard let continuation = waiters[source]?.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        if waiters[source]?.isEmpty ?? true {
            waiters[source] = nil
            visible.removeAll { $0 == source }
        }
    }

    private func start() {
        guard worker == nil, !visible.isEmpty || !upcoming.isEmpty else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while isSupported, let source = visible.first ?? upcoming.first {
            visible.removeAll { $0 == source }
            upcoming.removeAll { $0 == source }
            working = source
            let image = ready[source] == nil ? await generate(source) : ready[source]
            if image == nil { unavailable.insert(source) }
            working = nil
            for continuation in (waiters.removeValue(forKey: source) ?? [:]).values {
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

    private func generate(_ source: SpatialSource) async -> Spatial3DImage? {
        #if DEBUG
        // `-simulateSpatial 2.5`: pretend each generation takes that long (the simulator
        // can't generate scenes), to check the queue's order in Documents/debug.log.
        let simulated = UserDefaults.standard.double(forKey: "simulateSpatial")
        if simulated > 0 {
            debugLog("Spatial queue: generating \(source.label) (waiting: \(visible.map(\.label)), next: \(upcoming.map(\.label)))")
            try? await Task.sleep(for: .seconds(simulated))
            return nil
        }
        #endif
        do {
            let started = Date.now
            let image: Spatial3DImage
            if let tint = source.tint {
                let url = source.url
                guard let tinted = await Task.detached(priority: .userInitiated, operation: {
                    Self.tintedSource(url, tint)
                }).value else {
                    debugLog("Spatial scene failed: \(source.label) could not be tinted")
                    return nil
                }
                image = try await Spatial3DImage(imageSource: tinted)
            } else {
                image = try await Spatial3DImage(contentsOf: source.url)
            }
            try await image.generate()
            guard ImagePresentationComponent.supportedViewingModes(for: image).contains(.spatial3D) else {
                return nil
            }
            failures = 0
            hasSucceeded = true
            debugLog("Spatial scene ready: \(source.label) in \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s")
            ready[source] = image
            touch(source)
            return image
        } catch {
            // Generation is unavailable on some hardware and in the simulator: when the
            // first attempts all fail, stop trying and keep the art flat. Once a scene has
            // worked, a failure only leaves that one picture flat.
            debugLog("Spatial scene failed: \(source.label) \(error)")
            failures += 1
            if failures >= 2, !hasSucceeded { isSupported = false }
            return nil
        }
    }

    /// The picture with the camera tint applied, as Shaders.metal's `tint` draws it:
    /// mixed toward its gray by the saturation, then each channel scaled. Worked in
    /// the image's own (gamma) values, as the shader sees them.
    nonisolated static func tintedSource(_ url: URL, _ tint: Tint) -> CGImageSource? {
        guard let input = CIImage(contentsOf: url) else { return nil }
        let saturation = CGFloat(tint.saturation) / 128
        let weights: [CGFloat] = [0.299, 0.587, 0.114]
        func row(_ channel: Int, _ scale: Double) -> CIVector {
            var values = weights.map { (1 - saturation) * $0 }
            values[channel] += saturation
            return CIVector(x: values[0] * scale, y: values[1] * scale, z: values[2] * scale, w: 0)
        }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = input
        matrix.rVector = row(0, tint.red)
        matrix.gVector = row(1, tint.green)
        matrix.bVector = row(2, tint.blue)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let output = matrix.outputImage?.cropped(to: input.extent),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let data = context.pngRepresentation(of: output, format: .RGBA8, colorSpace: space) else { return nil }
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    private func touch(_ source: SpatialSource) {
        recent.removeAll { $0 == source }
        recent.append(source)
        while recent.count > capacity {
            ready[recent.removeFirst()] = nil
        }
    }

    /// Pictures that become spatial scenes: full-screen backgrounds and event CGs,
    /// not the solid color plates or the panoramas and tall pictures that pan.
    nonisolated static func isEligible(_ name: String) -> Bool {
        let key = (name as NSString).lastPathComponent.lowercased()
        guard key.hasPrefix("bg_") || key.hasPrefix("ev_") else { return false }
        guard let size = ArtLibrary.shared.pixelSize(name) else { return false }
        return abs(size.width / size.height - Screen.size.width / Screen.size.height) < 0.02
    }
}

/// The pictures currently shown as spatial scenes.
struct SpatialShowingKey: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

/// A picture shown flat at once, then as a spatial scene behind the window once
/// visionOS has generated it. The flat picture stays underneath for transitions.
struct SpatialPicture: View {
    let name: String
    /// The camera tint the picture is shown under, also baked into its scene.
    var tint: Tint?
    /// Fade between the flat picture and its scene; off in the gallery viewer,
    /// where pictures change at once.
    var fades = true
    var settings = Settings.shared
    @Environment(\.physicalMetrics) private var metrics
    /// The scene loaded for a picture, kept with the picture it belongs to: when the
    /// story swaps one CG variation for the next, this view stays and its name changes
    /// a frame before the task below runs, and the old scene must not be shown (or
    /// attached) under the new picture's name.
    @State private var loaded: Loaded?

    var body: some View {
        // A scene the lookahead already made shows from the first frame, with no flat
        // picture first; anything else arrives through the task below.
        let source = SpatialSource(name, tint: tint)
        let scene = (loaded?.source == source ? loaded?.image : nil) ?? readyScene
        let showsSpatial = settings.spatialScenes && scene != nil
        GeometryReader { proxy in
            ZStack {
                if let image = ArtLibrary.shared.image(name) {
                    Image(uiImage: image).resizable()
                        .tinted(tint)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(showsSpatial ? 0 : 1)
                }
                RealityView { content in
                    let root = Entity()
                    root.name = "scene"
                    content.add(root)
                } update: { content in
                    guard let root = content.entities.first else { return }
                    if showsSpatial, let spatial = scene {
                        let key = name + (tint.map { "#\($0.saturation)/\($0.color)" } ?? "")
                        if root.components[ImagePresentationComponent.self] == nil || root.name != key {
                            root.name = key
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
            .animation(fades ? .easeInOut(duration: 0.6) : nil, value: showsSpatial)
        }
        // Spatial scenes render behind the window's surface, so anything opaque in the
        // window hides them, even a view drawn "behind" this one. Containers read this
        // and clear their fills while the scene shows.
        .preference(key: SpatialShowingKey.self, value: showsSpatial ? [name] : [])
        .task(id: TaskKey(name: name, tint: tint, enabled: settings.spatialScenes)) {
            loaded = nil
            guard settings.spatialScenes, let source else { return }
            if let ready = SpatialSceneLibrary.shared.readyScene(for: source) {
                loaded = Loaded(source: source, image: ready)
                return
            }
            // Pictures that flash by (skipping, quick cuts) aren't worth generating.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if let image = await SpatialSceneLibrary.shared.scene(for: source), !Task.isCancelled {
                loaded = Loaded(source: source, image: image)
            }
        }
    }

    private var readyScene: SpatialSceneLibrary.Spatial3DImage? {
        guard settings.spatialScenes, let source = SpatialSource(name, tint: tint) else { return nil }
        return SpatialSceneLibrary.shared.readyScene(for: source)
    }

    private struct Loaded {
        let source: SpatialSource
        let image: SpatialSceneLibrary.Spatial3DImage
    }

    private struct TaskKey: Equatable {
        let name: String
        let tint: Tint?
        let enabled: Bool
    }
}
