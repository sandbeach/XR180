import Foundation

final class CompatibleMovie {
    let directory: URL
    let url: URL
    fileprivate(set) var copiedVideo = false

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("XR180-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("playback.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum Compatibility {
    private static let inputOptions = [
        "-protocol_whitelist", "file",
        "-format_whitelist", "mov,matroska,webm,avi,mpegts,mpeg,flv,asf,ogg,ivf"
    ]

    private struct Probe: Decodable {
        let streams: [Video]
    }

    private struct Video: Decodable {
        let codec_name: String?
        let width: Int?
        let height: Int?
        let avg_frame_rate: String?
        let pix_fmt: String?
        let color_transfer: String?
    }

    enum Failure: LocalizedError {
        case helperMissing, noVideo, cannotConvert, noSpace
        var errorDescription: String? {
            switch self {
            case .helperMissing: return "此构建未包含 FFmpeg 兼容播放组件。"
            case .noVideo: return "无法读取可播放的视频轨道。请检查文件是否完整、可访问且未加密。"
            case .cannotConvert: return "无法准备兼容播放。片源编码可能不受支持，或当前 Mac 无法以该尺寸编码。"
            case .noSpace: return "磁盘空间不足，无法准备临时播放文件。"
            }
        }
    }

    private static func executable(_ name: String) throws -> URL {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw Failure.helperMissing }
        return url
    }

    static func prepareCopy(of input: URL, allowVideoCopy: Bool = true) async throws -> CompatibleMovie {
        guard input.isFileURL else { throw Failure.noVideo }
        let probe = try executable("ffprobe")
        let movie = try CompatibleMovie()
        let metadata = movie.directory.appendingPathComponent("probe.json")
        let errorLog = movie.directory.appendingPathComponent("errors.log")
        let result = try await run(probe, ["-v", "error"] + inputOptions + [
            "-select_streams", "V:0",
            "-show_entries", "stream=codec_name,width,height,avg_frame_rate,pix_fmt,color_transfer",
            "-of", "json", "-i", input.path
        ], stdout: metadata, stderr: errorLog)
        guard result == 0, let json = try? Data(contentsOf: metadata),
              let video = try? JSONDecoder().decode(Probe.self, from: json).streams.first,
              let width = video.width, let height = video.height, width > 0, height > 0 else {
            throw Failure.noVideo
        }

        let ffmpeg = try executable("ffmpeg")
        let source = ["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-y"] + inputOptions + [
                      "-noautorotate", "-i", input.path,
                      "-map", "0:V:0", "-map", "0:a:0?", "-map_chapters", "-1", "-sn", "-dn"]
        let destination = ["-c:a", "aac", "-b:a", "256k", movie.url.path]

        if allowVideoCopy, let codec = video.codec_name, ["h264", "hevc"].contains(codec) {
            let tag = codec == "hevc" ? ["-tag:v", "hvc1"] : []
            if try await run(ffmpeg, source + ["-c:v", "copy"] + tag + destination,
                             stderr: errorLog) == 0 {
                movie.copiedVideo = true
                return movie
            }
            try checkDiskError(errorLog)
        }

        return try await encode(video, width: width, height: height, movie: movie,
                                ffmpeg: ffmpeg, source: source, destination: destination, errorLog: errorLog)
    }

    private static func encode(_ video: Video, width: Int, height: Int, movie: CompatibleMovie,
                               ffmpeg: URL, source: [String], destination: [String], errorLog: URL) async throws
        -> CompatibleMovie {
        let frameRate = video.avg_frame_rate?.split(separator: "/").compactMap { Double($0) } ?? []
        let fps = frameRate.count == 2 && frameRate[1] > 0 ? frameRate[0] / frameRate[1] : 30
        let bitrate = Int(min(160_000_000, max(4_000_000, Double(width) * Double(height) * min(max(fps, 24), 120) * 0.12)))
        let isHDR = ["smpte2084", "arib-std-b67"].contains(video.color_transfer ?? "")
        let main10 = isHDR || ["10", "12", "16"].contains { video.pix_fmt?.contains($0) == true }
        let pad = ["-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2:0:0", "-b:v", "\(bitrate)"]
        let hevc = ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-profile:v", main10 ? "main10" : "main",
                    "-pix_fmt", main10 ? "p010le" : "nv12"]
        if try await run(ffmpeg, source + pad + hevc + destination, stderr: errorLog) == 0 { return movie }
        try checkDiskError(errorLog)
        if !main10 && width <= 4096 && height <= 4096 {
            let h264 = ["-c:v", "h264_videotoolbox", "-pix_fmt", "nv12", "-allow_sw", "1"]
            if try await run(ffmpeg, source + pad + h264 + destination, stderr: errorLog) == 0 { return movie }
            try checkDiskError(errorLog)
        }
        throw Failure.cannotConvert
    }

    private static func checkDiskError(_ log: URL) throws {
        if let data = try? Data(contentsOf: log),
           String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("no space left on device") {
            throw Failure.noSpace
        }
    }

    private static func run(_ executable: URL, _ arguments: [String], stdout: URL? = nil,
                            stderr: URL) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = try stdout.map(makeLog)
        let errors = try makeLog(stderr)
        defer { try? output?.close(); try? errors.close() }
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let command = CancellableCommand(process)
        let status = try await withTaskCancellationHandler {
            try await command.run()
        } onCancel: {
            command.cancel()
        }
        try Task.checkCancellation()
        return status
    }

    private static func makeLog(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 0)
        return file
    }
}

private final class CancellableCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false

    init(_ process: Process) { self.process = process }

    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}
