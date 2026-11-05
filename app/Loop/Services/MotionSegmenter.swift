import Foundation

struct SegmenterSample: Sendable {
    var time: Date
    var cumMeters: Double
    var speed: Double
    var activity: MotionActivity?
    var confidence: MotionConfidence?
    var cadence: Double?
}

/// Splits a run into running and walking stretches. Pure.
enum MotionSegmenter {
    static let minSeconds: Double = 20
    static let minMeters: Double = 60

    static func vote(_ s: SegmenterSample, previous: MoveKind?) -> MoveKind? {
        if let a = s.activity, let c = s.confidence, c >= .medium {
            if a == .running { return .run }
            if a == .walking { return .walk }
        }
        if let cad = s.cadence, cad > 0 {
            if cad >= 140 { return .run }
            if cad <= 125 { return .walk }
        }
        if s.speed >= 0 {
            if s.speed >= 2.2 { return .run }
            if s.speed <= 1.9 { return .walk }
        }
        return previous
    }

    static func segments(_ samples: [SegmenterSample]) -> [MoveSegment] {
        guard let first = samples.first, let last = samples.last, last.cumMeters > first.cumMeters || samples.count > 1 else { return [] }
        // 1. raw per-sample votes
        var kinds: [MoveKind] = []
        var prev: MoveKind?
        for s in samples {
            let k = vote(s, previous: prev) ?? prev
            kinds.append(k ?? .run)
            prev = k ?? prev
        }
        // Fill any leading undecided with the first decided kind.
        // 2. raw segments
        var segs: [MoveSegment] = []
        var startIdx = 0
        for i in 1...samples.count {
            if i == samples.count || kinds[i] != kinds[startIdx] {
                let endSample = i == samples.count ? samples[i - 1] : samples[i]
                segs.append(MoveSegment(kind: kinds[startIdx], startMeters: samples[startIdx].cumMeters,
                                        endMeters: endSample.cumMeters, startTime: samples[startIdx].time,
                                        endTime: endSample.time))
                startIdx = i
            }
        }
        _ = first
        return smooth(segs)
    }

    static func smooth(_ input: [MoveSegment]) -> [MoveSegment] {
        var segs = merged(input)
        while segs.count > 1 {
            // shortest segment that is too short
            var worst: Int?
            var worstScore = Double.infinity
            for (i, s) in segs.enumerated() {
                let dur = s.endTime.timeIntervalSince(s.startTime)
                if dur < minSeconds || s.meters < minMeters {
                    let score = s.meters
                    if score < worstScore { worstScore = score; worst = i }
                }
            }
            guard let w = worst else { break }
            // absorb into the neighbours' kind
            let neighbour: MoveKind
            if w == 0 { neighbour = segs[1].kind }
            else if w == segs.count - 1 { neighbour = segs[w - 1].kind }
            else { neighbour = segs[w - 1].meters >= segs[w + 1].meters ? segs[w - 1].kind : segs[w + 1].kind }
            segs[w].kind = neighbour
            segs = merged(segs)
        }
        return segs
    }

    static func merged(_ segs: [MoveSegment]) -> [MoveSegment] {
        var out: [MoveSegment] = []
        for s in segs {
            if var l = out.last, l.kind == s.kind {
                l.endMeters = s.endMeters; l.endTime = s.endTime
                out[out.count - 1] = l
            } else { out.append(s) }
        }
        return out
    }
}
