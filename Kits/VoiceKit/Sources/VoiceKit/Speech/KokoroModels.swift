import Foundation

/// The pinned Kokoro-82M files (MLX weights, config and the English voices), downloaded on
/// demand into a folder the host chooses.
public enum KokoroModels {
    public struct Voice: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
    }

    public static let revision = "98623f832fc74ac3e2eaf2074171af7ac364b183"
    public static let defaultVoice = "af_heart"

    /// Every model is downloaded rather than bundled; the MLX conversion's own terms have not
    /// been checked for bundling, so the manifest does not claim it.
    public static let manifest = ModelManifest(
        id: "Kokoro-82M",
        displayName: "Kokoro model",
        baseURL: URL(string: "https://huggingface.co/mweinbach/Kokoro-82M-Swift/resolve/\(revision)/MLX_GPU/")!,
        artifacts: artifacts,
        licence: "Kokoro-82M by hexgrad, Apache-2.0; MLX conversion from mweinbach/Kokoro-82M-Swift.",
        redistributable: false)

    static let artifacts: [ModelArtifact] = [
        .init(path: "config.json", size: 2_351, sha256: "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"),
        .init(path: "kokoro-v1_0.safetensors", size: 324_752_712, sha256: "e910a0d08651e767910c0ba46cee19f40fc28ce1a774c6f2c4c626fe156c87a6"),
        .init(path: "voices/af_alloy.npy", size: 522_368, sha256: "445ae1abcc61bc598e8d5e77cece67d05f905b10c194972acd22a4fbf0e43468"),
        .init(path: "voices/af_aoede.npy", size: 522_368, sha256: "3b7fbd4d3370e6c230bbc255465e5160c58a3765db3d0ceeb79f4c1a657c78ed"),
        .init(path: "voices/af_bella.npy", size: 522_368, sha256: "adf92f9d074ce202966ac1aecd25c5f0eb9e8395d8d3ccb519f77ab321c98952"),
        .init(path: "voices/af_heart.npy", size: 522_368, sha256: "0212418aafafb1e9878f3300787937aa401ac937cff8c0310ffa32963d96c77b"),
        .init(path: "voices/af_jessica.npy", size: 522_368, sha256: "3d32685d7707c120944446f67642d28af08703bfed674ff179e11f04f7e0dae6"),
        .init(path: "voices/af_kore.npy", size: 522_368, sha256: "d8b0604fa03e79d6121d93c5e02e05021e20386b8656f95b5d205d6fa1af5be8"),
        .init(path: "voices/af_nicole.npy", size: 522_368, sha256: "d0c96b799c867a9c03a210f5385353097b0f6ef12f7ab3d777d3227853b129c4"),
        .init(path: "voices/af_nova.npy", size: 522_368, sha256: "a7ec888221fe372f28324d4926d81cff169682bd458c927a42ea725be234dd21"),
        .init(path: "voices/af_river.npy", size: 522_368, sha256: "06479b9964156be429103999a3b6f413eebfd469d167ab087456a1935641fc4c"),
        .init(path: "voices/af_sarah.npy", size: 522_368, sha256: "04c3eff66b437ea6a91f9d8ab170660c67057834553b8a2177bc6ec025ce6025"),
        .init(path: "voices/af_sky.npy", size: 522_368, sha256: "f0ad8d667e3083ace595b46430a99b2204b33d52175558eb057519ae416f2d18"),
        .init(path: "voices/am_adam.npy", size: 522_368, sha256: "836a3c058f9397161580bd8c1925fba35c826e8da718da4b82b9fcdeec8ae5a1"),
        .init(path: "voices/am_echo.npy", size: 522_368, sha256: "29ef1f5a8b486e238d110df57bcc08b43ddbc9a8aa803e30ecb89d03861e9713"),
        .init(path: "voices/am_eric.npy", size: 522_368, sha256: "6498bf201f0fec7c70ed43faece15040618f2c675cb9a1c780cbcc0acfa4ce07"),
        .init(path: "voices/am_fenrir.npy", size: 522_368, sha256: "6940b7633234b3bba450d2adc08b2431ce6f7b4b51ad60f588ba197907a005b9"),
        .init(path: "voices/am_liam.npy", size: 522_368, sha256: "29e7499291d45e522ee52cbbb1fa8924f846d7433b2abe2e256c85d920bd8e04"),
        .init(path: "voices/am_michael.npy", size: 522_368, sha256: "bbb62b3eae08e060f2fcf972d5434144add02bc5f2cc592403f90cab40ae1f4f"),
        .init(path: "voices/am_onyx.npy", size: 522_368, sha256: "3f58ca8d3ef6b4b856bf0016b9cef76db459421d91aa0ef7ee436f92569e165e"),
        .init(path: "voices/am_puck.npy", size: 522_368, sha256: "836a9be38c297f8cae74c32dcfe142c88b5decbce448949db75494cb002a1628"),
        .init(path: "voices/am_santa.npy", size: 522_368, sha256: "3368b44c6760799bc767cc8653fbde824fa0dfa829c43f4c0ec8b8bad0569de0"),
        .init(path: "voices/bf_alice.npy", size: 522_368, sha256: "be8e6bde8f2ccce00b8da8615a63ab53480abf4cd3ffc023f33f3a05d2c23755"),
        .init(path: "voices/bf_emma.npy", size: 522_368, sha256: "806fe5ac92bfd3b393d063e935b0af4b5f45e08c638765725bb60f8097f0f910"),
        .init(path: "voices/bf_isabella.npy", size: 522_368, sha256: "c8fb97c6bb59c159e6bdb3f10df100b0b14cf34205ef478882f6afa554d51caf"),
        .init(path: "voices/bf_lily.npy", size: 522_368, sha256: "6a7096cc0c97719e98268e21b09590a114f94730e756d2426b068533faa696e2"),
        .init(path: "voices/bm_daniel.npy", size: 522_368, sha256: "e0a4dabcc539c02c68198605fb71fa97a73c574c7813e61cf64e47ec1ba5dd15"),
        .init(path: "voices/bm_fable.npy", size: 522_368, sha256: "343e09d7c16f71ea05ab2595c68b9027f49246383b311c455a35f56223e61c7a"),
        .init(path: "voices/bm_george.npy", size: 522_368, sha256: "7692b2123ac5c99ffdcb5dfe8ea6e8f3bad7f2ae040ae3bddfc443241b5c5c21"),
        .init(path: "voices/bm_lewis.npy", size: 522_368, sha256: "1d8385549ec987e3e353f639393f6fc18d288c1cd644d49b6bc5990ecfeef6f0"),
    ]

    /// Voice ids are `<a|b><f|m>_<name>`: American or British, female or male.
    public static let voices: [Voice] = artifacts.filter { $0.path.hasPrefix("voices/") }.map {
        let id = URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent
        let name = String(id.dropFirst(3)).capitalized
        return Voice(id: id, displayName: "\(name) · \(id.hasPrefix("a") ? "American" : "British")")
    }

    public static let voiceIDs: Set<String> = Set(voices.map(\.id))

    /// The install folder under a host's models root (`<root>/Kokoro-82M/<revision>`).
    public static func directory(in root: URL) -> URL {
        root.appendingPathComponent("Kokoro-82M/\(revision)", isDirectory: true)
    }
}
