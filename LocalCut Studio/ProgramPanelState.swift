import Foundation
import Observation
import LocalCutCore

// MARK: - Program panel state

/// Observable state for the Program Panel. Bridges between the UI and
/// the `ProgramSession` actor.
@Observable
@MainActor
final class ProgramPanelState {
    var isRunning = false
    var currentSceneId: UUID?
    var activeVideoSourceCount = 0
    var budgetMax = 4
    var isBudgetExhausted = false
    var capabilitySufficient = true
    var statusMessage = ""
    var isRefreshingSources = false
    var isStarting = false
    var isStopping = false

    private var ownsCurrentSession = false

    var sources: [CaptureSourceDescriptor] {
        sourceBindings.map(\.descriptor)
    }

    var sourceBindings: [ProgramCaptureSource] = []

    func refreshCapability(budget: EncoderBudget) {
        let verdict = Capabilities.current.tier(for: .programMode)
        capabilitySufficient = verdict.tier >= .accelerated
        if !capabilitySufficient {
            statusMessage = "Hardware insufficient: \(verdict.reason)"
        }
        Task { [weak self] in
            guard let self else { return }
            budgetMax = await budget.maxConcurrent
            updateBudgetReadout()
            await publishEncoderBudget(budget)
        }
    }

    func syncSessionState(model: EditorModel, scenes: [SceneDefinition]) {
        if model.programSession != nil {
            isRunning = true
            currentSceneId = currentSceneId ?? scenes.first?.id
            if statusMessage.isEmpty {
                statusMessage = "Program session recording."
            }
        } else if !isStarting && !isStopping {
            isRunning = false
            ownsCurrentSession = false
            currentSceneId = nil
        }
    }

    func refreshSources() async {
        guard !isRefreshingSources else { return }
        isRefreshingSources = true
        defer { isRefreshingSources = false }

        var refreshed: [ProgramCaptureSource] = []
        do {
            let screenOptions = try await CaptureSourceCatalog.screenOptions()
            refreshed.append(contentsOf: screenOptions.map(Self.descriptor(for:)))
        } catch {
            statusMessage = "Could not refresh screen sources: \(error.localizedDescription)"
        }

        refreshed.append(contentsOf: CaptureSourceCatalog.webcamOptions().map(Self.webcamDescriptor(for:)))
        refreshed.append(contentsOf: CaptureSourceCatalog.microphoneOptions().map(Self.microphoneDescriptor(for:)))
        sourceBindings = refreshed
        updateBudgetReadout()
        if sources.isEmpty, statusMessage.isEmpty {
            statusMessage = "No capture sources found."
        } else if !sources.isEmpty {
            statusMessage = "Found \(sources.count) capture source\(sources.count == 1 ? "" : "s")."
        }
    }

    func switchScene(to sceneId: UUID, model: EditorModel) {
        currentSceneId = sceneId
        Task { [weak model] in
            await model?.programSession?.switchScene(to: sceneId)
        }
    }

    func start(model: EditorModel, scenes: [SceneDefinition]) {
        guard !isRunning, !isStarting else { return }
        guard model.programSession == nil else {
            isRunning = true
            ownsCurrentSession = false
            currentSceneId = currentSceneId ?? scenes.first?.id
            statusMessage = "A Program Mode session is already recording."
            return
        }
        let enabledBindings = sourceBindings.filter(\.isEnabled)
        guard !enabledBindings.isEmpty, let first = scenes.first else { return }
        guard let root = model.resolvedRecordingsFolder(promptIfMissing: true) else {
            statusMessage = "Choose a recordings folder before starting Program Mode."
            return
        }
        let programSession = ProgramSession(budget: model.encoderBudget, rootURL: root)
        let captureSources = enabledBindings
        let initialScenes = scenes
        let renderSize = model.project.renderSize
        model.programSession = programSession
        ownsCurrentSession = true
        isStarting = true
        currentSceneId = first.id
        statusMessage = "Starting Program Mode..."
        Task { [weak self, weak model] in
            defer { self?.isStarting = false }
            guard let self else {
                // Panel was dismissed before session started — clean up the
                // session reference so future panels don't see a stale session.
                model?.programSession = nil
                return
            }
            guard let model else {
                self.ownsCurrentSession = false
                return
            }
            do {
                try await programSession.start(
                    captureSources: captureSources,
                    scenes: initialScenes,
                    renderSize: renderSize,
                    onCaptureFailure: { [weak self, weak model] result, message in
                        guard let self, let model else { return }
                        // Strong captures from guard-let: critical cleanup
                        // (stopWhipPublish, landing) must complete even if the
                        // panel is dismissed during the failure path.
                        Task { @MainActor [self, model] in
                            await model.stopWhipPublish()
                            self.isRunning = false
                            self.isStarting = false
                            self.isStopping = false
                            self.ownsCurrentSession = false
                            self.currentSceneId = nil
                            model.programSession = nil
                            if let result {
                                ProgramLanding.land(result: result, model: model)
                                if result.writerWarnings.isEmpty {
                                    self.statusMessage = "\(message) Program session stopped and landed."
                                } else {
                                    self.statusMessage = "\(message) Landed with warnings: \(result.writerWarnings.joined(separator: "; "))"
                                }
                            } else {
                                self.statusMessage = message
                            }
                            await self.publishEncoderBudget(model.encoderBudget)
                        }
                    })
                await publishEncoderBudget(model.encoderBudget)
                isRunning = true
                statusMessage = "Program session recording."
            } catch {
                await publishEncoderBudget(model.encoderBudget)
                model.programSession = nil
                ownsCurrentSession = false
                isRunning = false
                currentSceneId = nil
                statusMessage = error.localizedDescription
            }
        }
    }

