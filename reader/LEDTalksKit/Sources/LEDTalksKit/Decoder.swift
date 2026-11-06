import Foundation

/// One camera frame's view of the LED: the mean colour of a region of interest around it, and
/// when it was seen (seconds, any epoch, increasing).
public struct Sample: Equatable, Sendable {
    public var time: Double
    public var colour: RGB

    public init(time: Double, colour: RGB) {
        self.time = time
        self.colour = colour
    }
}

public struct DecodedMessage: Equatable, Sendable {
    public let mode: LEDTalks.Mode
    public let payload: [UInt8]
    /// The device's symbol period, as measured.
    public let period: Double
    /// When the frame's preamble started and its body ended.
    public let start: Double
    public let end: Double

    public var content: Content { Content.parse(payload) }
}

public enum DecoderEvent: Equatable, Sendable {
    /// A preamble, sync, and a valid header: a frame is being read.
    case locked(mode: LEDTalks.Mode, period: Double)
    /// Body symbols read so far, of the total (known once the length has been read).
    case progress(received: Int, total: Int?)
    case decoded(DecodedMessage)
    case failed(Failure)
}

public enum Failure: Equatable, Sendable {
    case unknownHeader(UInt8)
    /// The training sequence's symbols were too alike to tell apart.
    case indistinctSymbols
    case crc
}

/// Decodes LED Talks frames from a stream of samples (docs/protocol.md §6).
///
/// 1. Find the preamble and sync from brightness transitions, and fit the symbol period and
///    phase to them by least squares.
/// 2. Read the header as binary, then learn each symbol's colour from the training sequence.
/// 3. Classify body symbols by nearest learned colour, nudging the phase towards every
///    transition, so a device's clock skew can't accumulate.
/// 4. De-whiten, check the CRC, and go back to looking for a preamble.
public struct Decoder: Sendable {
    public struct Config: Sendable {
        /// The smallest brightness swing (luma, 0...1) treated as a signal.
        public var minContrast = 0.04
        /// How far back the brightness threshold looks, in seconds.
        public var window = 2.5
        /// Phase and frequency gains of the timing loop.
        public var phaseGain = 0.4
        public var frequencyGain = 0.05

        public init() {}
    }

    public let config: Config
    /// The current brightness swing (luma), for showing signal strength.
    public private(set) var contrast = 0.0

    private var times: [Double] = []
    private var colours: [RGB] = []
    private var lumas: [Double] = []
    private var scanIndex = 0

    // Searching
    private var high: Bool?
    private var transitions: [(time: Double, rising: Bool)] = []

    // Reading
    private var frame: Frame?

    private struct Frame {
        var start: Double
        var period: Double
        var threshold: Double
        var slot = 20            // the next slot to read; 20 is the header's first
        var slotStart: Double
        var previous: RGB?       // the previous slot's mean
        var header: UInt8 = 0
        var mode: LEDTalks.Mode?
        var centroids: [RGB] = []
        var body: [UInt8] = []
        var length: Int?
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    public var isReading: Bool { frame != nil }

    public mutating func reset() {
        self = Decoder(config: config)
    }

    public mutating func add(_ sample: Sample) -> [DecoderEvent] {
        if let last = times.last, sample.time <= last { return [] }
        times.append(sample.time)
        colours.append(sample.colour)
        lumas.append(sample.colour.luma)

        var events: [DecoderEvent] = []
        var progressed = true
        while progressed {
            progressed = false
            if frame == nil {
                progressed = search()
            }
            if frame != nil {
                let (more, ev) = read()
                events += ev
                progressed = progressed || more
            }
        }
        trim()
        return events
    }

    // MARK: Searching

    /// Scans new samples for transitions; true once a preamble and sync have been found.
    private mutating func search() -> Bool {
        while scanIndex < times.count {
            let i = scanIndex
            scanIndex += 1
            let (lo, hi) = range(endingAt: i)
            contrast = hi - lo
            guard contrast >= config.minContrast else {
                high = nil
                continue
            }
            let mid = (lo + hi) / 2, band = contrast * 0.1
            let l = lumas[i]
            var now = high
            if l > mid + band { now = true } else if l < mid - band { now = false }
            guard let state = now else { continue }
            defer { high = state }
            guard let before = high, before != state else { continue }

            transitions.append((crossing(at: i, level: mid), state))
            if transitions.count > 48 { transitions.removeFirst(transitions.count - 48) }
            if lock(threshold: mid) { return true }
        }
        return false
    }

