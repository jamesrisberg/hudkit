import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

@MainActor
private func grok(
    key: String? = "key", requester: @escaping GrokVoice.Requester,
    makePlayer: @escaping (Data) throws -> AVAudioPlayer = { try FakePlayer(data: $0) }
) -> GrokVoice {
    GrokVoice(apiKey: { key }, requester: requester, makePlayer: makePlayer)
}

@MainActor
struct GrokVoiceTests {
    @Test func requestUsesOnlyTheTextAndSelectedVoice() throws {
        let request = try GrokVoice.request(text: "The note is ready.", apiKey: " key ", voice: "ara")
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/tts")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(Set(body.keys) == Set(["text", "voice_id", "language", "output_format"]))
        #expect(body["text"] as? String == "The note is ready.")
        #expect(body["voice_id"] as? String == "ara")
        #expect(body["language"] as? String == "en")
        let format = try #require(body["output_format"] as? [String: Any])
        #expect(format["codec"] as? String == "mp3")
        #expect(format["sample_rate"] as? Int == 24000)
        #expect(format["bit_rate"] as? Int == 128000)
    }

    @Test func invalidInputCannotReachTheNetwork() {
        for (text, key, voice) in [
            ("", "key", "ara"), ("hi", "", "ara"), ("hi", "key\ninjection", "ara"), ("hi", "key", "invalid"),
            (String(repeating: "a", count: 15_001), "key", "ara"),
        ] {
            #expect(throws: GrokVoice.Failure.self) {
                try GrokVoice.request(text: text, apiKey: key, voice: voice)
            }
        }
    }

    @Test func aMissingKeyFailsWithoutARequest() async {
        var calls = 0
        let voice = grok(key: nil, requester: { _ in calls += 1; return Data([1]) })
        let result = await withCheckedContinuation { continuation in
            voice.speak("Hello") { continuation.resume(returning: $0) }
        }
        #expect(calls == 0)
        if case .failure(let error) = result {
            #expect(error as? GrokVoice.Failure == .missingKey)
        } else {
            Issue.record("expected a failure")
        }
    }

    @Test func aStoppedRequestCannotStartPlaybackOrComplete() async throws {
        var continuation: CheckedContinuation<Data, Error>?
        let voice = grok(requester: { _ in try await withCheckedThrowingContinuation { continuation = $0 } })
        var completions = 0
        var speakingEvents = 0
        voice.onSpeakingChanged = { if $0 { speakingEvents += 1 } }
        voice.speak("Hello") { _ in completions += 1 }
        while continuation == nil { await Task.yield() }
        voice.stop()
        continuation?.resume(returning: Data([0]))
        for _ in 0..<10 { await Task.yield() }
        #expect(completions == 0)
        #expect(speakingEvents == 0)
    }

    @Test func aReplacedRequestCannotFinishTheNewOne() async throws {
        var continuations: [CheckedContinuation<Data, Error>] = []
        let voice = grok(requester: { _ in try await withCheckedThrowingContinuation { continuations.append($0) } })
        var oldCompletions = 0
        var newCompletions = 0
        voice.speak("Old") { _ in oldCompletions += 1 }
        while continuations.count < 1 { await Task.yield() }
        voice.speak("New") { _ in newCompletions += 1 }
        while continuations.count < 2 { await Task.yield() }
        continuations[0].resume(throwing: URLError(.timedOut))
        for _ in 0..<10 { await Task.yield() }
        #expect(oldCompletions == 0)
        #expect(newCompletions == 0)
        continuations[1].resume(throwing: GrokVoice.Failure.service(429))
        while newCompletions == 0 { await Task.yield() }
        #expect(newCompletions == 1)
    }

    @Test func networkErrorsAreSanitizedWithoutRetry() async {
        var calls = 0
        let voice = grok(requester: { _ in
            calls += 1
            throw NSError(domain: "secret reply text", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret reply text"])
        })
        let result = await withCheckedContinuation { continuation in
            voice.speak("Hello") { continuation.resume(returning: $0) }
        }
        #expect(calls == 1)
        if case .failure(let error) = result {
            #expect(!error.localizedDescription.contains("secret"))
        } else {
            Issue.record("expected a failure")
        }
    }

    @Test func emptyAndOversizedResponsesFailBeforePlayback() async {
        for data in [Data(), Data(repeating: 0, count: GrokVoice.maximumAudioBytes + 1)] {
            let voice = grok(requester: { _ in data })
            var speaking = false
            voice.onSpeakingChanged = { speaking = speaking || $0 }
            let result = await withCheckedContinuation { continuation in
                voice.speak("Hello") { continuation.resume(returning: $0) }
            }
            #expect((try? result.get()) == nil)
            #expect(!speaking)
        }
    }

    @Test func successfulPlaybackAndStopRejectLateDelegateCallbacks() async throws {
        let first = try FakePlayer(data: silentWave())
        let second = try FakePlayer(data: silentWave())
        var players = [first, second]
        let voice = grok(requester: { _ in Data([1]) }, makePlayer: { _ in players.removeFirst() })
        var events: [Bool] = []
        var oldCompletions = 0
        var newCompletions = 0
        voice.onSpeakingChanged = { events.append($0) }
        voice.speak("First") { _ in oldCompletions += 1 }
        while events.isEmpty { await Task.yield() }
        #expect(first.fakePlaying)
        voice.stop()
        #expect(!first.fakePlaying)
        #expect(events == [true, false])
        voice.speak("Second") { result in
            if case .success = result { newCompletions += 1 }
        }
        while events.count < 3 { await Task.yield() }
        voice.playback.audioPlayerDidFinishPlaying(first, successfully: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(oldCompletions == 0)
        #expect(newCompletions == 0)
        #expect(second.fakePlaying)
        voice.playback.audioPlayerDidFinishPlaying(second, successfully: true)
        while newCompletions == 0 { await Task.yield() }
        #expect(events == [true, false, true, false])
        #expect(newCompletions == 1)
    }

    @Test func transportRejectsHTTPErrorsEmptyAndOversizedBodies() async throws {
        for scenario in ["ok", "error", "empty", "length", "stream"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GrokFixtureProtocol.self]
            var request = try GrokVoice.request(text: "Hello", apiKey: "key", voice: "eve")
            request.setValue(scenario, forHTTPHeaderField: "X-Test-Scenario")
            do {
                let data = try await GrokVoice.download(request, configuration: configuration)
                #expect(scenario == "ok")
                #expect(data == Data([1, 2, 3]))
            } catch let error as GrokVoice.Failure {
                switch (scenario, error) {
                case ("error", .service(429)), ("empty", .invalidResponse),
                     ("length", .oversizedAudio), ("stream", .oversizedAudio): break
                default: Issue.record("Unexpected error for \(scenario): \(error)")
                }
                #expect(!error.localizedDescription.contains("private reply"))
            }
        }
    }
}

/// Answers every request in process; nothing reaches the network.
private final class GrokFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario") ?? "ok"
        let status = scenario == "error" ? 429 : 200
        let headers = scenario == "length" ? ["Content-Length": "9000000"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data: Data
        switch scenario {
        case "empty": data = Data()
        case "stream": data = Data(repeating: 0, count: 8 * 1024 * 1024 + 1)
        case "error": data = Data("private reply and server error body".utf8)
        default: data = Data([1, 2, 3])
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
