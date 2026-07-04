import SwiftUI
import LocalCutCore

struct PublishPanel: View {
    @Bindable var model: EditorModel
    @State private var publishState = PublishPanelState()

    var body: some View {
        Form {
            headerSection
            endpointSection
            codecSection
            rtmpHonestySection
            controlsSection
            statusSection
            reducedTierSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 280)
        .onAppear {
            publishState.refreshCapability(model: model)
            if !model.publishSettings.endpointURL.isEmpty {
                publishState.endpointURL = model.publishSettings.endpointURL
                publishState.endpointType = model.publishSettings.endpointType
            }
        }
        .onChange(of: model.programSession != nil) { _, _ in
            publishState.refreshCapability(model: model)
        }
    }

    private var headerSection: some View {
        Section {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.red)
                Text("WHIP Publish")
                    .font(.headline)
                Spacer()
                if publishState.publishState == .live {
                    Label("LIVE", systemImage: "circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption.bold())
                        .accessibilityLabel("Currently live")
                }
            }
        }
    }

    private var endpointSection: some View {
        Section {
            Picker("Endpoint Type", selection: $publishState.endpointType) {
                ForEach(PublishEndpointType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .accessibilityLabel("Endpoint type")

            TextField("Endpoint URL", text: $publishState.endpointURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .disableAutocorrection(true)
                .accessibilityLabel("WHIP endpoint URL")

            if publishState.endpointRequiresToken {
                SecureField("Stream key", text: $publishState.bearerToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .accessibilityLabel("Stream key")

                Toggle("Remember on this device", isOn: $publishState.rememberToken)
                    .font(.caption)
                    .accessibilityHint("Stores the token in the Keychain.")
            }
        } header: {
            Text("Endpoint")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }

    private var codecSection: some View {
        Section {
            Picker("Codec", selection: $publishState.selectedCodec) {
                ForEach(PublishCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            .accessibilityLabel("Video codec")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Video Bitrate").font(.caption)
                    Spacer()
                    Text("\(publishState.videoBitrate) kbps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(publishState.videoBitrate) },
                        set: { publishState.videoBitrate = Int($0) }
                    ),
                    in: 500...20_000, step: 500
                )
                .accessibilityLabel("Video bitrate")
                .accessibilityValue("\(publishState.videoBitrate) kilobits per second")
            }

            HStack {
                Text("Audio Bitrate").font(.caption)
                Spacer()
                Text("\(publishState.audioBitrate) kbps Opus")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Stepper(value: $publishState.keyframeInterval, in: 1...10) {
                HStack {
                    Text("Keyframe Interval").font(.caption)
                    Spacer()
                    Text("\(publishState.keyframeInterval)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Keyframe interval")
            .accessibilityValue("\(publishState.keyframeInterval) seconds")
        } header: {
            Text("Codec")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }

    private var rtmpHonestySection: some View {
        Section {
            Text("RTMP-only platforms are not directly supported. Use a WHIP-to-RTMP gateway such as MediaMTX. LocalCut does not host or proxy relays.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controlsSection: some View {
        Section {
            HStack {
                if publishState.publishState == .live || publishState.publishState == .reconnecting || publishState.publishState == .connecting {
                    Button {
                        publishState.stopPublish(model: model)
                    } label: {
                        Label("Stop Publish", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(publishState.isStopping)
                    .accessibilityLabel("Stop publishing")
                } else {
                    Button {
                        publishState.startPublish(model: model)
                    } label: {
                        Label("Start Publish", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!publishState.canStart)
                    .accessibilityLabel("Start publishing")
                }
            }
            if !publishState.statusMessage.isEmpty {
                Text(publishState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel("Status: \(publishState.statusMessage)")
            }
        }
    }

    private var statusSection: some View {
        Group {
            if publishState.publishState != .idle {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        stateRow
                        if let stats = publishState.stats {
                            Divider()
                            statsGrid(stats)
                        }
                    }
                } header: {
                    Text("Status")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateRow: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(stateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statsGrid(_ stats: PublishStatsDisplay) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Bytes sent").font(.caption).foregroundStyle(.secondary)
                Text(PublishPanelState.formattedBytes(stats.bytesSent)).font(.caption.monospacedDigit())
            }
            GridRow {
                Text("Frames").font(.caption).foregroundStyle(.secondary)
                Text("\(stats.framesSent)").font(.caption.monospacedDigit())
            }
            GridRow {
                Text("Bitrate").font(.caption).foregroundStyle(.secondary)
                Text(PublishPanelState.formattedBitrate(stats.bitrate)).font(.caption.monospacedDigit())
            }
            GridRow {
                Text("RTT").font(.caption).foregroundStyle(.secondary)
                Text(PublishPanelState.formattedRTT(stats.rtt)).font(.caption.monospacedDigit())
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var reducedTierSection: some View {
        Group {
            if !publishState.isWebRTCAvailable || !publishState.isBudgetAvailable || !publishState.isProgramOutputAvailable {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        if !publishState.isWebRTCAvailable {
                            Label("WebRTC framework is not available in this build.", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                        if !publishState.isProgramOutputAvailable {
                            Label("Start Program Mode to publish the live program output.", systemImage: "rectangle.on.rectangle.slash")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                        if !publishState.isBudgetAvailable {
                            Label("Encoder budget exhausted — stop another session to publish.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Availability")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateColor: Color {
        switch publishState.publishState {
        case .idle: .secondary
        case .connecting: .orange
        case .live: .red
        case .reconnecting: .yellow
        case .failed: .red
        case .ended: .secondary
        }
    }

    private var stateLabel: String {
        switch publishState.publishState {
        case .idle: "Idle"
        case .connecting: "Connecting…"
        case .live: "Live"
        case .reconnecting: "Reconnecting…"
        case .failed: "Failed"
        case .ended: "Ended"
        }
    }
}
