import Foundation

public struct SpeechSegmenterConfig: Equatable, Sendable {
    public var frameSamples: Int
    public var onRMS: Float
    public var offRMS: Float
    public var minSpeechSeconds: Double
    public var redemptionSeconds: Double
    public var prePadSeconds: Double
    public var postPadSeconds: Double
    public var maxSegmentSeconds: Double
    public var cutSearchSeconds: Double
    public var floorMultiplier: Float
    public var floorWindowSeconds: Double
    public var maxOnRMS: Float
    public var cutOverlapSeconds: Double
    public var maxNoisyCuts: Int

    public init(
        frameSamples: Int = 480, onRMS: Float = 0.003, offRMS: Float = 0.0021, minSpeechSeconds: Double = 0.1,
        redemptionSeconds: Double = 0.5, prePadSeconds: Double = 0.3, postPadSeconds: Double = 0.4,
        maxSegmentSeconds: Double = 20, cutSearchSeconds: Double = 2, floorMultiplier: Float = 3,
        floorWindowSeconds: Double = 10, maxOnRMS: Float = 0.05, cutOverlapSeconds: Double = 0.5, maxNoisyCuts: Int = 2
    ) {
        self.frameSamples = frameSamples
        self.onRMS = onRMS
        self.offRMS = offRMS
        self.minSpeechSeconds = minSpeechSeconds
        self.redemptionSeconds = redemptionSeconds
        self.prePadSeconds = prePadSeconds
        self.postPadSeconds = postPadSeconds
        self.maxSegmentSeconds = maxSegmentSeconds
        self.cutSearchSeconds = cutSearchSeconds
        self.floorMultiplier = floorMultiplier
        self.floorWindowSeconds = floorWindowSeconds
        self.maxOnRMS = maxOnRMS
        self.cutOverlapSeconds = cutOverlapSeconds
        self.maxNoisyCuts = maxNoisyCuts
    }

    public static let `default` = SpeechSegmenterConfig()
    public static let sensitive = SpeechSegmenterConfig(onRMS: 0.0012, offRMS: 0.00084)

    fileprivate var offRatio: Float { onRMS > 0 ? offRMS / onRMS : 0.7 }

    fileprivate func samples(_ seconds: Double) -> Int { Int((seconds * Double(SpeechAudio.sampleRate)).rounded()) }
}

public enum SegmenterEvent: Equatable, Sendable {
    case opened(startSample: Int)
    case segment(startSample: Int, samples: [Float])
    case dropped
}

public struct SpeechSegmenter: Sendable {
    private let config: SpeechSegmenterConfig
    private let frame: Int
    private let minSpeech: Int
    private let redemption: Int
    private let prePad: Int
    private let postPad: Int
    private let maxSegment: Int
    private let cutSearch: Int
    private let cutOverlap: Int
    private let floorCapacity: Int
    private var floorLevels: [Float] = []
    private var floorTick = 0
    private var on: Float
    private var off: Float
    private var noisyCuts = 0
    private var noiseRun = false
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var processed = 0
    private var total = 0
    private var lastEmittedEnd = 0
    private var isOpen = false
    private var isContinuation = false
    private var announced = false
    private var candidate = 0
    private var emitFrom = 0
    private var lastVoicedEnd = 0

    public init(config: SpeechSegmenterConfig = .default) {
        self.config = config
        frame = max(1, config.frameSamples)
        minSpeech = config.samples(config.minSpeechSeconds)
        redemption = config.samples(config.redemptionSeconds)
        prePad = config.samples(config.prePadSeconds)
        postPad = config.samples(config.postPadSeconds)
        maxSegment = config.samples(config.maxSegmentSeconds)
        cutSearch = config.samples(config.cutSearchSeconds)
        cutOverlap = config.samples(config.cutOverlapSeconds)
        floorCapacity = max(1, config.samples(config.floorWindowSeconds) / max(1, config.frameSamples))
        on = config.onRMS
        off = config.offRMS
    }

    public var totalSamples: Int { total }

    public var hasOpenSegment: Bool { isOpen }

    public mutating func append(_ samples: [Float]) -> [SegmenterEvent] {
        buffer.append(contentsOf: samples)
        total += samples.count
        var events: [SegmenterEvent] = []
        while processed + frame <= total {
            let start = processed
            let end = start + frame
            processed = end
            let level = rms(from: start, to: end)
            if !isOpen {
                guard level >= on else {
                    recordFloor(level)
                    continue
                }
                open(at: start)
            } else if level >= off {
                lastVoicedEnd = end
            } else if end - lastVoicedEnd >= redemption {
                close(into: &events)
                continue
            }
            announceIfNeeded(into: &events)
            if end - emitFrom >= maxSegment { forceCut(at: end, into: &events) }
        }
        trim()
        return events
    }

