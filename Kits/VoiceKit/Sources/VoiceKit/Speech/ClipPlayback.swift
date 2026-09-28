import AVFoundation
import Foundation

/// Plays one in-memory audio clip at a time for a voice that produces whole clips (Kokoro,
/// Grok): level metering, and delegate callbacks from a replaced player are ignored.
@MainActor
final class ClipPlayback: NSObject, AVAudioPlayerDelegate {
    typealias PlayerFactory = (Data) throws -> AVAudioPlayer

    var onSpeakingChanged: ((Bool) -> Void)?
    var onLevel: ((Double) -> Void)?
    private let makePlayer: PlayerFactory
    private var player: AVAudioPlayer?
    private var meter: Timer?
    private var isSpeaking = false
    /// Scheduled when a clip ends on its own, so the next main-actor turn can report
    /// `onSpeakingChanged(false)`; `play()` cancels it first, so a `play()` that follows in
    /// the same completion (prefetch's next sentence) coalesces the two clips into one
    /// uninterrupted `true` instead of a false-then-true flicker.
    private var pendingIdle: Task<Void, Never>?
    private var finished: ((Result<Void, Error>) -> Void)?
    private var playbackFailure: Error = CancellationError()

    init(makePlayer: @escaping PlayerFactory) {
        self.makePlayer = makePlayer
    }

    /// Starts `audio`, replacing any clip playing. `finished` runs once when the clip ends,
    /// unless `stop()` comes first. Throws `failure` when the clip cannot start.
    func play(_ audio: Data, failure: Error, finished: @escaping (Result<Void, Error>) -> Void) throws {
        pendingIdle?.cancel()
        pendingIdle = nil
        stopPlayer()
        let player: AVAudioPlayer
        do { player = try makePlayer(audio) } catch { throw failure }
        player.delegate = self
        player.isMeteringEnabled = true
        self.player = player
        guard player.prepareToPlay(), player.play() else {
            self.player = nil
            throw failure
        }
        playbackFailure = failure
        self.finished = finished
        let wasSpeaking = isSpeaking
        isSpeaking = true
        let identity = ObjectIdentifier(player)
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player, ObjectIdentifier(player) == identity else { return }
                player.updateMeters()
                self.onLevel?(min(1, max(0, pow(10, Double(player.averagePower(forChannel: 0)) / 20))))
            }
        }
        if !wasSpeaking { onSpeakingChanged?(true) }
    }

    /// Stops the clip without running its completion, reporting the end of speaking at once
    /// (unlike a clip ending on its own, an explicit stop is never coalesced).
    func stop() {
        pendingIdle?.cancel()
        pendingIdle = nil
        finished = nil
        stopPlayer()
        onLevel?(0)
        if isSpeaking {
            isSpeaking = false
            onSpeakingChanged?(false)
        }
    }

    private func stopPlayer() {
        meter?.invalidate()
        meter = nil
        player?.stop()
        player = nil
    }

    private func end(_ player: AVAudioPlayer, _ result: Result<Void, Error>) {
        guard let active = self.player, active === player else { return }
        let callback = finished
        finished = nil
        stopPlayer()
        callback?(result)
        // A `play()` inside `callback` (prefetch's next sentence) already resumed playback;
        // only report idle when nothing did.
        guard self.player == nil, isSpeaking, pendingIdle == nil else { return }
        pendingIdle = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.pendingIdle = nil
            self.isSpeaking = false
            self.onLevel?(0)
            self.onSpeakingChanged?(false)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let box = PlayerBox(player)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.end(box.player, flag ? .success(()) : .failure(self.playbackFailure))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let box = PlayerBox(player)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.end(box.player, .failure(self.playbackFailure))
        }
    }
}

/// Carries a player reference to the main actor for an identity check only.
private struct PlayerBox: @unchecked Sendable {
    let player: AVAudioPlayer
    init(_ player: AVAudioPlayer) { self.player = player }
}