    func stop(model: EditorModel) {
        guard isRunning, !isStopping, let session = model.programSession else { return }
        isStopping = true
        ownsCurrentSession = false
        isRunning = false
        statusMessage = "Stopping Program Mode..."
        // model and session are captured strongly to guarantee the critical
        // stop/landing path completes even if the panel is dismissed.
        // self is captured weakly for UI state updates only.
        Task { [weak self] in
            defer {
                self?.isStopping = false
                model.programSession = nil
                self?.currentSceneId = nil
            }
            do {
                await model.stopWhipPublish()
                let result = try await session.stop()
                await self?.publishEncoderBudget(model.encoderBudget)
                ProgramLanding.land(result: result, model: model)
                if result.writerWarnings.isEmpty {
                    self?.statusMessage = "Program session landed."
                } else {
                    self?.statusMessage = "Landed with warnings: \(result.writerWarnings.joined(separator: "; "))"
                }
            } catch {
                await self?.publishEncoderBudget(model.encoderBudget)
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    /// Tears down an owned session if this panel disappears while recording.
    /// Non-owning panel instances must not stop another visible panel's session.
    func teardownIfRunning(budget: EncoderBudget, model: EditorModel) {
        guard isRunning, ownsCurrentSession, let session = model.programSession else { return }
        isRunning = false
        ownsCurrentSession = false
        // model and session are captured strongly to guarantee teardown
        // completes even if the panel is dismissed mid-operation.
        // self is captured weakly for UI state updates only.
        Task { [weak self] in
            do {
                await model.stopWhipPublish()
                let result = try await session.stop()
                ProgramLanding.land(result: result, model: model)
            } catch {
                NSLog("[ProgramPanelState] teardown stop failed: \(error)")
                self?.statusMessage = "Teardown failed: \(error.localizedDescription)"
            }
            await self?.publishEncoderBudget(budget)
            model.programSession = nil
            self?.currentSceneId = nil
        }
    }

    func updateBudgetReadout() {
        activeVideoSourceCount = sourceBindings.filter { $0.isEnabled && $0.descriptor.kind.isVideo }.count
        isBudgetExhausted = activeVideoSourceCount > budgetMax
    }

    private func publishEncoderBudget(_ budget: EncoderBudget) async {
        let active = await budget.activeCount
        let max = await budget.maxConcurrent
        let ledgerSnapshot = await budget.ledger
        let ledger = ledgerSnapshot
            .map(\.consumer.rawValue)
            .sorted()
        DiagnosticsBridge.shared.setEncoderBudget(
            active: active,
            max: max,
            ledger: ledger)
    }

    private static func descriptor(for option: CaptureSourceOption) -> ProgramCaptureSource {
        let size = option.target.outputSize
        let descriptor = CaptureSourceDescriptor(
            id: stableUUID(for: "screen:\(option.id)"),
            kind: option.target.sourceKind,
            displayName: option.title,
            relativePath: "\(filenameStem(from: option.id)).mov",
            width: size.width,
            height: size.height,
            frameRate: 30)
        return ProgramCaptureSource(descriptor: descriptor, endpoint: .screen(option.target))
    }

    private static func webcamDescriptor(for option: CaptureDeviceOption) -> ProgramCaptureSource {
        let descriptor = CaptureSourceDescriptor(
            id: stableUUID(for: "webcam:\(option.id)"),
            kind: .webcam,
            displayName: option.title,
            relativePath: "\(filenameStem(from: "webcam-\(option.id)")).mov",
            width: 1920,
            height: 1080,
            frameRate: 30)
        return ProgramCaptureSource(descriptor: descriptor, endpoint: .webcam(deviceID: option.id))
    }

    private static func microphoneDescriptor(for option: CaptureDeviceOption) -> ProgramCaptureSource {
        let descriptor = CaptureSourceDescriptor(
            id: stableUUID(for: "microphone:\(option.id)"),
            kind: .microphone,
            displayName: option.title,
            relativePath: "\(filenameStem(from: "microphone-\(option.id)")).mov",
            sampleRate: 48_000,
            channels: 1)
        return ProgramCaptureSource(descriptor: descriptor, endpoint: .microphone(deviceID: option.id))
    }

    private static func filenameStem(from value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let stem = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return stem.isEmpty ? "source" : stem
    }

    private static func stableUUID(for value: String) -> UUID {
        let bytes = Array(value.utf8)
        let first = fnv1a64(bytes: bytes, seed: 0xcbf2_9ce4_8422_2325)
        let second = fnv1a64(bytes: bytes.reversed(), seed: 0x8422_2325_cbf2_9ce4)
        var uuidBytes: [UInt8] = []
        uuidBytes.reserveCapacity(16)
        for shift in stride(from: 56, through: 0, by: -8) {
            uuidBytes.append(UInt8((first >> UInt64(shift)) & 0xff))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            uuidBytes.append(UInt8((second >> UInt64(shift)) & 0xff))
        }
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
    }

    private static func fnv1a64<S: Sequence>(bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }
}
