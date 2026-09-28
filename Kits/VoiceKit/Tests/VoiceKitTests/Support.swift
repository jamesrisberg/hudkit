import CryptoKit
import Foundation
import Testing

@MainActor
func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition not reached")
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A fresh folder under the temporary directory; the caller removes `root`.
func temporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicekit-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// A folder named by an environment variable, when it exists: the opt-in real-model tests.
func environmentDirectory(_ name: String) -> URL? {
    guard let path = ProcessInfo.processInfo.environment[name], !path.isEmpty else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
}

/// A playable in-memory WAV of `count` silent samples; `AVAudioPlayer(data:)` needs real audio.
func silentWave(_ count: Int = 100) -> Data {
    var wave = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
    }
    append(UInt32(36 + count * 2))
    wave.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(24000)); append(UInt32(48000)); append(UInt16(2)); append(UInt16(16))
    wave.append(Data("data".utf8)); append(UInt32(count * 2))
    wave.append(Data(repeating: 0, count: count * 2))
    return wave
}
