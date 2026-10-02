import Foundation
import Testing

@testable import VoiceKit

/// Time that moves only when a test advances it; timers run at their due time, in order.
@MainActor
final class ManualSpeechClock: SpeechClock {
    private(set) var now: TimeInterval = 0
    private var timers: [(id: Int, due: TimeInterval, action: @MainActor () -> Void)] = []
    private var nextID = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SpeechClockTimer {
        let id = nextID
        nextID += 1
        timers.append((id, now + delay, action))
        return SpeechClockTimer { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = timers.filter({ $0.due <= target + 1e-9 })
            .min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            timers.removeAll { $0.id == next.id }
            now = max(now, next.due)
            next.action()
        }
        now = target
    }
}

/// A prefetching voice on a `ManualSpeechClock`: synthesis takes `synthesisLatency` and runs one
/// clip at a time (as Kokoro does), a clip plays for `secondsPerWord` per word, and every span
/// of playback is recorded. Nothing is synthesized or played for real.
@MainActor
final class TimedVoice: PrefetchingSpeechVoice {
    let kind = SpeechVoiceKind.kokoro
    var onSpeakingChanged: ((Bool) -> Void)?
    var onLevel: ((Double) -> Void)?
    let clock: ManualSpeechClock
    var synthesisLatency: TimeInterval
    var secondsPerWord: TimeInterval
    private(set) var prepared: [String] = []
    private(set) var spans: [(text: String, start: TimeInterval, end: TimeInterval)] = []
    private(set) var stops = 0
    private var synthesisFree: TimeInterval = 0
    private var timers: [SpeechClockTimer] = []

    init(clock: ManualSpeechClock, synthesisLatency: TimeInterval, secondsPerWord: TimeInterval) {
        self.clock = clock
        self.synthesisLatency = synthesisLatency
        self.secondsPerWord = secondsPerWord
    }

    func speak(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Issue.record("a prefetching voice is only asked to prepare and play, never to speak \(text)")
    }

    func prepare(_ text: String, completion: @escaping (Result<SpeechClip, Error>) -> Void) {
        prepared.append(text)
        let done = max(clock.now, synthesisFree) + synthesisLatency
        synthesisFree = done
        timers.append(clock.schedule(after: done - clock.now) {
            completion(.success(SpeechClip(audio: Data(text.utf8))))
        })
    }

    func play(_ clip: SpeechClip, completion: @escaping (Result<Void, Error>) -> Void) {
        let text = String(decoding: clip.audio, as: UTF8.self)
        let duration = Double(text.split(separator: " ").count) * secondsPerWord
        spans.append((text, clock.now, clock.now + duration))
        timers.append(clock.schedule(after: duration) { completion(.success(())) })
    }

    func stop() {
        stops += 1
        timers.forEach { $0.cancel() }
        timers.removeAll()
        synthesisFree = 0
    }
}

/// `text` cut into pieces of `size` characters, as a stream delivers it.
func pieces(of text: String, size: Int) -> [String] {
    var result: [String] = []
    var rest = Substring(text)
    while !rest.isEmpty {
        result.append(String(rest.prefix(size)))
        rest = rest.dropFirst(size)
    }
    return result
}
