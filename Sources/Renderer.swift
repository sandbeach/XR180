import AppKit
import AVFoundation
import MetalKit
import simd

enum Projection: UInt32, CaseIterable, Identifiable {
    case equirectangular, equidistant, equisolid, flat
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .equirectangular: return "VR180 等距柱状"
        case .equidistant: return "VR180 等距鱼眼"
        case .equisolid: return "VR180 等立体角鱼眼"
        case .flat: return "平面 3D"
        }
    }
}

enum StereoLayout: UInt32, CaseIterable, Identifiable {
    case sideBySide, topBottom, mono
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .sideBySide: return "左右并排"
        case .topBottom: return "上下排列"
        case .mono: return "单眼 / 2D"
        }
    }
}

struct RenderSettings {
    var projection = Projection.equirectangular
    var layout = StereoLayout.sideBySide
    var swap = false
    var flip = false
    var rotation: UInt32 = 0
    var fieldOfView: Float = 57
    var lensFieldOfView: Float = 180
    var signs = SIMD3<Float>(-1, 1, -1)
}

struct ProjectionParams {
    var cameraX: SIMD4<Float>
    var cameraY: SIMD4<Float>
    var cameraZ: SIMD4<Float>
    var optics: SIMD4<Float>
    var modes: SIMD4<UInt32>
    var options: SIMD4<UInt32>
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let fallback: MTLTexture
    private let cache: CVMetalTextureCache
    private var frame: CVMetalTexture?
    private var textureError = false

    let tracker = HeadTracking()
    var manual = SIMD2<Float>.zero
    var settings = RenderSettings()
    var output: AVPlayerItemVideoOutput? {
        didSet {
            frame = nil
            textureError = false
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
    var didFailFrame: (() -> Void)?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let fallback = device.makeTexture(descriptor: .texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)),
              let shader = Bundle.main.url(forResource: "Projection", withExtension: "metal") else {
            throw RenderError.unavailable
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw RenderError.unavailable }
        let library = try device.makeLibrary(source: String(contentsOf: shader, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name: "project")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.device = device
        self.queue = queue
        self.fallback = fallback
        self.cache = cache
        var black: UInt32 = 0xff000000
        fallback.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                         withBytes: &black, bytesPerRow: 4)
    }

    private enum RenderError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法初始化 Metal 渲染器。" }
    }

    func resetView() {
        manual = .zero
        tracker.recenter()
    }

    func drag(x: CGFloat, y: CGFloat) {
        manual.x -= Float(x) * 0.0035
        manual.y += Float(y) * 0.0035
        manual.x = atan2(sin(manual.x), cos(manual.x))
        manual.y = min(max(manual.y, -1.5), 1.5)
    }

    func parameters(stereo: Bool, texture: MTLTexture, testPattern: Bool) -> ProjectionParams {
        let pose = tracker.latest.pose * settings.signs
        let yaw = simd_quatf(angle: pose.y + manual.x, axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: pose.x + manual.y, axis: SIMD3(1, 0, 0))
        let roll = simd_quatf(angle: pose.z, axis: SIMD3(0, 0, 1))
        let camera = simd_float3x3(yaw * pitch * roll)
        let diagonal = tan(settings.fieldOfView * .pi / 360)
        let height = diagonal / hypot(Float(16.0 / 9.0), 1)
        var sourceAspect = Float(texture.width) / Float(texture.height)
        if settings.layout == .sideBySide { sourceAspect *= 0.5 }
        if settings.layout == .topBottom { sourceAspect *= 2 }
        return ProjectionParams(
            cameraX: SIMD4(camera.columns.0, 0), cameraY: SIMD4(camera.columns.1, 0),
            cameraZ: SIMD4(camera.columns.2, 0),
            optics: SIMD4(height * 16 / 9, height, settings.lensFieldOfView * .pi / 180, sourceAspect),
            modes: SIMD4(settings.projection.rawValue, settings.layout.rawValue,
                         settings.swap ? 1 : 0, stereo ? 1 : 0),
            options: SIMD4(testPattern ? 1 : 0, settings.flip ? 1 : 0, settings.rotation, 0))
    }

    func encode(_ pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, texture: MTLTexture,
                stereo: Bool, testPattern: Bool) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var params = parameters(stereo: stereo, texture: texture, testPattern: testPattern)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ProjectionParams>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func draw(_ view: MTKView, stereo: Bool) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        updateVideoFrame()
        let retainedFrame = frame
        let texture = retainedFrame.flatMap(CVMetalTextureGetTexture) ?? fallback
        encode(pass, command: command, texture: texture, stereo: stereo, testPattern: output == nil)
        command.addCompletedHandler { _ in withExtendedLifetime(retainedFrame) {} }
        command.present(drawable)
        command.commit()
    }

    private func updateVideoFrame() {
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard time.isNumeric, output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        var result: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(buffer),
            CVPixelBufferGetHeight(buffer), 0, &result)
        if status == kCVReturnSuccess, let result {
            frame = result
        } else if !textureError {
            textureError = true
            DispatchQueue.main.async { [weak self] in self?.didFailFrame?() }
        }
    }
}

final class RenderView: MTKView, MTKViewDelegate {
    let renderer: Renderer
    let stereo: Bool
    var onKey: ((NSEvent) -> Bool)?

    init(renderer: Renderer, stereo: Bool) {
        self.renderer = renderer
        self.stereo = stereo
        super.init(frame: .zero, device: renderer.device)
        preferredFramesPerSecond = 60
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let layer = layer as? CAMetalLayer { layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("RenderView must be created in code") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { renderer.draw(view, stereo: stereo) }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) { renderer.drag(x: event.deltaX, y: event.deltaY) }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