    /// The luma range over the window ending at sample i.
    private func range(endingAt i: Int) -> (Double, Double) {
        let from = times[i] - config.window
        var lo = lumas[i], hi = lumas[i]
        var j = i
        while j > 0, times[j - 1] >= from {
            j -= 1
            lo = min(lo, lumas[j])
            hi = max(hi, lumas[j])
        }
        return (lo, hi)
    }

    /// When the luma crossed `level`, interpolated, given that sample i is past it.
    private func crossing(at i: Int, level: Double) -> Double {
        let above = lumas[i] > level
        var j = i - 1
        while j > 0, (lumas[j] > level) == above { j -= 1 }
        guard j >= 0, j + 1 <= i else { return times[i] }
        let (l1, l2) = (lumas[j], lumas[j + 1])
        let f = l2 == l1 ? 0.5 : min(max((level - l1) / (l2 - l1), 0), 1)
        return times[j] + f * (times[j + 1] - times[j])
    }

    /// Looks for the preamble and sync in the latest transitions (§3.1, §3.2). The sync's
    /// transitions fall at slots 12 (rise), 15 (fall), 17 (rise), and 18 (fall), after the
    /// preamble's at every slot up to 11.
    private mutating func lock(threshold: Double) -> Bool {
        let t = transitions
        let m = t.count
        guard m >= 12, t[m - 1].rising == false else { return false }
        // Unit intervals before the sync, newest first.
        var units: [Double] = []
        var k = m - 4
        while k >= 1, units.count < 12 {
            units.append(t[k].time - t[k - 1].time)
            k -= 1
        }
        guard units.count >= 8 else { return false }
        let p0 = units.sorted()[units.count / 2]
        guard p0 > 0.004, p0 < 0.5 else { return false }
        // The run of unit intervals, from the sync backwards.
        var run = 0
        for u in units {
            guard abs(u / p0 - 1) < 0.25 else { break }
            run += 1
        }
        guard run >= 8 else { return false }
        let d1 = (t[m - 3].time - t[m - 4].time) / p0
        let d2 = (t[m - 2].time - t[m - 3].time) / p0
        let d3 = (t[m - 1].time - t[m - 2].time) / p0
        guard abs(d1 - 3) < 0.4, abs(d2 - 2) < 0.35, abs(d3 - 1) < 0.25 else { return false }

        // Least squares: transition time = start + slot × period.
        var points: [(n: Double, t: Double)] = [(18, t[m - 1].time), (17, t[m - 2].time),
                                                (15, t[m - 3].time), (12, t[m - 4].time)]
        for r in 0..<run { points.append((Double(11 - r), t[m - 5 - r].time)) }
        let count = Double(points.count)
        let mn = points.map(\.n).reduce(0, +) / count
        let mt = points.map(\.t).reduce(0, +) / count
        let sxy = points.map { ($0.n - mn) * ($0.t - mt) }.reduce(0, +)
        let sxx = points.map { ($0.n - mn) * ($0.n - mn) }.reduce(0, +)
        let period = sxy / sxx
        let start = mt - period * mn
        guard period > 0.004, period < 0.5 else { return false }

        frame = Frame(start: start, period: period, threshold: threshold,
                      slotStart: start + 20 * period)
        transitions.removeAll()
        return true
    }

    // MARK: Reading

    /// Reads every slot whose samples have all arrived.
    private mutating func read() -> (Bool, [DecoderEvent]) {
        var events: [DecoderEvent] = []
        var progressed = false
        while var f = frame, let latest = times.last, latest >= f.slotStart + f.period {
            progressed = true
            let mean = slotMean(start: f.slotStart, period: f.period)
            if let prev = f.previous { track(&f, from: prev, to: mean) }
            f.previous = mean
            let slot = f.slot
            f.slot += 1
            f.slotStart += f.period

            switch slot {
            case 20..<28:
                f.header = f.header << 1 | (mean.luma > f.threshold ? 1 : 0)
                frame = f
                if slot == 27 {
                    guard f.header >> 4 == LEDTalks.version,
                          let mode = LEDTalks.Mode(rawValue: f.header & 0x0F) else {
                        events.append(.failed(.unknownHeader(f.header)))
                        endFrame(at: f.slotStart)
                        return (true, events)
                    }
                    frame?.mode = mode
                    events.append(.locked(mode: mode, period: f.period))
                }
            default:
                guard let mode = f.mode else { return (progressed, events) }
                if slot < 28 + mode.symbols {
                    f.centroids.append(mean)
                    frame = f
                    if f.centroids.count == mode.symbols, !distinct(f.centroids) {
                        events.append(.failed(.indistinctSymbols))
                        endFrame(at: f.slotStart)
                        return (true, events)
                    }
                    continue
                }
                f.body.append(nearest(mean, in: f.centroids))
                if f.length == nil, f.body.count * mode.bits >= 8 {
                    let first = BitPacker.bytes(from: f.body, bits: mode.bits, count: 1)[0]
                    f.length = Int(first ^ LEDTalks.whitening(1)[0])
                }
                let total = f.length.map { LEDTalks.bodySymbols(mode, length: $0) }
                frame = f
                events.append(.progress(received: f.body.count, total: total))
                if let total, let length = f.length, f.body.count >= total {
                    events.append(finish(f, mode: mode, length: length))
                    endFrame(at: f.slotStart)
                    return (true, events)
                }
            }
        }
        return (progressed, events)
    }

