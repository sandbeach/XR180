import AppKit
import SwiftUI

private let ink = Color(red: 0.055, green: 0.070, blue: 0.097)
private let panel = Color(red: 0.084, green: 0.106, blue: 0.139)
private let cyan = Color(red: 0.36, green: 0.84, blue: 0.92)

struct PlayerInterface: View {
    @ObservedObject var player: Playback
    @State private var scrubbing = false
    @State private var position = 0.0
    @State private var showingNAS = false
    @State private var remoteSelection: RemoteSelection?

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 24).padding(.vertical, 19)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                videoPane.frame(maxWidth: .infinity)
                settingsPane.frame(width: 244)
            }
            .padding(24)
            Spacer(minLength: 0)
            Divider()
            connectionBar.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .background(ink)
        .preferredColorScheme(.dark)
        .frame(minWidth: 920, minHeight: 600)
        .sheet(isPresented: $showingNAS, onDismiss: openRemoteSelection) {
            RemoteInterface { selection in
                remoteSelection = selection
                showingNAS = false
            } onCancel: {
                showingNAS = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(cyan)
                .frame(width: 40, height: 40)
                .background(cyan.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("XR180").font(.system(size: 22, weight: .semibold))
                Text("XREAL One Pro  ·  VR180 播放器").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { player.showTestPattern() } label: {
                Label("测试图", systemImage: "viewfinder")
            }
            Button { player.openFile() } label: {
                Label("打开视频", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            Button { showingNAS = true } label: {
                Label("NAS 视频", systemImage: "externaldrive.connected.to.line.below")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Button { player.toggleOutput() } label: {
                Label(player.outputActive ? "停止输出" : "输出到眼镜",
                      systemImage: player.outputActive ? "stop.fill" : "display")
            }
            .buttonStyle(.borderedProminent)
            .tint(cyan.opacity(0.9))
            .foregroundStyle(ink)
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .controlSize(.large)
    }

    private func openRemoteSelection() {
        let selection = remoteSelection
        remoteSelection = nil
        switch selection {
        case .browse(let folder, let notice):
            if let notice {
                let alert = NSAlert()
                alert.messageText = "钥匙串"
                alert.informativeText = notice
                alert.addButton(withTitle: "继续浏览")
                alert.runModal()
            }
            player.openFile(in: folder)
        case .play(let url): player.open(url)
        case nil: break
        }
    }

    private var controlsOnly: Bool {
        player.outputActive || (player.xrealConnected && (player.hasVideo || player.loading))
    }

    private var videoPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(player.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !controlsOnly {
                    Text("左眼预览").font(.caption).foregroundStyle(.secondary)
                }
            }
            ZStack {
                if controlsOnly {
                    VStack(spacing: 10) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 34))
                            .foregroundStyle(cyan)
                            .accessibilityHidden(true)
                        Text(player.outputActive ? "画面仅在眼镜中显示" : "等待眼镜播放")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                } else {
                    Preview(player: player).aspectRatio(16 / 9, contentMode: .fit)
                }
                if player.loading || player.buffering {
                    VStack(spacing: 8) {
                        ProgressView(player.preparingCompatibility ? "正在准备兼容播放…" :
                                     player.loading ? "正在打开…" : "正在缓冲…")
                        if player.preparingCompatibility {
                            Button("取消") { player.cancelCompatibility() }
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 12) {
                Button { player.seek(to: player.elapsed - 10) } label: {
                    Image(systemName: "gobackward.10").accessibilityLabel("后退 10 秒")
                }
                Button { player.togglePlayback() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .accessibilityLabel(player.playing ? "暂停" : "播放")
                }
                .keyboardShortcut(.space, modifiers: [])
                Button { player.seek(to: player.elapsed + 10) } label: {
                    Image(systemName: "goforward.10").accessibilityLabel("前进 10 秒")
                }
                Slider(value: Binding(get: { scrubbing ? position : player.elapsed },
                                      set: { value in
                                          if scrubbing { position = value }
                                          else { player.seek(to: value) }
                                      }),
                       in: 0...max(player.duration, player.elapsed, 0.01)) { editing in
                    if editing { position = player.elapsed }
                    scrubbing = editing
                    if !editing { player.seek(to: position) }
                }
                .accessibilityLabel("播放进度")
                .tint(cyan)
                Text("\(time(scrubbing ? position : player.elapsed)) / \(time(player.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .disabled(!player.hasVideo)
            .buttonStyle(.borderless)
            if let error = player.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !controlsOnly {
                Text("拖动预览可转动视角   ·   R 回正   ·   Esc 停止眼镜输出")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("画面与姿态").font(.headline)
            Picker("投影", selection: $player.settings.projection) {
                ForEach(Projection.allCases) { Text($0.title).tag($0) }
            }
            Picker("片源", selection: $player.settings.layout) {
                ForEach(StereoLayout.allCases) { Text($0.title).tag($0) }
            }
            Picker("旋转", selection: $player.settings.rotation) {
                ForEach(0..<4, id: \.self) { Text("\($0 * 90)°").tag(UInt32($0)) }
            }
            HStack {
                Toggle("交换左右眼", isOn: $player.settings.swap)
                Spacer(minLength: 2)
                Toggle("上下翻转", isOn: $player.settings.flip)
            }
            Divider()
            angle("视野", value: $player.settings.fieldOfView, range: 35...110)
                .disabled(player.settings.projection == .flat && player.hasVideo)
            if player.settings.projection == .equidistant || player.settings.projection == .equisolid {
                angle("鱼眼镜头", value: $player.settings.lensFieldOfView, range: 140...220)
            }
            Divider()
            Toggle("使用眼镜头部追踪", isOn: $player.tracking)
                .tint(cyan)
            HStack {
                Button("回正") { player.renderer.resetView() }
                Button("校准") { player.renderer.tracker.recalibrate() }
                    .disabled(player.status != .live)
                Spacer()
                Menu("方向") {
                    axis("反转抬头", index: 0, normal: -1)
                    axis("反转转头", index: 1, normal: 1)
                    axis("反转歪头", index: 2, normal: -1)
                }
                .fixedSize()
                .disabled(!player.tracking)
            }
        }
        .controlSize(.small)
        .padding(15)
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func axis(_ label: String, index: Int, normal: Float) -> some View {
        Toggle(label, isOn: Binding(get: { player.settings.signs[index] != normal },
                                    set: { player.settings.signs[index] = $0 ? -normal : normal }))
    }

    private func angle(_ label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue))°").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1).accessibilityLabel(label).tint(cyan)
        }
    }

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Circle().fill(player.glassesPresent ? cyan : .gray).frame(width: 7, height: 7)
            Text(player.outputActive ? "正在输出 Full SBS" :
                 player.glassesPresent ? "Full SBS 已就绪" : "等待 3840 × 1080 扩展显示器")
            Spacer()
            Text(trackingLabel)
                .foregroundStyle(player.status == .live ? cyan : .secondary)
        }
        .font(.caption)
    }

    private var trackingLabel: String {
        switch player.status {
        case .off: return "头部追踪已关闭"
        case .connecting: return "正在连接眼镜传感器…"
        case .waiting: return "已连接 · 等待姿态数据"
        case .calibrating(let progress): return "校准 \(progress)% · 保持眼镜静止"
        case .live: return "3DoF 头部追踪已就绪"
        case .unavailable: return "眼镜传感器不可达 · 检查 Ethernet 和本地网络权限"
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = Int(seconds)
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct Preview: NSViewRepresentable {
    let player: Playback
    func makeNSView(context: Context) -> RenderView {
        let view = RenderView(renderer: player.renderer, stereo: false)
        view.onKey = { [weak player] in player?.handleKey($0) ?? false }
        return view
    }
    func updateNSView(_ view: RenderView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var player: Playback?
    private var keyMonitor: Any?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let player = try Playback(renderer: Renderer())
            self.player = player
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 990, height: 630),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "XR180"
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentViewController = NSHostingController(rootView: PlayerInterface(player: player))
            window.contentMinSize = NSSize(width: 920, height: 600)
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            player.controlsWindow = window
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak player] event in
                if event.keyCode == 53, event.window?.sheetParent == nil, player?.outputActive == true {
                    player?.stopOutput()
                    return nil
                }
                return event
            }
            if let pendingURL { player.open(pendingURL) }
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.isFileURL else { return }
        if let player { player.open(url) }
        else { pendingURL = url }
    }

    func windowWillClose(_ notification: Notification) { player?.closeOutput() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        player?.closeOutput()
        player?.tracking = false
    }
}