    public mutating func flush() -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        if isOpen { close(into: &events) }
        processed = total
        trim()
        return events
    }

    public mutating func skipGap(samples: Int) -> [SegmenterEvent] {
        let events = flush()
        total += samples
        processed = total
        lastEmittedEnd = total
        bufferStart = total
        buffer = []
        return events
    }

    private mutating func open(at start: Int) {
        isOpen = true
        isContinuation = false
        announced = false
        candidate = start
        emitFrom = max(start - prePad, lastEmittedEnd, bufferStart)
        lastVoicedEnd = start + frame
    }

    private var hasEnoughSpeech: Bool {
        lastVoicedEnd - candidate >= (isContinuation ? frame : minSpeech)
    }

    private mutating func announceIfNeeded(into events: inout [SegmenterEvent]) {
        guard isOpen, !announced, hasEnoughSpeech else { return }
        announced = true
        events.append(.opened(startSample: emitFrom))
    }

    private mutating func close(into events: inout [SegmenterEvent]) {
        defer {
            isOpen = false
            noisyCuts = 0
            noiseRun = false
        }
        guard !noiseRun, hasEnoughSpeech else {
            if announced { events.append(.dropped) }
            return
        }
        let end = min(lastVoicedEnd + postPad, total)
        emit(from: emitFrom, to: end, into: &events)
    }

    private mutating func emit(from start: Int, to end: Int, into events: inout [SegmenterEvent]) {
        let lower = max(start, bufferStart) - bufferStart
        let upper = min(end, bufferStart + buffer.count) - bufferStart
        lastEmittedEnd = max(lastEmittedEnd, end)
        guard lower < upper else {
            events.append(.dropped)
            return
        }
        events.append(.segment(startSample: bufferStart + lower, samples: Array(buffer[lower..<upper])))
    }

    private mutating func forceCut(at now: Int, into events: inout [SegmenterEvent]) {
        var best = now - frame
        var bestLevel = Float.greatestFiniteMagnitude
        var start = max(emitFrom, now - cutSearch)
        start += (now - start) % frame
        while start + frame <= now {
            let level = rms(from: start, to: start + frame)
            if level <= bestLevel {
                bestLevel = level
                best = start
            }
            start += frame
        }
        let quiet = bestLevel < off
        if !quiet, noisyCuts >= config.maxNoisyCuts {
            markNoise(until: now, into: &events)
            return
        }
        let cut = best + frame / 2
        emit(from: emitFrom, to: cut, into: &events)
        isContinuation = true
        announced = false
        candidate = cut
        emitFrom = quiet ? cut : max(cut - cutOverlap, bufferStart)
        noisyCuts = quiet ? 0 : noisyCuts + 1
        lastVoicedEnd = cut
        rescanVoiced(after: best + frame, until: now)
        announceIfNeeded(into: &events)
    }

    private mutating func markNoise(until now: Int, into events: inout [SegmenterEvent]) {
        noiseRun = true
        events.append(.dropped)
        floorLevels = []
        var index = now - frame
        while index >= emitFrom, floorLevels.count < floorCapacity {
            floorLevels.append(rms(from: index, to: index + frame))
            index -= frame
        }
        updateThresholds(force: true)
        isContinuation = true
        announced = false
        candidate = now
        emitFrom = now
        lastEmittedEnd = max(lastEmittedEnd, now)
        lastVoicedEnd = now
    }

    private mutating func rescanVoiced(after first: Int, until now: Int) {
        var next = first
        while next + frame <= now {
            if rms(from: next, to: next + frame) >= off { lastVoicedEnd = next + frame }
            next += frame
        }
    }

    private mutating func recordFloor(_ level: Float) {
        floorLevels.append(level)
        if floorLevels.count > floorCapacity { floorLevels.removeFirst(floorLevels.count - floorCapacity) }
        floorTick += 1
        if floorTick % 16 == 0 { updateThresholds(force: false) }
    }

    private mutating func updateThresholds(force: Bool) {
        guard force || floorLevels.count >= 33, !floorLevels.isEmpty else { return }
        let sorted = floorLevels.sorted()
        let percentile = sorted[sorted.count / 5]
        on = min(max(config.onRMS, config.floorMultiplier * percentile), max(config.onRMS, config.maxOnRMS))
        off = on * config.offRatio
    }

    private func rms(from start: Int, to end: Int) -> Float {
        SignalLevel.rms(buffer[(start - bufferStart)..<(end - bufferStart)])
    }

    private mutating func trim() {
        let keep = isOpen ? emitFrom : max(bufferStart, processed - prePad)
        let drop = min(max(0, keep - bufferStart), buffer.count)
        guard drop > 0 else { return }
        buffer.removeFirst(drop)
        bufferStart += drop
    }
}