    private func finish(_ f: Frame, mode: LEDTalks.Mode, length: Int) -> DecoderEvent {
        let bytes = LEDTalks.whiten(BitPacker.bytes(from: f.body, bits: mode.bits, count: length + 3))
        let payload = Array(bytes[1..<1 + length])
        let crc = UInt16(bytes[length + 1]) << 8 | UInt16(bytes[length + 2])
        guard LEDTalks.crc16([f.header, UInt8(length)] + payload) == crc else { return .failed(.crc) }
        return .decoded(DecodedMessage(mode: mode, payload: payload, period: f.period,
                                       start: f.start, end: f.slotStart))
    }

    private mutating func endFrame(at time: Double) {
        frame = nil
        high = nil
        transitions.removeAll()
        scanIndex = max(scanIndex, firstIndex(atOrAfter: time))
    }

    /// The mean colour of the slot's middle 60%, or the nearest sample if none fall in it.
    private func slotMean(start: Double, period: Double) -> RGB {
        let a = firstIndex(atOrAfter: start + 0.2 * period)
        let b = firstIndex(atOrAfter: start + 0.8 * period)
        if b > a {
            let sum = colours[a..<b].reduce(RGB.black, +)
            return sum * (1 / Double(b - a))
        }
        let mid = start + period / 2
        let i = min(a, times.count - 1)
        if i > 0, abs(times[i - 1] - mid) < abs(times[i] - mid) { return colours[i - 1] }
        return colours[i]
    }

    /// Measures where the colour changed between two slots, and nudges the timing towards it.
    private func track(_ f: inout Frame, from prev: RGB, to cur: RGB) {
        let d = cur - prev
        let d2 = d.dot(d)
        guard d2.squareRoot() >= config.minContrast else { return }
        let edge = f.slotStart
        let a = firstIndex(atOrAfter: edge - f.period / 2)
        let b = firstIndex(atOrAfter: edge + f.period / 2)
        guard b - a >= 2 else { return }
        var best: Double?
        for i in a..<(b - 1) {
            let f1 = (colours[i] - prev).dot(d) / d2
            let f2 = (colours[i + 1] - prev).dot(d) / d2
            guard (f1 < 0.5) != (f2 < 0.5) else { continue }
            let x = f2 == f1 ? 0.5 : (0.5 - f1) / (f2 - f1)
            let t = times[i] + x * (times[i + 1] - times[i])
            if best == nil || abs(t - edge) < abs(best! - edge) { best = t }
        }
        guard let measured = best else { return }
        let e = min(max(measured - edge, -0.3 * f.period), 0.3 * f.period)
        f.slotStart += config.phaseGain * e
        f.period += config.frequencyGain * e
    }

    private func distinct(_ centroids: [RGB]) -> Bool {
        for i in centroids.indices {
            for j in centroids.indices where j > i {
                if centroids[i].distance(to: centroids[j]) < config.minContrast / 2 { return false }
            }
        }
        return true
    }

    private func nearest(_ c: RGB, in centroids: [RGB]) -> UInt8 {
        var best = 0, bestD = Double.infinity
        for (i, k) in centroids.enumerated() {
            let d = c.distance(to: k)
            if d < bestD { best = i; bestD = d }
        }
        return UInt8(best)
    }

    private func firstIndex(atOrAfter t: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Drops samples nothing will look at again.
    private mutating func trim() {
        guard times.count > 4096 else { return }
        var keepFrom = times.last! - config.window - 1
        if let f = frame { keepFrom = min(keepFrom, f.slotStart - 2 * f.period) }
        let drop = min(firstIndex(atOrAfter: keepFrom), scanIndex)
        guard drop > 1024 else { return }
        times.removeFirst(drop)
        colours.removeFirst(drop)
        lumas.removeFirst(drop)
        scanIndex -= drop
    }
}
