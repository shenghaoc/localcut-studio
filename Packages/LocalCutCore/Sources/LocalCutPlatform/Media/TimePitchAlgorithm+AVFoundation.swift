import AVFoundation
import LocalCutCore

public extension TimePitchAlgorithm {
    var avFoundationAlgorithm: AVAudioTimePitchAlgorithm {
        switch self {
        case .timeDomain: .timeDomain
        case .spectral: .spectral
        }
    }
}
