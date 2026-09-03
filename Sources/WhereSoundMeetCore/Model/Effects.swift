import Foundation

/// Per-source effect chain. Order is fixed: high-pass → low-pass → gate → EQ → compressor → echo → reverb → limiter.
public struct EffectSettings: Codable, Hashable {
    public var highPass = HighPassSettings()
    public var lowPass = LowPassSettings()
    public var gate = GateSettings()
    public var eq = EQSettings()
    public var compressor = CompressorSettings()
    public var echo = EchoSettings()
    public var reverb = ReverbSettings()
    public var limiter = LimiterSettings()

    public init() {}

    public var anyEnabled: Bool {
        highPass.enabled || lowPass.enabled || gate.enabled || eq.enabled || compressor.enabled
            || echo.enabled || reverb.enabled || limiter.enabled
    }

    public var enabledCount: Int {
        [highPass.enabled, lowPass.enabled, gate.enabled, eq.enabled, compressor.enabled,
         echo.enabled, reverb.enabled, limiter.enabled].filter { $0 }.count
    }
}

public struct HighPassSettings: Codable, Hashable {
    public var enabled = false
    /// Hz, 10…2000
    public var cutoff: Float = 80
    public init() {}
}

public struct LowPassSettings: Codable, Hashable {
    public var enabled = false
    /// Hz, 1000…20000
    public var cutoff: Float = 12_000
    public init() {}
}

public struct GateSettings: Codable, Hashable {
    public var enabled = false
    /// dB, -80…0. Signal below this is attenuated.
    public var threshold: Float = -45
    /// Expansion ratio 1…50; higher closes the gate harder.
    public var ratio: Float = 10
    public init() {}
}

public struct EQSettings: Codable, Hashable {
    public static let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public var enabled = false
    /// dB per band, -12…+12
    public var gains: [Float] = Array(repeating: 0, count: 10)
    public init() {}

    public enum Preset: String, CaseIterable, Codable {
        case flat = "Flat", bassBoost = "Bass Boost", trebleBoost = "Treble Boost", vocal = "Vocal"
        case podcast = "Podcast", loudness = "Loudness", telephone = "Telephone"

        public var gains: [Float] {
            switch self {
            case .flat: return Array(repeating: 0, count: 10)
            case .bassBoost: return [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
            case .trebleBoost: return [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
            case .vocal: return [-3, -2, -1, 1, 3, 4, 4, 2, 0, -1]
            case .podcast: return [-6, -4, 0, 2, 3, 3, 2, 1, -1, -3]
            case .loudness: return [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]
            case .telephone: return [-12, -12, -8, 0, 4, 4, 0, -8, -12, -12]
            }
        }
    }
}

public struct CompressorSettings: Codable, Hashable {
    public var enabled = false
    /// dB, -40…20
    public var threshold: Float = -20
    /// Ratio expressed as head room in dB, 0.1…40 (Apple DynamicsProcessor). Smaller = harder.
    public var headRoom: Float = 5
    /// seconds
    public var attack: Float = 0.005
    public var release: Float = 0.1
    /// dB make-up gain, -40…40
    public var makeupGain: Float = 0
    public init() {}
}

public struct EchoSettings: Codable, Hashable {
    public var enabled = false
    /// seconds 0…2
    public var time: Float = 0.3
    /// percent -100…100
    public var feedback: Float = 30
    /// percent 0…100 wet
    public var mix: Float = 30
    public init() {}
}

public struct ReverbSettings: Codable, Hashable {
    public enum Room: String, CaseIterable, Codable {
        case smallRoom = "Small Room", mediumRoom = "Medium Room", largeRoom = "Large Room"
        case mediumHall = "Medium Hall", largeHall = "Large Hall", plate = "Plate", cathedral = "Cathedral"

        /// Factory preset index of Apple's MatrixReverb.
        public var presetIndex: Int {
            switch self {
            case .smallRoom: return 0
            case .mediumRoom: return 1
            case .largeRoom: return 2
            case .mediumHall: return 3
            case .largeHall: return 4
            case .plate: return 5
            case .cathedral: return 8
            }
        }
    }
    public var enabled = false
    public var room: Room = .mediumRoom
    /// percent 0…100 wet
    public var mix: Float = 25
    public init() {}
}

public struct LimiterSettings: Codable, Hashable {
    public var enabled = false
    /// dB pre-gain -40…40
    public var preGain: Float = 0
    public init() {}
}
