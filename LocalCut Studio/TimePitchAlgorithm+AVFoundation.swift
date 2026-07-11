import AVFoundation
import LocalCutCore

extension TimePitchAlgorithm {
    var avFoundationAlgorithm: AVAudioTimePitchAlgorithm {
        switch self {
        case .timeDomain: .timeDomain
        case .spectral: .spectral
        }
    }
}
