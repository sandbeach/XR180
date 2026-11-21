import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

final class Playback: ObservableObject {
    let player = AVPlayer()
    let renderer: Renderer
    @Published var title = "双眼测试图"
    @Published var error: String?
    @Published var loading = false
    @Published var playing = false
    @Published var buffering = false
    @Published var hasVideo = false
    @Published var elapsed = 0.0
    @Published var duration = 0.0
    @Published private(set) var xrealConnected = false
    @Published var glassesPresent = false
    @Published var outputActive = false
    @Published var tracking = false {
        didSet { renderer.tracker.setEnabled(tracking) }
    }
    @Published var status = HeadTracking.Status.off
    @Published var settings = RenderSettings() {
        didSet { renderer.settings = settings }
    }

    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var outputWindow: NSWindow?
    private var outputDisplayID: CGDirectDisplayID?
    weak var controlsWindow: NSWindow?
    private var pendingLoad: Task<Void, Never>?
    private var loadID = UUID()
    private var tick: Timer?
    private var seekID = UUID()
    private var seeking = false

    init(renderer: Renderer) {
        self.renderer = renderer
        renderer.didFailFrame = { [weak self] in
            self?.error = "无法把解码后的画面交给 Metal。请试用较低分辨率的 H.264 或 HEVC MP4。"
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self, !self.seeking, time.seconds.isFinite else { return }
            self.elapsed = time.seconds
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshScreens() }
        tick = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let liveStatus = self.renderer.tracker.latest.status
            if self.status != liveStatus { self.status = liveStatus }
            let transport = self.player.timeControlStatus
            let playing = transport != .paused
            if self.playing != playing { self.playing = playing }
            let buffering = self.hasVideo && transport == .waitingToPlayAtSpecifiedRate
            if self.buffering != buffering { self.buffering = buffering }
        }
        refreshScreens()
    }

    deinit {
        pendingLoad?.cancel()
        tick?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        renderer.tracker.setEnabled(false)
    }

    func openFile(in folder: URL? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = folder
        if folder != nil { panel.message = "在共享文件夹中选择要播放的视频。" }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        clearMedia()
        loading = true
        title = url.lastPathComponent.isEmpty ? "网络视频" : url.lastPathComponent
        let request = loadID
        pendingLoad = Task { @MainActor [weak self] in
            do {
                let asset = AVURLAsset(url: url)
                let video = try await asset.loadTracks(withMediaType: .video)
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                guard let self, self.loadID == request else { return }
                guard playable, !video.isEmpty, duration.isFinite, duration > 0 else {
                    self.mediaError(url.isFileURL
                        ? "此文件没有可播放的视频轨道。请试用 H.264 或 HEVC 编码的 MP4 / MOV。"
                        : "链接未返回可播放的视频。请确认它是可直接读取的 MP4 / MOV 文档地址。")
                    return
                }
                self.prepare(asset, duration: duration)
            } catch {
                guard let self, self.loadID == request else { return }
                self.mediaError(url.isFileURL
                    ? "无法打开视频。\(error.localizedDescription)"
                    : "无法打开网络视频。请确认链接可访问、未过期，并指向视频文件。")
            }
        }
    }

    private func prepare(_ asset: AVURLAsset, duration: Double) {
        let item = AVPlayerItem(asset: asset)
        let isNetworkURL = !asset.url.isFileURL
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        item.add(output)
        renderer.output = output
        self.duration = duration
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.loading = false
                    self.hasVideo = true
                    self.startPlayback()
                case .failed:
                    self.mediaError(isNetworkURL
                        ? "网络视频播放失败。请检查连接、链接有效期和视频编码。"
                        : "解码失败。\(item.error?.localizedDescription ?? "此编码可能不受 macOS 支持。")")
                default: break
                }
            }
        }
        itemObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.player.currentItem === item else { return }
            self.seek(to: 0)
        })
        itemObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.player.currentItem === item else { return }
            self.mediaError("播放中断。请检查视频所在的共享或网络连接，再重新打开。")
        })
        player.replaceCurrentItem(with: item)
    }

    func showTestPattern() {
        clearMedia()
        title = "双眼测试图"
    }

    private func mediaError(_ message: String) {
        clearMedia()
        title = "双眼测试图"
        error = message
    }

    private func clearMedia() {
        pendingLoad?.cancel()
        pendingLoad = nil
        loadID = UUID()
        seeking = false
        seekID = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        renderer.output = nil
        itemObservation = nil
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers.removeAll()
        elapsed = 0
        duration = 0
        error = nil
        loading = false
        hasVideo = false
        playing = false
        buffering = false
    }

    func togglePlayback() {
        guard hasVideo else { return }
        if player.timeControlStatus == .paused { startPlayback() } else { player.pause() }
    }

    private func startPlayback() {
        if !outputActive, let screen = NSScreen.screens.first(where: { isXREAL($0) && isFullSBS($0) }) {
            startOutput(on: screen)
        } else if !outputActive, NSScreen.screens.contains(where: isXREAL) {
            error = "眼镜已连接。请开启 Full SBS，并在 macOS「显示器」中选为扩展显示器，然后再播放。"
            return
        }
        player.play()
    }

    func seek(to seconds: Double) {
        guard hasVideo else { return }
        let target = min(max(seconds, 0), duration)
        elapsed = target
        seeking = true
        let request = UUID()
        seekID = request
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.seekID == request else { return }
                self.seeking = false
            }
        }
    }

    // Full SBS must be its own extended display. The pixel mode may be HiDPI.
    private func isFullSBS(_ screen: NSScreen) -> Bool {
        guard let id = displayID(screen),
              CGDisplayIsBuiltin(id) == 0, CGDisplayIsInMirrorSet(id) == 0,
              let mode = CGDisplayCopyDisplayMode(id) else { return false }
        let wide = (mode.pixelWidth == 3840 && mode.pixelHeight == 1080)
            || (mode.width == 3840 && mode.height == 1080)
        return wide && abs(screen.frame.width / screen.frame.height - (3840.0 / 1080.0)) < 0.02
    }

    private func isXREAL(_ screen: NSScreen) -> Bool {
        guard let id = displayID(screen), CGDisplayIsBuiltin(id) == 0 else { return false }
        // XREAL devices use the MRG EDID manufacturer ID.
        let mrg = UInt32((13 << 10) | (18 << 5) | 7)
        return CGDisplayVendorNumber(id) == mrg
            || screen.localizedName.localizedCaseInsensitiveContains("XREAL")
            || screen.localizedName.localizedCaseInsensitiveContains("NREAL")
    }

    private func displayID(_ screen: NSScreen?) -> CGDirectDisplayID? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func refreshScreens() {
        let screens = NSScreen.screens
        xrealConnected = screens.contains(where: isXREAL)
        glassesPresent = screens.contains(where: isFullSBS)
        guard let window = outputWindow, let outputDisplayID else { return }
        guard let screen = screens.first(where: { displayID($0) == outputDisplayID && isFullSBS($0) }) else {
            stopOutput()
            return
        }
        window.setFrame(screen.frame, display: true)
    }

    func toggleOutput() {
        if outputActive { stopOutput(); return }
        let candidates = NSScreen.screens.filter(isFullSBS)
        if let identified = candidates.first(where: isXREAL) {
            startOutput(on: identified)
        } else if candidates.count == 1, let screen = candidates.first, !xrealConnected {
            startOutput(on: screen)
        } else {
            error = "未发现 3840 × 1080 扩展显示器。请开启眼镜的 Full SBS，并在 macOS「显示器」中关闭镜像。"
        }
    }

    private func startOutput(on screen: NSScreen) {
        guard let id = displayID(screen) else { return }
        error = nil
        moveControlsOffDisplay(id)
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = .mainMenu + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        let view = RenderView(renderer: renderer, stereo: true)
        window.contentView = view
        window.ignoresMouseEvents = true
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        outputDisplayID = id
        outputWindow = window
        outputActive = true
    }

    private func moveControlsOffDisplay(_ id: CGDirectDisplayID) {
        guard let window = controlsWindow, displayID(window.screen) == id else { return }
        let otherScreens = NSScreen.screens.filter { displayID($0) != id }
        let mac = otherScreens.first { screen in
            guard let screenID = displayID(screen) else { return false }
            return CGDisplayIsBuiltin(screenID) != 0
        } ?? otherScreens.first
        guard let bounds = mac?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: max(bounds.minX, bounds.midX - window.frame.width / 2),
                                      y: max(bounds.minY, bounds.midY - window.frame.height / 2)))
    }

    func stopOutput() {
        player.pause()
        closeOutput()
    }

    func closeOutput() {
        outputWindow?.orderOut(nil)
        outputWindow?.close()
        outputWindow = nil
        outputDisplayID = nil
        outputActive = false
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: togglePlayback()
        case 53: if outputActive { stopOutput() }
        case 123: seek(to: elapsed - 10)
        case 124: seek(to: elapsed + 10)
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
            renderer.resetView()
        }
        return true
    }
}
