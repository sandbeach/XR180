import AVFoundation
import MetalKit
import simd

func require(_ success: @autoclosure () -> Bool, _ message: String) {
    if !success() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func mockPacket(_ magic: UInt8, time: UInt64) -> Data {
    var bytes: [UInt8] = [magic, 0x36, 0, 0, 0, 128]
    bytes += Array(repeating: 0, count: 128)
    func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { buffer in
            bytes.replaceSubrange((6+offset)..<(6+offset+buffer.count), with: buffer)
        }
    }
    put(time, at: 8)
    put(UInt32(0x0b), at: 24)
    put(Float(0.01).bitPattern, at: 32)
    put(Float(9.8).bitPattern, at: 40)
    return Data(bytes)
}

func checkTracking() {
    var framer = IMUFramer()
    var filter = PoseFilter()
    var parsed: [IMUSample] = []
    let first = mockPacket(0x28, time: 10)
    let last = mockPacket(0x27, time: 20)
    framer.append(Data([0, 0x28, 0x36, 0, 0, 0, 1]) + first.prefix(19)) { parsed.append($0) }
    require(parsed.isEmpty, "partial packet")
    framer.append(first.dropFirst(19) + last) { parsed.append($0) }
    require(parsed.map(\.time) == [10, 20], "both firmware headers after junk and partial packet")
    require(abs(parsed[1].gyro.y - 0.01) < 1e-6, "gyro decoding")
    require(abs(parsed[1].acceleration.x - 9.8) < 1e-5, "accelerometer decoding")
    for t in 1...1500 {
        let yawRate: Float = t <= 500 ? 0.01 : 0.51
        filter.feed(IMUSample(time: UInt64(t) * 1_000_000, gyro: SIMD3(0, yawRate, 0),
                              acceleration: SIMD3(9.8, 0, 0)))
    }
    require(filter.calibrated, "calibration")
    require(abs(filter.relative.y - 0.5) < 0.002, "turn integrated in radians")
    filter.recenter()
    require(simd_length(filter.relative) < 0.001, "recenter")
    print("PASS: fragmented IMU stream, both headers, calibration, yaw and recenter")
}

func encodeFixture(_ url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 256, AVVideoHeightKey: 128
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferWidthKey as String: 256,
                                      kCVPixelBufferHeightKey as String: 128])
    writer.add(input)
    require(writer.startWriting(), "start writing \(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let frame = buffer!
    CVPixelBufferLockBaseAddress(frame, [])
    let base = CVPixelBufferGetBaseAddress(frame)!
    for y in 0..<128 {
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(frame)).assumingMemoryBound(to: UInt32.self)
        for x in 0..<256 { row[x] = x < 128 ? 0xffff0000 : 0xff0000ff }
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    for index in 0..<15 {
        let limit = Date(timeIntervalSinceNow: 2)
        while !input.isReadyForMoreMediaData && Date() < limit { Thread.sleep(forTimeInterval: 0.006) }
        require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)),
                "write synthetic stereo video")
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    require(done.wait(timeout: .now() + 8) == .success && writer.status == .completed, "finish fixture")
}

func checkRendering(_ url: URL) throws {
    let renderer = try Renderer()
    let playback = Playback(renderer: renderer)
    playback.open(url)
    let deadline = Date(timeIntervalSinceNow: 8)
    while !playback.hasVideo && playback.error == nil && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    require(playback.hasVideo, "AVFoundation prepares native MP4: \(playback.error ?? "timed out")")
    guard let output = renderer.output else { fatalError("Missing video output") }
    var pixel: CVPixelBuffer?
    let frameDeadline = Date(timeIntervalSinceNow: 5)
    while pixel == nil && Date() < frameDeadline {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time) {
            pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        }
        if pixel == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }
    require(pixel != nil, "decodes frames during playback")
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &cache)
    var image: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache!, pixel!, nil, .bgra8Unorm, 256, 128, 0, &image)
    require(status == kCVReturnSuccess, "decoded frame shares surface with Metal")
    let source = CVMetalTextureGetTexture(image!)!
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: 128, height: 36, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget]
    let target = renderer.device.makeTexture(descriptor: descriptor)!
    func render(swap: Bool, yaw: Float = 0) -> (left: [UInt8], right: [UInt8]) {
        renderer.settings.swap = swap
        renderer.manual.x = yaw
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        let command = renderer.queue.makeCommandBuffer()!
        renderer.encode(pass, command: command, texture: source, stereo: true, testPattern: false)
        command.commit()
        command.waitUntilCompleted()
        require(command.status == .completed, "GPU render \(String(describing: command.error))")
        func pixel(_ x: Int) -> [UInt8] {
            var result = Array(repeating: UInt8.zero, count: 4)
            target.getBytes(&result, bytesPerRow: 4, from: MTLRegionMake2D(x, 18, 1, 1), mipmapLevel: 0)
            return result
        }
        return (pixel(32), pixel(96))
    }
    for projection in [Projection.equirectangular, .equidistant, .equisolid, .flat] {
        renderer.settings.projection = projection
        let colors = render(swap: false)
        require(colors.left[2] > 200 && colors.left[0] < 30, "left eye samples red")
        require(colors.right[0] > 200 && colors.right[2] < 30, "right eye samples blue")
        let exchanged = render(swap: true)
        require(exchanged.left[0] > 200 && exchanged.right[2] > 200, "swap eyes")
    }
    renderer.settings.projection = .equirectangular
    let behind = render(swap: false, yaw: .pi)
    require(behind.left[0] == 0 && behind.left[2] == 0 &&
            behind.right[0] == 0 && behind.right[2] == 0, "outside the VR180 hemisphere is black")
    withExtendedLifetime(image) {}
    print("PASS: AVPlayer decoding, Metal projection, separate stereo eyes, swap, behind-camera clipping")
}

func checkRemoteAddresses() throws {
    let smb = try RemoteSource(" SMB://nas.local/测试 影片/ ")
    guard case let .share(shareURL) = smb else { fatalError("Expected SMB share") }
    require(shareURL.scheme == "smb" && shareURL.path == "/测试 影片", "SMB accepts Unicode and spaces")

    let https = try RemoteSource("https://nas.example:8443/video.mp4?token=a%2Fb")
    guard case let .video(videoURL) = https else { fatalError("Expected HTTPS video") }
    require(videoURL.port == 8443 && videoURL.query == "token=a%2Fb", "HTTPS preserves port and signed query")

    for invalid in ["smb://nas.local", "smb://nas.local/Video/subfolder", "smb://nas.local/%2E%2E",
                    "smb://nas.local/Video%2Fpath", "smb://user:secret@nas.local/Video",
                    "https://nas.example", "http://nas.example/video.mp4"] {
        require((try? RemoteSource(invalid)) == nil, "reject incomplete, ambiguous or unsupported network address")
    }
    print("PASS: SMB and HTTPS address handling")
}

checkTracking()
do { try checkRemoteAddresses() }
catch { fputs("FAIL: \(error)\n", stderr); exit(1) }

if CommandLine.arguments.count > 1 {
    let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
    defer { try? FileManager.default.removeItem(at: fixture) }
    do { try encodeFixture(fixture); try checkRendering(fixture) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
