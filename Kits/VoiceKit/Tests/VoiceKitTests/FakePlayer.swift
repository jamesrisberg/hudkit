import AVFoundation

/// Never makes a sound: play and stop only flip a flag.
final class FakePlayer: AVAudioPlayer {
    var fakePlaying = false
    var acceptsPlayback = true
    override var isPlaying: Bool { fakePlaying }
    override func prepareToPlay() -> Bool { true }
    override func play() -> Bool {
        fakePlaying = acceptsPlayback
        return acceptsPlayback
    }
    override func stop() { fakePlaying = false }
}
