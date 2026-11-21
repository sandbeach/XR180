import Foundation
import Network
import simd

// Wire format documented by comxtohr/xreal-one-mac-probe and Skarian/one-xr.
struct IMUSample {
    let time: UInt64
    let gyro: SIMD3<Float>
    let acceleration: SIMD3<Float>
}

struct IMUFramer {
    private var bytes: [UInt8] = []

    mutating func append(_ data: Data, consume: (IMUSample) -> Void) {
        bytes.append(contentsOf: data)
        var index = 0
        while bytes.count - index >= 6 {
            let magic = bytes[index]
            guard (magic == 0x27 || magic == 0x28),
                  bytes[index + 1] == 0x36, bytes[index + 2] == 0,
                  bytes[index + 3] == 0, bytes[index + 4] == 0,
                  bytes[index + 5] == 128 else {
                index += 1
                continue
            }
            guard bytes.count - index >= 134 else { break }
            let body = index + 6
            index += 134
            let type = read32(body + 24)
            guard type == 0x0B else { continue }
            let time = UInt64(read32(body + 8)) | (UInt64(read32(body + 12)) << 32)
            let gyro = vector(body + 28)
            let accel = vector(body + 40)
            guard time > 0, simd_length_squared(gyro) < 900,
                  simd_length_squared(accel) < 10_000 else { continue }
            consume(IMUSample(time: time, gyro: gyro, acceleration: accel))
        }
        if index > 0 { bytes.removeFirst(index) }
    }

    private func read32(_ i: Int) -> UInt32 {
        UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
            | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
    }

    private func vector(_ i: Int) -> SIMD3<Float> {
        SIMD3(Float(bitPattern: read32(i)), Float(bitPattern: read32(i + 4)),
              Float(bitPattern: read32(i + 8)))
    }
}

struct PoseFilter {
    private var count = 0
    private var bias = SIMD3<Float>.zero
    private var sum = SIMD3<Float>.zero
    private var gravitySum = SIMD3<Float>.zero
    private var lastTime: UInt64 = 0
    private var stillTime: Float = 0
    private var angles = SIMD3<Float>.zero // pitch, yaw, roll
    private var center = SIMD3<Float>.zero

    var calibrated: Bool { count >= 500 }
    var progress: Int { min(100, count / 5) }
    var relative: SIMD3<Float> {
        let delta = angles - center
        return SIMD3(wrap(delta.x), wrap(delta.y), wrap(delta.z))
    }

    mutating func recenter() { center = angles }

    mutating func feed(_ sample: IMUSample) {
        let gravity = SIMD3(sample.acceleration.z, sample.acceleration.y, sample.acceleration.x)
        if !calibrated {
            guard simd_length(sample.gyro) < 0.08 else {
                count = 0
                sum = .zero
                gravitySum = .zero
                return
            }
            count += 1
            sum += sample.gyro
            gravitySum += gravity
            if calibrated {
                bias = sum / Float(count)
                let avg = gravitySum / Float(count)
                if simd_length(avg) > 0.1 {
                    angles.x = atan2(-avg.x, hypot(avg.y, avg.z))
                    angles.z = atan2(avg.y, avg.z)
                }
                recenter()
                lastTime = sample.time
            }
            return
        }

        let previous = lastTime
        lastTime = sample.time
        guard sample.time > previous, sample.time - previous < 100_000_000 else { return }
        let dt = Float(sample.time - previous) * 1e-9
        let velocity = sample.gyro - bias
        if simd_length(velocity) < 0.012 {
            stillTime += dt
            if stillTime > 0.25 { bias += velocity * min(dt * 0.55, 1) }
        } else {
            stillTime = 0
        }
        angles += velocity * dt
        let magnitude = simd_length(gravity)
        // Correct tilt gently and ignore readings dominated by linear acceleration.
        if (7...12).contains(magnitude) || (0.75...1.25).contains(magnitude) {
            let weight = 1 - exp(-dt / 0.12)
            angles.x += weight * wrap(atan2(-gravity.x, hypot(gravity.y, gravity.z)) - angles.x)
            angles.z += weight * wrap(atan2(gravity.y, gravity.z) - angles.z)
        }
        angles = SIMD3(wrap(angles.x), wrap(angles.y), wrap(angles.z))
    }

