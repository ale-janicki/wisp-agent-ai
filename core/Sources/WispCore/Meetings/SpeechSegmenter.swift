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

    public init(
        frameSamples: Int = 480, onRMS: Float = 0.003, offRMS: Float = 0.0021, minSpeechSeconds: Double = 0.25,
        redemptionSeconds: Double = 0.5, prePadSeconds: Double = 0.3, postPadSeconds: Double = 0.4,
        maxSegmentSeconds: Double = 20, cutSearchSeconds: Double = 2
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
    }

    public static let `default` = SpeechSegmenterConfig()

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
                guard level >= config.onRMS else { continue }
                open(at: start)
            } else if level >= config.offRMS {
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
        defer { isOpen = false }
        guard hasEnoughSpeech else {
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
        let cut = best + frame / 2
        emit(from: emitFrom, to: cut, into: &events)
        isContinuation = true
        announced = false
        candidate = cut
        emitFrom = cut
        lastVoicedEnd = cut
        var next = best + frame
        while next + frame <= now {
            if rms(from: next, to: next + frame) >= config.offRMS { lastVoicedEnd = next + frame }
            next += frame
        }
        announceIfNeeded(into: &events)
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
