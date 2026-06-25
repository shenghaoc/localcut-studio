import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore

enum VoiceCleanupAudioProcessing {
    struct PCMBlock {
        var samples: [Float]
        var channels: Int
        var sampleRate: Double
    }

    nonisolated static func process(sample: CMSampleBuffer,
                                    settings: VoiceCleanupSettings,
                                    state: inout VoiceCleanupProcessorState) -> CMSampleBuffer? {
        guard var block = floatBlock(from: sample) else { return nil }
        VoiceCleanupDSP.processInterleaved(
            &block.samples,
            channels: block.channels,
            sampleRate: block.sampleRate,
            settings: settings,
            state: &state)
        return makeInt16SampleBuffer(
            from: block.samples,
            channels: block.channels,
            sampleRate: block.sampleRate,
            source: sample)
    }

    nonisolated static func measureLoudness(composition: AVComposition,
                                            audioMix: AVAudioMix?,
                                            duration: Double,
                                            settings: VoiceCleanupSettings) throws -> LoudnessAnalysisResult {
        guard duration >= 3 else {
            return LoudnessAnalysisResult(
                measuredLUFS: -.infinity,
                targetLUFS: settings.loudness.targetLUFS,
                gainDB: 0,
                durationSeconds: duration,
                note: "Normalisation skipped: selection is shorter than 3 seconds.")
        }

        let audioTracks = composition.tracks(withMediaType: .audio) as [AVAssetTrack]
        guard !audioTracks.isEmpty else {
            return LoudnessAnalysisResult(
                measuredLUFS: -.infinity,
                targetLUFS: settings.loudness.targetLUFS,
                gainDB: 0,
                durationSeconds: duration,
                note: "Normalisation skipped: project has no audio.")
        }

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VoiceCleanupError.readerOutputRejected
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? VoiceCleanupError.readerStartFailed
        }

        var analysisSettings = settings
        analysisSettings.loudness.appliedGainDB = 0
        analysisSettings.loudness.enabled = false
        var state = VoiceCleanupProcessorState()
        var analyser = EBUR128LoudnessAnalyser(sampleRate: 48_000, channels: 2)

        while let sample = output.copyNextSampleBuffer() {
            guard var block = floatBlock(from: sample) else { continue }
            VoiceCleanupDSP.processInterleaved(
                &block.samples,
                channels: block.channels,
                sampleRate: block.sampleRate,
                settings: analysisSettings,
                state: &state)
            analyser.feedInterleaved(block.samples, channels: block.channels)
        }

        if reader.status == .failed, let error = reader.error {
            throw error
        }

        let measured = analyser.integratedLoudness()
        let gain = VoiceCleanupDSP.normalisationGain(
            measuredLUFS: measured,
            targetLUFS: settings.loudness.targetLUFS)
        return LoudnessAnalysisResult(
            measuredLUFS: measured,
            targetLUFS: settings.loudness.targetLUFS,
            gainDB: gain,
            durationSeconds: duration)
    }

    nonisolated static func floatBlock(from sample: CMSampleBuffer) -> PCMBlock? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sample),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let dataBuffer = CMSampleBufferGetDataBuffer(sample) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        let flags = asbd.mFormatFlags
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 16,
              asbd.mChannelsPerFrame > 0,
              asbd.mBytesPerFrame == asbd.mChannelsPerFrame * UInt32(MemoryLayout<Int16>.size),
              flags & kAudioFormatFlagIsSignedInteger != 0,
              flags & kAudioFormatFlagIsFloat == 0,
              flags & kAudioFormatFlagIsBigEndian == 0,
              flags & kAudioFormatFlagIsNonInterleaved == 0 else {
            return nil
        }

        let channels = Int(asbd.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sample)
        let byteCount = frameCount * channels * MemoryLayout<Int16>.size
        guard byteCount > 0 else {
            return PCMBlock(samples: [], channels: channels, sampleRate: asbd.mSampleRate)
        }

        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination)
        }
        guard status == noErr else { return nil }

        var samples = Array(repeating: Float(0), count: frameCount * channels)
        data.withUnsafeBytes { bytes in
            for index in samples.indices {
                let offset = index * MemoryLayout<Int16>.size
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                samples[index] = max(-1, Float(Int16(bitPattern: bits)) / 32768)
            }
        }
        return PCMBlock(samples: samples, channels: channels, sampleRate: asbd.mSampleRate)
    }

    private nonisolated static func makeInt16SampleBuffer(from samples: [Float],
                                                          channels: Int,
                                                          sampleRate: Double,
                                                          source: CMSampleBuffer) -> CMSampleBuffer? {
        guard channels > 0 else { return nil }
        let frameCount = samples.count / channels
        var outputBytes = Data(count: samples.count * MemoryLayout<Int16>.size)
        outputBytes.withUnsafeMutableBytes { (rawBytes: UnsafeMutableRawBufferPointer) in
            for index in samples.indices {
                let clamped = max(-1, min(0.999_969_5, samples[index]))
                let intValue = Int16(clamped * 32767)
                let bits = UInt16(bitPattern: intValue)
                let offset = index * MemoryLayout<Int16>.size
                rawBytes[offset] = UInt8(bits & 0x00ff)
                rawBytes[offset + 1] = UInt8((bits >> 8) & 0x00ff)
            }
        }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: outputBytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: outputBytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard createStatus == noErr, let blockBuffer else { return nil }

        let replaceStatus = outputBytes.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: outputBytes.count)
        }
        guard replaceStatus == noErr else { return nil }

        guard let formatDescription = CMSampleBufferGetFormatDescription(source) else {
            return nil
        }
        let totalDuration = CMSampleBufferGetDuration(source)
        let sampleDuration: CMTime
        if totalDuration.isValid, totalDuration.isNumeric, frameCount > 0 {
            sampleDuration = CMTimeMultiplyByRatio(
                totalDuration,
                multiplier: 1,
                divisor: Int32(max(1, frameCount)))
        } else {
            sampleDuration = CMTime(value: 1, timescale: CMTimeScale(sampleRate))
        }

        var timing = CMSampleTimingInfo(
            duration: sampleDuration,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
            decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &output)
        guard sampleStatus == noErr else { return nil }
        return output
    }
}

enum VoiceCleanupError: LocalizedError {
    case readerOutputRejected
    case readerStartFailed

    var errorDescription: String? {
        switch self {
        case .readerOutputRejected:
            "Could not add an audio reader output for loudness measurement."
        case .readerStartFailed:
            "Could not start audio reader for loudness measurement."
        }
    }
}