    private func wrap(_ value: Float) -> Float { atan2(sin(value), cos(value)) }
}

final class HeadTracking {
    enum Status: Equatable {
        case off, connecting, waiting, calibrating(Int), live, unavailable
    }

    private let queue = DispatchQueue(label: "XR180.IMU", qos: .userInteractive)
    private let lock = NSLock()
    private var snapshot: (Status, SIMD3<Float>) = (.off, .zero)
    private var connection: NWConnection?
    private var enabled = false
    private var generation = 0
    private var framer = IMUFramer()
    private var filter = PoseFilter()
    private var endpointIndex = 0
    private var lastPacket = DispatchTime.now()
    private var lastPublish = DispatchTime.now()
    private let endpoints = ["169.254.2.1", "169.254.1.1"]

    var latest: (status: Status, pose: SIMD3<Float>) {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func setEnabled(_ value: Bool) {
        queue.async {
            guard self.enabled != value else { return }
            self.enabled = value
            self.generation += 1
            self.connection?.cancel()
            self.connection = nil
            self.endpointIndex = 0
            if value { self.connect() }
            else { self.publish(.off) }
        }
    }

    func recenter() {
        queue.async {
            self.filter.recenter()
            if self.filter.calibrated, self.latest.status == .live { self.publish(.live) }
        }
    }

    func recalibrate() {
        queue.async {
            self.filter = PoseFilter()
            if self.latest.status == .live { self.publish(.calibrating(0)) }
        }
    }

    private func publish(_ status: Status) {
        lock.lock()
        snapshot = (status, status == .live ? filter.relative : .zero)
        lock.unlock()
    }

    private func connect() {
        guard enabled else { return }
        generation += 1
        let attempt = generation
        let host = endpoints[endpointIndex]
        let client = NWConnection(host: NWEndpoint.Host(host), port: 52998, using: .tcp)
        connection = client
        filter = PoseFilter()
        framer = IMUFramer()
        lastPacket = .now()
        lastPublish = .now()
        publish(.connecting)
        client.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client, self.generation == attempt else { return }
            switch state {
            case .ready:
                self.lastPacket = .now()
                self.publish(.waiting)
                self.receive(client, attempt: attempt)
            case .failed:
                self.retry(attempt)
            default: break
            }
        }
        client.start(queue: queue)
        watchdog(attempt)
    }

    private func receive(_ client: NWConnection, attempt: Int) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak client] data, _, closed, error in
            guard let self, let client, self.generation == attempt else { return }
            if let data, !data.isEmpty {
                var samples: [IMUSample] = []
                self.framer.append(data) { samples.append($0) }
                if !samples.isEmpty {
                    self.lastPacket = .now()
                    for sample in samples { self.filter.feed(sample) }
                    // Rendering only needs the newest pose. Avoid locking for each packet.
                    if self.lastPacket.uptimeNanoseconds - self.lastPublish.uptimeNanoseconds > 4_000_000 {
                        self.publish(self.filter.calibrated ? .live : .calibrating(self.filter.progress))
                        self.lastPublish = self.lastPacket
                    }
                }
            }
            if closed || error != nil { self.retry(attempt) }
            else { self.receive(client, attempt: attempt) }
        }
    }

    private func watchdog(_ attempt: Int) {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == attempt else { return }
            if DispatchTime.now().uptimeNanoseconds - self.lastPacket.uptimeNanoseconds > 3_000_000_000 {
                self.retry(attempt)
            } else {
                self.watchdog(attempt)
            }
        }
    }

    private func retry(_ attempt: Int) {
        guard generation == attempt else { return }
        generation += 1
        let pending = generation
        connection?.cancel()
        connection = nil
        endpointIndex = (endpointIndex + 1) % endpoints.count
        publish(.unavailable)
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.generation == pending else { return }
            self.connect()
        }
    }
}
