import SwiftUI
import AppKit
import AVFoundation
import LocalCutCore
import LocalCutDomain

/// The multi-track timeline: a time ruler, one lane per track, clip blocks, and a
/// draggable playhead. Zoom is controlled by `model.pixelsPerSecond`.
struct TimelineView: View {
    @Bindable var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rulerHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var laneHeight: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var gutterWidth: CGFloat = 56
    @ScaledMetric(relativeTo: .caption2) private var markerLabelWidth: CGFloat = 60
    @ScaledMetric(relativeTo: .body) private var markerRenameFieldWidth: CGFloat = 160
    private let zoomSliderWidth: CGFloat = 140
    private let edgeZoneWidth: CGFloat = 8
    private let markerGlyphSize: CGFloat = 12
    private static let rulerCoordinateSpace = "timelineRuler"
    /// Cached system separator colour for the marker stroke. Computed once
    /// (per type) rather than allocated per glyph per ruler tick (audit P3).
    private static let markerSeparatorStroke: Color = Color(nsColor: .separatorColor)
    @State private var renamingMarkerID: TimelineMarker.ID?
    @State private var renameDraft: String = ""
    @State private var timelineScrollTargetSeconds: Double = 0
    @State private var timelineScrollRequest = 0
    /// Viewport width captured via GeometryReader so the center-playhead
    /// action can offset the scroll anchor by half the visible area.
    @State private var timelineViewportWidth: CGFloat = 0
    /// Live leading-edge of the visible timeline window, in seconds, fed by
    /// `onScrollGeometryChange`. Lets the page-scroll buttons and the
    /// accessibilityAdjustableAction base their delta on the *current* viewport
    /// — including manual trackpad / scrollbar scrolls — instead of the stale
    /// last programmatic target (Codex P2 on d8c7ee2).
    @State private var timelineCurrentScrollSeconds: Double = 0
    @FocusState private var focusedClipID: Clip.ID?
    @FocusState private var focusedTransitionClipID: Clip.ID?
    @FocusState private var receivesTimelineShortcuts: Bool

    private var pps: CGFloat { CGFloat(model.pixelsPerSecond) }

    /// Content width in points, with headroom past the last clip *or* the
    /// last marker — markers don't extend `Project.duration`, but they still
    /// have to be visible on the scrollable ruler (Codex review #3).
    private var contentWidth: CGFloat {
        let tail = max(model.totalDuration, model.project.markers.last?.time.seconds ?? 0)
        return max(CGFloat(tail) + 4, 10) * pps
    }

    private var tracks: [Track] {
        model.project.videoTracks + model.project.audioTracks
    }

    private var captionTracks: [CaptionTrack] {
        model.project.captionTracks
    }

    /// Project-wide transition cuts used to ripple clip positions so the timeline
    /// matches the rendered composition.
    private var transitionCuts: [TransitionLayout.Cut] {
        TransitionLayout.cuts(videoTracks: model.project.videoTracks.map(\.clips))
    }

    // MARK: - Drag state

    enum DragMode: Equatable {
        case trimmingLeft(clipID: Clip.ID, candidate: CMTime)
        case trimmingRight(clipID: Clip.ID, candidate: CMTime)
        case moving(clipID: Clip.ID, candidateStart: CMTime, sourceTrackID: Track.ID, targetTrackIndex: Int)
    }

    @State private var dragMode: DragMode?
    @State private var captionDrag: CaptionLineDrag?
    @State private var hoverEdge: HoverEdge?
    // Track which trim-edge hover-cursor we currently own so `onDisappear` only
    // pops a cursor this view actually pushed — an unconditional pop would
    // unbalance the global NSCursor stack when a clip leaves the ForEach while
    // not hovered. (The ruler and markers use declarative `.pointerStyle`.)
    private struct CaptionLineDrag: Equatable {
        let lineID: CaptionLine.ID
        let trackID: CaptionTrack.ID
        let candidateStart: CMTime
    }

    enum HoverEdge: Equatable {
        case left(Clip.ID)
        case right(Clip.ID)
    }

    private enum TimelineScrollAnchor: Hashable {
        case viewportTarget
    }

    private struct ClipFocusCandidate {
        let id: Clip.ID
        let startSeconds: Double
        let trackIndex: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                gutter
                Divider()
                timelineScroller
            }
        }
        .focusable()
        .focused($receivesTimelineShortcuts)
        .onAppear { receivesTimelineShortcuts = true }
        .onKeyPress { press in
            switch TimelineShortcutPolicy.action(for: press) {
            case .ignore:
                return .ignored
            case .togglePlay:
                model.togglePlayPause()
            case .addMarker:
                model.addMarkerAtPlayhead()
            case .renameMarker:
                beginRenamingSelectedMarker()
            case .maybeDeleteMarker:
                // Leave clip / transition deletion to the existing scoped
                // `onDeleteCommand` when no marker owns this key press.
                guard deleteSelectedMarkerIfAny() else { return .ignored }
            }
            return .handled
        }
        .onDeleteCommand {
            _ = deleteSelectedClipOrTransitionIfAny()
        }
        .onMoveCommand(perform: moveTimelineSelection)
        .onChange(of: focusedClipID) { _, newValue in
            guard let newValue, model.selectedClipID != newValue else { return }
            model.selectClip(id: newValue)
            scrollTimelineToClip(id: newValue)
        }
        .onChange(of: focusedTransitionClipID) { _, newValue in
            guard let newValue, model.selectedTransitionClipID != newValue else { return }
            model.selectTransition(clipID: newValue)
        }
        .onChange(of: model.selectedClipID) { _, newValue in
            focusedClipID = newValue
            if newValue != nil {
                focusedTransitionClipID = nil
            }
        }
        .onChange(of: model.selectedTransitionClipID) { _, newValue in
            focusedTransitionClipID = newValue
            if newValue != nil {
                focusedClipID = nil
            }
        }
    }

    /// Opens the rename popover for the selected marker; reports guidance when
    /// none is selected. Called from the Shift+M key handler.
    private func beginRenamingSelectedMarker() {
        guard let marker = model.selectedMarker else {
            model.statusMessage = "Select a marker on the ruler to rename."
            return
        }
        renameDraft = marker.name
        renamingMarkerID = marker.id
    }

    /// Deletes the selected marker; returns whether anything was deleted so the
    /// Delete handler can decide whether to consume the key. When no marker is
    /// selected the scoped timeline delete command handles clips/transitions.
    @discardableResult
    private func deleteSelectedMarkerIfAny() -> Bool {
        guard let id = model.selectedMarkerID else { return false }
        model.removeMarker(id: id)
        return true
    }

    @discardableResult
    private func deleteSelectedClipOrTransitionIfAny() -> Bool {
        if model.selectedTransitionClipID != nil {
            model.removeSelectedTransition()
            return true
        }
        guard model.selectedClipID != nil else { return false }
        model.deleteSelectedClip()
        return true
    }

    // MARK: Header

    private var header: some View {
        EditorPanelHeader("Timeline", verticalPadding: 6) {
            Button {
                scrollTimelinePage(-1)
            } label: {
                Image(systemName: "arrow.left.to.line.compact")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(model.totalDuration <= 0)
            .help("Scroll timeline left")
            .accessibilityLabel("Scroll timeline left")

            Button {
                requestTimelineScroll(to: model.currentTime)
            } label: {
                Image(systemName: "smallcircle.filled.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(model.totalDuration <= 0)
            .help("Center playhead in timeline")
            .accessibilityLabel("Center playhead in timeline")

            Button {
                scrollTimelinePage(1)
            } label: {
                Image(systemName: "arrow.right.to.line.compact")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(model.totalDuration <= 0)
            .help("Scroll timeline right")
            .accessibilityLabel("Scroll timeline right")

            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $model.pixelsPerSecond, in: 20...300)
                .frame(width: zoomSliderWidth)
                .help("Zoom timeline")
                .accessibilityLabel("Timeline zoom")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    // MARK: Left gutter (track labels)

    private var gutter: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ForEach(tracks) { track in
                Divider()
                HStack(spacing: 4) {
                    Image(systemName: track.kind == .video ? "film" : "waveform")
                        .font(.caption)
                    Text(track.name)
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: laneHeight)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(trackAccessibilityLabel(track))
            }
            ForEach(captionTracks) { track in
                Divider()
                HStack(spacing: 4) {
                    Image(systemName: "captions.bubble")
                        .font(.caption)
                    Text(track.name)
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: laneHeight)
                .foregroundStyle(track.isMuted ? .tertiary : .secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(captionTrackAccessibilityLabel(track))
            }
        }
        .frame(width: gutterWidth)
        .background(Color.lcRail)
    }

    private func trackAccessibilityLabel(_ track: Track) -> Text {
        let name = track.name
        let count = track.clips.count
        // One whole localized string per kind so a translator controls the entire
        // order (name / kind / count), not just isolated fragments.
        let label = track.kind == .video
            ? AttributedString(localized: "\(name), video track, ^[\(count) clip](inflect: true)")
            : AttributedString(localized: "\(name), audio track, ^[\(count) clip](inflect: true)")
        return Text(label)
    }

    private func captionTrackAccessibilityLabel(_ track: CaptionTrack) -> Text {
        let name = track.name
        let count = track.lines.count
        // Whole localized strings (muted vs not) so the mute state can be
        // reordered relative to the track name and kind in any locale.
        let label = track.isMuted
            ? AttributedString(localized: "\(name), caption track, ^[\(count) caption line](inflect: true), muted")
            : AttributedString(localized: "\(name), caption track, ^[\(count) caption line](inflect: true)")
        return Text(label)
    }

    // MARK: Scrollable timeline content

    private var timelineScroller: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal]) {
                // Compute transition cuts once per body invalidation — every
                // video lane shares the same set, so reading the computed var
                // per-lane would otherwise re-sort/-merge all video clips for
                // each lane on every currentTime tick (audit P3).
                let cuts = transitionCuts
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ruler
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { trackIndex, track in
                            Divider()
                            lane(for: track, trackIndex: trackIndex, cuts: cuts)
                        }
                        ForEach(captionTracks) { track in
                            Divider()
                            captionLane(for: track)
                        }
                    }
                    timelineScrollAnchor
                    PlayheadView(model: model, pps: pps, rulerHeight: rulerHeight)
                }
                .frame(width: contentWidth, alignment: .topLeading)
            }
            // Mirror the live viewport leading-edge into state so page-scroll
            // buttons + the adjustable a11y action use the *current* offset
            // (including manual trackpad / scrollbar scrolls), not a stale
            // programmatic target (Codex P2 on d8c7ee2).
            .onScrollGeometryChange(for: Double.self) { geo in
                Double(geo.contentOffset.x) / max(Double(pps), 1)
            } action: { _, newSeconds in
                timelineCurrentScrollSeconds = newSeconds
            }
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { timelineViewportWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, new in timelineViewportWidth = new }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline viewport")
            .accessibilityValue("Around \(TimeFormatting.timecode(timelineScrollTargetSeconds))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    scrollTimelinePage(1)
                case .decrement:
                    scrollTimelinePage(-1)
                @unknown default:
                    break
                }
            }
            .onChange(of: timelineScrollRequest) { _, _ in
                // Defer one runloop: the same update changed
                // timelineScrollTargetSeconds (and thus the anchor's spacer
                // width), so scrolling synchronously would read the anchor's
                // pre-layout geometry and target the previous position.
                DispatchQueue.main.async {
                    if reduceMotion {
                        proxy.scrollTo(TimelineScrollAnchor.viewportTarget, anchor: .leading)
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(TimelineScrollAnchor.viewportTarget, anchor: .leading)
                        }
                    }
                }
            }
        }
    }

    private var timelineScrollAnchor: some View {
        // Lay the anchor out at the target time *minus half the viewport* via a
        // real leading spacer, so a `.leading` scroll lands the target at centre.
        // `.offset` is a render-only transform — it does NOT move the layout
        // frame `ScrollViewReader.scrollTo` targets, so the anchor stayed at x=0
        // and every scroll request (center / page / focus) snapped to the start.
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, CGFloat(timelineScrollTargetSeconds) * pps - timelineViewportWidth / 2),
                       height: 1)
            Color.clear
                .frame(width: 1, height: 1)
                .id(TimelineScrollAnchor.viewportTarget)
        }
        .accessibilityHidden(true)
    }

    private var ruler: some View {
        let markers = model.project.markers
        let beatMarkers = model.showBeatMarkers ? model.projectedBeatMarkers() : []
        let selectedMarkerID = model.selectedMarkerID
        return ZStack(alignment: .topLeading) {
            // The primary scrub gesture lives on the Canvas — *not* the ZStack —
            // and marker labels mirror it so their tooltips do not block scrubs.
            // Keeping the gesture off the outer ZStack lets diamond taps win.
            RulerBackgroundCanvas(
                pps: pps,
                rulerHeight: rulerHeight,
                tickStep: tickStep(),
                beatMarkersRevision: model.projectedBeatTimesRevision,
                beatMarkers: beatMarkers
            )
            .equatable()
            .contentShape(Rectangle())
            .gesture(rulerScrubGesture)
            .accessibilityHidden(true)
            .overlay {
                RulerAccessibilityOverlay(model: model, tickStep: tickStep())
                    .allowsHitTesting(false)
            }
            // Declarative resize cursor signals the ruler is scrubbable. Region-
            // based, so there's no shared NSCursor push/pop stack to unbalance
            // when the ruler Canvas rebuilds on zoom.
            .pointerStyle(.columnResize)
            .help("Drag to scrub")

            ForEach(markers) { marker in
                markerGlyph(marker, isSelected: marker.id == selectedMarkerID)
            }
        }
        .frame(height: rulerHeight)
        .background(Color.lcRail)
        .coordinateSpace(.named(Self.rulerCoordinateSpace))
    }

    /// Scrub gesture that also clears any marker selection on a fresh press,
    /// so dragging the playhead off the marker band releases focus from a
    /// previously-selected marker. It is attached to the Canvas and marker
    /// labels — not the parent ZStack — so diamond taps still win.
    private var rulerScrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rulerCoordinateSpace))
            .onChanged { value in
                if model.selectedMarkerID != nil { model.selectedMarkerID = nil }
                // Fast seek during drag; the playhead head's gesture handles
                // the precise end-of-drag seek when the user scrubs there.
                model.seek(toSeconds: Double(value.location.x / pps),
                           tolerance: CMTime(seconds: 0.1, preferredTimescale: 600))
            }
            .onEnded { value in
                model.seek(toSeconds: Double(value.location.x / pps))
            }
    }

    /// One marker glyph + label drawn at the marker's `time`. The popover
    /// reopens whenever `renamingMarkerID` matches this marker's id.
    ///
    /// The diamond remains the marker's only selection target. The floating
    /// label mirrors the ruler's scrub gesture so it can expose the full marker
    /// name on hover without swallowing clicks that should scrub the ruler.
    @ViewBuilder
    private func markerGlyph(_ marker: TimelineMarker, isSelected: Bool) -> some View {
        let x = CGFloat(marker.time.seconds) * pps
        let fill: Color = marker.colour.map { Color(cgColor: $0.cgColor) } ?? Color.lcAccent
        // Adaptive separator colour rather than a fixed translucent black so the
        // outline tracks Dark Mode and Increase Contrast; selected stays on gold.
        let strokeColor: Color = isSelected ? .lcAccent : Self.markerSeparatorStroke
        let strokeWidth: CGFloat = isSelected ? 2 : 1
        let labelWidth = markerLabelWidth
        VStack(spacing: 1) {
            Text(marker.name)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.regularMaterial.opacity(0.8)))
                .frame(width: labelWidth)
                .contentShape(Rectangle())
                .help(marker.name)
                .pointerStyle(.columnResize)
                .gesture(rulerScrubGesture)
                .accessibilityHidden(true)
            MarkerDiamond()
                .fill(fill)
                .overlay(MarkerDiamond().stroke(strokeColor, lineWidth: strokeWidth))
                .frame(width: markerGlyphSize, height: markerGlyphSize)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .help(marker.name)
                // Pointing-hand cursor over the marker (declarative; replaces a
                // manual NSCursor push/pop hover wrapper).
                .pointerStyle(.link)
                .onTapGesture { model.selectMarker(id: marker.id) }
                .popover(isPresented: Binding(
                    get: { renamingMarkerID == marker.id },
                    set: { newValue in if !newValue { commitRenameIfActive(); renamingMarkerID = nil } }
                )) {
                    markerRenamePopover(marker)
                }
                .accessibilityLabel("Marker \(marker.name) at \(TimeFormatting.timecode(marker.time.seconds))")
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .frame(width: labelWidth, alignment: .center)
        .offset(x: x - labelWidth / 2, y: 0)
    }

    @ViewBuilder
    private func markerRenamePopover(_ marker: TimelineMarker) -> some View {
        HStack(spacing: 8) {
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: markerRenameFieldWidth)
                .onSubmit { commitRenameIfActive(); renamingMarkerID = nil }
            Button("Done") {
                commitRenameIfActive()
                renamingMarkerID = nil
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private func commitRenameIfActive() {
        guard let id = renamingMarkerID else { return }
        model.renameMarker(id: id, to: renameDraft)
    }

    private func lane(for track: Track, trackIndex: Int, cuts: [TransitionLayout.Cut]) -> some View {
        let placements = TransitionLayout.placements(for: track.clips, cuts: cuts)
        let effectiveStarts = Dictionary(uniqueKeysWithValues: placements.map { ($0.clip.id, $0.effectiveStart) })
        return ZStack(alignment: .topLeading) {
            Color.lcLane
                .contentShape(Rectangle())
                .onTapGesture {
                    model.clearSelection()
                    focusedClipID = nil
                }
            ForEach(track.clips) { clip in
                clipBlock(clip, kind: track.kind, trackID: track.id, trackIndex: trackIndex,
                          effectiveStart: effectiveStarts[clip.id] ?? clip.timelineStart)
            }
            if track.kind == .video {
                ForEach(placements.filter { $0.transitionRange != nil }) { placement in
                    transitionGlyph(placement)
                }
            }
        }
        .frame(height: laneHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func captionLane(for track: CaptionTrack) -> some View {
        ZStack(alignment: .topLeading) {
            Color.lcLane
                .contentShape(Rectangle())
                .onTapGesture {
                    model.clearSelection()
                    focusedClipID = nil
                }
            ForEach(track.lines) { line in
                captionLineBlock(line, in: track)
            }
        }
        .frame(height: laneHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(track.isMuted ? 0.45 : 1)
    }

    private func captionLineBlock(_ line: CaptionLine, in track: CaptionTrack) -> some View {
        let candidateStart = captionDrag?.lineID == line.id ? captionDrag?.candidateStart : nil
        let start = candidateStart ?? line.range.start
        let x = CGFloat(start.seconds) * pps
        let width = max(CGFloat(line.range.duration.seconds) * pps, 18)
        let label = line.text.isEmpty ? "Caption" : line.text

        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.lcCaptionFill.opacity(captionDrag?.lineID == line.id ? 0.25 : 0.38))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.lcCaptionStroke, lineWidth: 1))
            .overlay(alignment: .leading) {
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .foregroundStyle(.primary)
                    .help(label)
            }
            .frame(width: width, height: laneHeight - 14)
            .offset(x: x, y: 7)
            .contentShape(Rectangle())
            .gesture(captionLineDragGesture(line: line, trackID: track.id))
            .contextMenu {
                Button("Move to Playhead") {
                    let start = CMTime(seconds: max(0, model.currentTime), preferredTimescale: 600)
                    model.retimeCaptionLine(line.id, in: track.id, start: start)
                    model.commitCoalescedUndo()
                }
                Divider()
                Button("Remove Caption Line", role: .destructive) {
                    model.removeCaptionLine(line.id, in: track.id)
                }
            }
            .accessibilityLabel("Caption \(label)")
            .accessibilityValue("Starts \(TimeFormatting.timecode(start.seconds)), \(TimeFormatting.timecode(line.range.duration.seconds)) long")
            .accessibilityAddTraits(.isButton)
    }

    /// A selectable glyph drawn over the overlap region at a transition's cut.
    @ViewBuilder
    private func transitionGlyph(_ placement: TransitionLayout.Placement) -> some View {
        if let overlap = placement.transitionRange {
            let x = CGFloat(overlap.start.seconds) * pps
            let width = max(CGFloat(overlap.duration.seconds) * pps, 12)
            let isSelected = model.selectedTransitionClipID == placement.clip.id
            let type = placement.clip.transition?.type ?? .crossDissolve
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.lcTransitionFill.opacity(isSelected ? 0.5 : 0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.lcAccent : Color.lcTransitionFill.opacity(0.8),
                                      lineWidth: isSelected ? 2 : 1))
                .overlay(
                    Image(systemName: type.symbolName)
                        .font(.caption2)
                        .foregroundStyle(Color.lcTransitionIcon))
                .frame(width: width, height: laneHeight - 16)
                .offset(x: x, y: 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectTransition(clipID: placement.clip.id)
                    focusedClipID = nil
                    focusedTransitionClipID = placement.clip.id
                }
                .focusable()
                .focused($focusedTransitionClipID, equals: placement.clip.id)
                .accessibilityLabel("\(type.displayName) transition")
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    // MARK: - Clip block with trim/drag interaction

    private func clipBlock(_ clip: Clip, kind: TrackKind, trackID: Track.ID, trackIndex: Int,
                           effectiveStart: CMTime) -> some View {
        let shift = clip.timelineStart - effectiveStart
        let displayValues = clipDisplayValues(clip, trackIndex: trackIndex, shift: shift)
        let width = displayValues.width
        let x = displayValues.x
        let isSelected = model.selectedClipID == clip.id
        let baseColor: Color = kind == .video ? .blue : .green
        // Precompute the name and its localized accessibility label outside the
        // view builder: inlining `.map(Text.init)` tipped this already-large
        // expression past the Swift type-checker's time budget.
        let clipName = model.project.media(for: clip.mediaID)?.name
        let nameLabel: Text = clipName.map(Text.init) ?? Text("Clip")
        // Announce the rippled (effective) start so VoiceOver matches the drawn
        // block position when an upstream transition has shortened the timeline.
        let valueLabel = Text("Starts \(TimeFormatting.timecode(effectiveStart.seconds)), \(TimeFormatting.timecode(clip.outputDuration.seconds)) long")

        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(baseColor.opacity(isDragging(clip.id) ? 0.2 : 0.35))
                .overlay {
                    ClipIdentityOverlay(name: clipName ?? "Clip",
                                        systemImage: kind == .video ? "film" : "waveform")
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.lcAccent : baseColor.opacity(0.6),
                                      lineWidth: isSelected ? 2 : 1))

            // Edge zones for trim handles
            HStack(spacing: 0) {
                trimHandle(edge: .left, clip: clip, shift: shift)
                Spacer(minLength: 0)
                trimHandle(edge: .right, clip: clip, shift: shift)
            }
        }
        .frame(width: width, height: laneHeight - 8)
        .offset(x: x, y: displayValues.yOffset)
        .opacity(displayValues.opacity)
        .onTapGesture {
            selectTimelineClip(clip)
        }
        .contextMenu {
            Button("Split at Playhead") {
                model.selectClip(id: clip.id)
                model.splitSelectedClipAtPlayhead()
            }
            // Transitions are video-only — hide the entry on audio clips
            // rather than showing it greyed out (canAddTransition would
            // disable it but the entry would still appear, which is
            // misleading UX for a concept that never applies to audio).
            if kind == .video {
                Button("Add Transition Before This Clip") {
                    model.addTransition(toClipID: clip.id)
                }
                .disabled(!model.canAddTransition(toClipID: clip.id))
            }
            Divider()
            Button("Delete Clip", role: .destructive) {
                model.selectClip(id: clip.id)
                model.deleteSelectedClip()
            }
        }
        .gesture(bodyDragGesture(clip: clip, kind: kind, trackID: trackID, trackIndex: trackIndex, shift: shift))
        .focusable()
        .focused($focusedClipID, equals: clip.id)
        .help(clipName ?? "Clip")
        .accessibilityLabel(nameLabel)
        .accessibilityValue(valueLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Select") {
            selectTimelineClip(clip)
        }
        .accessibilityAction(named: "Split at Playhead") {
            model.selectClip(id: clip.id)
            model.splitSelectedClipAtPlayhead()
        }
        .accessibilityAction(named: "Delete Clip") {
            model.selectClip(id: clip.id)
            model.deleteSelectedClip()
        }
        .onHover { hovering in
            if !hovering { hoverEdge = nil }
        }
        // Move affordance: open hand over the clip body, closed hand while it's
        // being dragged. Declarative `.pointerStyle` is region-based (no NSCursor
        // push/pop stack to unbalance) and coexists with the trim handles, whose
        // edge zones sit on top and show the resize cursor.
        .pointerStyle(isDragging(clip.id) ? .grabActive : .grabIdle)
    }

    private func trimHandle(edge: EditorModel.TrimEdge, clip: Clip, shift: CMTime) -> some View {
        let activeEdge: HoverEdge = edge == .left ? .left(clip.id) : .right(clip.id)
        let isHovered = hoverEdge == activeEdge

        return Rectangle()
            .fill(isHovered ? Color.lcTrimHover : Color.clear)
            .frame(width: edgeZoneWidth)
            .contentShape(Rectangle())
            // Region-based cursor: no NSCursor push/pop stack to unbalance.
            // Previously this used onHover { push() / pop() } + commitDrag's
            // pop(), which had two reproducible imbalance paths (drag bypassed
            // onHover-out → trailing pop ran twice; click-anchored handles
            // skipped onHover entirely on commit). `.pointerStyle` is the
            // declarative replacement that already shipped for ruler/marker
            // cursors (audit P2).
            .pointerStyle(.columnResize)
            .onHover { hovering in
                if hovering {
                    hoverEdge = activeEdge
                } else if hoverEdge == activeEdge {
                    hoverEdge = nil
                }
            }
            .gesture(trimDragGesture(clip: clip, edge: edge, shift: shift))
    }

    // MARK: - Display values with drag offset

    private struct ClipDisplayValues {
        let width: CGFloat
        let x: CGFloat
        let yOffset: CGFloat
        let opacity: Double
    }

    private func clipDisplayValues(_ clip: Clip, trackIndex: Int, shift: CMTime) -> ClipDisplayValues {
        // Authored times are drawn in effective (rippled) coordinates by
        // subtracting this clip's constant ripple shift.
        let shiftSeconds = shift.seconds
        func effectiveX(_ authored: Double) -> CGFloat { CGFloat(authored - shiftSeconds) * pps }

        guard let mode = dragMode else {
            let width = max(CGFloat(clip.outputDuration.seconds) * pps, 2)
            return ClipDisplayValues(width: width, x: effectiveX(clip.timelineStart.seconds), yOffset: 4, opacity: 1)
        }

        switch mode {
        case .trimmingLeft(let id, let candidate) where id == clip.id:
            let displayDuration = clip.timelineEnd - candidate
            let width = max(CGFloat(displayDuration.seconds) * pps, 2)
            return ClipDisplayValues(width: width, x: effectiveX(candidate.seconds), yOffset: 4, opacity: 1)

        case .trimmingRight(let id, let candidate) where id == clip.id:
            let displayDuration = candidate - clip.timelineStart
            let width = max(CGFloat(displayDuration.seconds) * pps, 2)
            return ClipDisplayValues(width: width, x: effectiveX(clip.timelineStart.seconds), yOffset: 4, opacity: 1)

        case .moving(let id, let candidateStart, _, let targetIdx) where id == clip.id:
            let width = max(CGFloat(clip.outputDuration.seconds) * pps, 2)
            let trackDelta = targetIdx - trackIndex
            let yOffset: CGFloat = 4 + CGFloat(trackDelta) * (laneHeight + 1)
            return ClipDisplayValues(width: width, x: effectiveX(candidateStart.seconds), yOffset: yOffset, opacity: 0.7)

        default:
            let width = max(CGFloat(clip.outputDuration.seconds) * pps, 2)
            return ClipDisplayValues(width: width, x: effectiveX(clip.timelineStart.seconds), yOffset: 4, opacity: 1)
        }
    }

    private func isDragging(_ clipID: Clip.ID) -> Bool {
        switch dragMode {
        case .trimmingLeft(let id, _), .trimmingRight(let id, _), .moving(let id, _, _, _):
            id == clipID
        case nil:
            false
        }
    }

    // MARK: - Gestures

    private func trimDragGesture(clip: Clip, edge: EditorModel.TrimEdge, shift: CMTime) -> some Gesture {
        let shiftSeconds = shift.seconds
        return DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Edges are drawn in effective coordinates; convert the dragged
                // position back to authored time by adding the ripple shift.
                let baseX: CGFloat = switch edge {
                case .left: CGFloat(clip.timelineStart.seconds - shiftSeconds) * pps
                case .right: CGFloat(clip.timelineEnd.seconds - shiftSeconds) * pps
                }
                let newX = baseX + value.translation.width
                var candidate = CMTime(seconds: max(0, Double(newX / pps) + shiftSeconds), preferredTimescale: 600)

                // Snap unless Option is held.
                if !NSEvent.modifierFlags.contains(.option) {
                    candidate = model.resolveSnap(candidate: candidate, excluding: clip.id)
                }

                switch edge {
                case .left:
                    candidate = min(candidate, clip.timelineEnd)
                    dragMode = .trimmingLeft(clipID: clip.id, candidate: candidate)
                case .right:
                    candidate = max(candidate, clip.timelineStart)
                    dragMode = .trimmingRight(clipID: clip.id, candidate: candidate)
                }
            }
            .onEnded { _ in
                commitDrag()
            }
    }

    private func bodyDragGesture(clip: Clip, kind: TrackKind, trackID: Track.ID, trackIndex: Int, shift: CMTime) -> some Gesture {
        let shiftSeconds = shift.seconds
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                let originalX = CGFloat(clip.timelineStart.seconds - shiftSeconds) * pps
                let newX = originalX + value.translation.width
                var candidateStart = CMTime(seconds: max(0, Double(newX / pps) + shiftSeconds), preferredTimescale: 600)

                // Constrain vertical drag to same-kind tracks only.
                let trackDelta = Int(round(value.translation.height / (laneHeight + 1)))
                let rawIndex = trackIndex + trackDelta
                let sameKindIndices = tracks.indices.filter { tracks[$0].kind == kind }
                let targetIndex = sameKindIndices.min(by: {
                    abs($0 - rawIndex) < abs($1 - rawIndex)
                }) ?? trackIndex

                if !NSEvent.modifierFlags.contains(.option) {
                    candidateStart = model.resolveSnap(
                        candidate: candidateStart, excluding: clip.id,
                        trailingEdgeOffset: clip.outputDuration)
                }

                dragMode = .moving(clipID: clip.id, candidateStart: candidateStart,
                                   sourceTrackID: trackID, targetTrackIndex: targetIndex)
            }
            .onEnded { _ in
                commitDrag()
            }
    }

    private func captionLineDragGesture(line: CaptionLine, trackID: CaptionTrack.ID) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let originalX = CGFloat(line.range.start.seconds) * pps
                let newX = originalX + value.translation.width
                let candidate = CMTime(seconds: max(0, Double(newX / pps)), preferredTimescale: 600)
                captionDrag = CaptionLineDrag(lineID: line.id, trackID: trackID, candidateStart: candidate)
            }
            .onEnded { _ in
                commitCaptionDrag()
            }
    }

    private func commitDrag() {
        guard let mode = dragMode else { return }
        dragMode = nil

        // Cursor management was moved to declarative `.pointerStyle` on the
        // trim handles, so no NSCursor.pop() is needed here (the old paired
        // pops created two reproducible imbalance paths — see trimHandle).
        switch mode {
        case .trimmingLeft(let id, let candidate):
            model.trimClip(id: id, edge: .left, to: candidate)

        case .trimmingRight(let id, let candidate):
            model.trimClip(id: id, edge: .right, to: candidate)

        case .moving(let id, let candidateStart, _, let targetIndex):
            let targetTrack = tracks[targetIndex]
            model.moveClip(id: id, toTrack: targetTrack.id, start: candidateStart)
        }
    }

    private func commitCaptionDrag() {
        guard let drag = captionDrag else { return }
        captionDrag = nil
        model.retimeCaptionLine(drag.lineID, in: drag.trackID, start: drag.candidateStart)
        model.commitCoalescedUndo()
    }

    /// Choose a tick spacing (seconds) that stays legible at the current zoom.
    private func tickStep() -> Double {
        let targetPixels: CGFloat = 60
        let raw = Double(targetPixels / pps)
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300]
        return candidates.first { $0 >= raw } ?? 600
    }

    // MARK: - Keyboard focus + timeline scrolling

    private var clipFocusCandidates: [ClipFocusCandidate] {
        tracks.enumerated().flatMap { trackIndex, track in
            // Use rippled (effective) start positions so keyboard-focus
            // scroll targets match the drawn clip positions when upstream
            // transitions shift later clips rightward.
            let placements = TransitionLayout.placements(for: track.clips, cuts: transitionCuts)
            let effectiveStarts = Dictionary(uniqueKeysWithValues: placements.map { ($0.clip.id, $0.effectiveStart) })
            return track.clips.map {
                ClipFocusCandidate(id: $0.id,
                                   startSeconds: (effectiveStarts[$0.id] ?? $0.timelineStart).seconds,
                                   trackIndex: trackIndex)
            }
        }
        .sorted {
            if $0.startSeconds == $1.startSeconds {
                return $0.trackIndex < $1.trackIndex
            }
            return $0.startSeconds < $1.startSeconds
        }
    }

    private var timelinePageSeconds: Double {
        TimelineScrollMath.pageSeconds(pps: pps)
    }

    private func selectTimelineClip(_ clip: Clip) {
        model.selectClip(id: clip.id)
        focusedClipID = clip.id
        // Use the rippled (effective) start so projects with upstream
        // transitions don't scroll to the authored position — matches the
        // drawn clip location and keyboard-nav behaviour (Codex P2 on e5cae6b).
        scrollTimelineToClip(id: clip.id)
    }

    private func moveTimelineSelection(_ direction: MoveCommandDirection) {
        let candidates = clipFocusCandidates
        guard !candidates.isEmpty else { return }
        let currentID = focusedClipID ?? model.selectedClipID
        let currentIndex = currentID.flatMap { id in candidates.firstIndex { $0.id == id } }

        let targetIndex: Int? = switch direction {
        case .left, .up:
            currentIndex.map { max(0, $0 - 1) } ?? candidates.count - 1
        case .right, .down:
            currentIndex.map { min(candidates.count - 1, $0 + 1) } ?? 0
        default:
            nil
        }

        guard let targetIndex else { return }
        let target = candidates[targetIndex]
        model.selectClip(id: target.id)
        focusedClipID = target.id
        requestTimelineScroll(to: target.startSeconds)
    }

    private func scrollTimelineToClip(id: Clip.ID) {
        guard let candidate = clipFocusCandidates.first(where: { $0.id == id }) else { return }
        requestTimelineScroll(to: candidate.startSeconds)
    }

    private func scrollTimelinePage(_ direction: Int) {
        // Page from the live viewport centre, not from the last programmatic
        // target — manual trackpad / scrollbar scrolls don't update the target,
        // so this would otherwise jump back to wherever the user last clicked
        // (Codex P2 on d8c7ee2). Math lives in `TimelineScrollMath` so it can
        // be unit-tested without a View context.
        let currentCentre = TimelineScrollMath.viewportCentreSeconds(
            scrollLeadingSeconds: timelineCurrentScrollSeconds,
            viewportWidth: timelineViewportWidth,
            pps: pps)
        requestTimelineScroll(to: currentCentre + Double(direction) * timelinePageSeconds)
    }

    private func requestTimelineScroll(to seconds: Double) {
        timelineScrollTargetSeconds = TimelineScrollMath.clampedTarget(
            seconds, totalDuration: model.totalDuration)
        timelineScrollRequest += 1
    }

}

private struct RulerAccessibilityOverlay: View {
    var model: EditorModel
    var tickStep: Double

    var body: some View {
        Color.clear
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Timeline scrub ruler")
            .accessibilityValue("Playhead \(TimeFormatting.timecode(model.currentTime)) of \(TimeFormatting.timecode(model.totalDuration))")
            .accessibilityHint("Adjust to scrub the playhead")
            .accessibilityAdjustableAction(adjustRulerPlayhead)
    }

    private func adjustRulerPlayhead(_ direction: AccessibilityAdjustmentDirection) {
        let increment: Bool
        switch direction {
        case .increment: increment = true
        case .decrement: increment = false
        @unknown default: return
        }
        guard let target = TimelineScrollMath.rulerAdjustmentTarget(
            currentTime: model.currentTime,
            totalDuration: model.totalDuration,
            tickStep: tickStep,
            increment: increment) else { return }
        model.seek(toSeconds: target)
    }
}

/// Pure scroll-math helpers extracted from `TimelineView` so the page-scroll,
/// viewport-centre, and target-clamp formulas can be unit-tested without a
/// View context (audit P3). Holding them in a top-level enum keeps the View
/// methods one-liners that just delegate.
enum TimelineScrollMath: Sendable {
    /// How many seconds of timeline a single page button advances. Floored at
    /// 5 s so the page step still feels useful when the user is zoomed in.
    static func pageSeconds(pps: CGFloat) -> Double {
        max(5, 640 / max(Double(pps), 1))
    }

    /// Visible duration of the timeline viewport in seconds.
    static func viewportSeconds(viewportWidth: CGFloat, pps: CGFloat) -> Double {
        Double(viewportWidth) / max(Double(pps), 1)
    }

    /// Time at the centre of the visible viewport — `scrollLeadingSeconds`
    /// comes straight from `onScrollGeometryChange` (the leading edge in
    /// seconds), so this is the live position the user actually sees.
    static func viewportCentreSeconds(scrollLeadingSeconds: Double,
                                      viewportWidth: CGFloat,
                                      pps: CGFloat) -> Double {
        scrollLeadingSeconds + viewportSeconds(viewportWidth: viewportWidth, pps: pps) / 2
    }

    /// Clamps a requested target to the project range — negative requests pin
    /// to 0, requests past `totalDuration` pin to the end (or 0 when there is
    /// no content yet).
    static func clampedTarget(_ seconds: Double, totalDuration: Double) -> Double {
        min(max(seconds, 0), max(totalDuration, 0))
    }

    /// Target for one VoiceOver ruler adjustment. Keep the step usable at
    /// extreme zoom levels and never seek outside the project range.
    static func rulerAdjustmentTarget(currentTime: Double,
                                      totalDuration: Double,
                                      tickStep: Double,
                                      increment: Bool) -> Double? {
        guard totalDuration > 0 else { return nil }
        let step = min(max(tickStep, 0.25), 5)
        let target = currentTime + (increment ? step : -step)
        return clampedTarget(target, totalDuration: totalDuration)
    }
}

private struct RulerBackgroundCanvas: View, Equatable {
    let pps: CGFloat
    let rulerHeight: CGFloat
    let tickStep: Double
    let beatMarkersRevision: Int
    let beatMarkers: [ProjectedBeatMarker]

    var body: some View {
        Canvas { context, size in
            let step = tickStep
            guard step > 0, pps > 0 else { return }
            // Ticks sit in the lower half of the ruler so the marker band
            // above them stays visually distinct.
            let tickTop = rulerHeight - 12
            var i = 0
            while true {
                let t = Double(i) * step
                let x = CGFloat(t) * pps
                guard x <= size.width else { break }
                let isMajor = (i % 5 == 0)
                var line = Path()
                line.move(to: CGPoint(x: x, y: isMajor ? tickTop : tickTop + 6))
                line.addLine(to: CGPoint(x: x, y: rulerHeight))
                context.stroke(line, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                if isMajor {
                    let text = Text(TimeFormatting.timecode(t)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    context.draw(text, at: CGPoint(x: x + 2, y: tickTop), anchor: .topLeading)
                }
                i += 1
            }

            // One Path stroked once, not one stroke per marker — long
            // timelines can carry thousands of beats and per-line draw calls
            // dominate scroll cost.
            var beatPath = Path()
            for marker in beatMarkers {
                let x = CGFloat(marker.time.seconds) * pps
                guard x >= 0, x <= size.width else { continue }
                beatPath.move(to: CGPoint(x: x, y: 0))
                beatPath.addLine(to: CGPoint(x: x, y: rulerHeight))
            }
            context.stroke(beatPath, with: .color(.lcBeatMarker), lineWidth: 1)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.pps == rhs.pps,
              lhs.rulerHeight == rhs.rulerHeight,
              lhs.tickStep == rhs.tickStep,
              lhs.beatMarkersRevision == rhs.beatMarkersRevision,
              lhs.beatMarkers.count == rhs.beatMarkers.count
        else { return false }
        // The model increments this revision whenever any input to beat
        // projection changes. It keeps scroll-time equality constant-time while
        // still invalidating for interior beat moves and retimes.
        return true
    }
}

// MARK: - Playhead

private struct ClipIdentityOverlay: View {
    let name: String
    let systemImage: String

    private let repeatEvery: CGFloat = 360

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(labelOffsets(width: proxy.size.width), id: \.self) { offset in
                    label
                        .offset(x: offset)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(name)
                .lineLimit(1)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .foregroundStyle(.primary)
    }

    private func labelOffsets(width: CGFloat) -> [CGFloat] {
        guard width > 0 else { return [] }
        var offsets: [CGFloat] = [6]
        var next = repeatEvery
        while next < width - 20 {
            offsets.append(next)
            next += repeatEvery
        }
        return offsets
    }
}

/// The red scrubber line. Isolated so it can re-evaluate on every
/// `currentTime` tick without invalidating the rest of `TimelineView`.
private struct PlayheadView: View {
    var model: EditorModel
    var pps: CGFloat
    var rulerHeight: CGFloat

    private let headWidth: CGFloat = 11
    private let headHeight: CGFloat = 7
    private let lineWidth: CGFloat = 1.5
    // Grab target around the head: wider than the 11pt triangle so it's an easy
    // hit, and only as tall as the ruler/lane boundary band so it doesn't cover
    // the marker label band above it.
    private let headHitWidth: CGFloat = 22
    private let headHitHeight: CGFloat = 16

    // Playhead time captured when the head drag begins, so we scrub by the
    // gesture's translation (origin-independent — the head is an offset subview).
    @State private var dragStartSeconds: Double?

    var body: some View {
        let x = CGFloat(model.currentTime) * pps
        // Both elements are centred on `x` (the head triangle's midpoint and the
        // line's mid-width), so the head cap sits exactly over the scrub line.
        ZStack(alignment: .topLeading) {
            // Precise scrub line spanning the full timeline height — kept
            // non-interactive so clicks fall through to clips and the ruler.
            Rectangle()
                .fill(.red)
                .frame(width: lineWidth)
                .frame(maxHeight: .infinity)
                .offset(x: x - lineWidth / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Draggable head pinned to the ruler/lane boundary.
            PlayheadHead()
                .fill(.red)
                .frame(width: headWidth, height: headHeight)
                .frame(width: headHitWidth, height: headHitHeight, alignment: .bottom)
                .contentShape(Rectangle())
                .offset(x: x - headHitWidth / 2, y: rulerHeight - headHitHeight)
                .pointerStyle(dragStartSeconds == nil ? .grabIdle : .grabActive)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = dragStartSeconds ?? model.currentTime
                            if dragStartSeconds == nil { dragStartSeconds = start }
                            if model.selectedMarkerID != nil { model.selectedMarkerID = nil }
                            // Fast seek (non-zero tolerance) during drag keeps the
                            // scrub at 60 fps; the precise frame-accurate seek
                            // happens on gesture end below.
                            model.seek(toSeconds: start + Double(value.translation.width / pps),
                                       tolerance: CMTime(seconds: 0.1, preferredTimescale: 600))
                        }
                        .onEnded { value in
                            let start = dragStartSeconds ?? model.currentTime
                            model.seek(toSeconds: start + Double(value.translation.width / pps))
                            dragStartSeconds = nil
                        }
                )
                .help("Drag to scrub")
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Marker glyph + keyboard

/// Small downward playhead marker at the ruler/lane boundary, matching the
/// design-system timeline reference while the vertical red line remains the
/// precise scrub position.
private struct PlayheadHead: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A four-pointed diamond drawn for each marker glyph.
private struct MarkerDiamond: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var p = Path()
        let midX = rect.midX
        let midY = rect.midY
        p.move(to: CGPoint(x: midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: midY))
        p.addLine(to: CGPoint(x: midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: midY))
        p.closeSubpath()
        return p
    }
}

/// Pure shortcut mapping for the focused timeline. SwiftUI's `onKeyPress`
/// gives text fields and focused controls first refusal, so this mapper no
/// longer needs raw key codes, an event monitor, or responder inspection.
enum TimelineShortcutPolicy: Sendable {
    enum Key: Equatable, Sendable {
        case space
        case marker
        case deleteBackward
        case deleteForward
        case other
    }

    enum Action: Equatable {
        /// Pass the key through unchanged.
        case ignore
        /// Space — toggle play/pause.
        case togglePlay
        /// `m` — add a marker at the playhead.
        case addMarker
        /// `Shift+m` — open the rename popover on the selected marker.
        case renameMarker
        /// Try to delete the selected marker; the scoped timeline delete command
        /// remains responsible for clips and transitions when no marker is set.
        case maybeDeleteMarker
    }

    /// SwiftUI deprecated its `.function` convenience flag, while AppKit still
    /// exposes the raw event bit. Keep it passive, together with Caps Lock and
    /// keypad flags, so the focused timeline preserves the former handler's
    /// behavior instead of mistaking those hardware-state flags for commands.
    private static let passiveModifierFlags: EventModifiers = [
        .shift,
        .capsLock,
        .numericPad,
        EventModifiers(rawValue: Int(NSEvent.ModifierFlags.function.rawValue))
    ]

    static func action(for press: KeyPress) -> Action {
        let key: Key
        if press.key == .space {
            key = .space
        } else if press.key == .delete {
            key = .deleteBackward
        } else if press.key == .deleteForward {
            key = .deleteForward
        } else if press.characters == "m" || press.characters == "M" {
            key = .marker
        } else {
            key = .other
        }
        return action(key: key, modifiers: press.modifiers)
    }

    static func action(key: Key, modifiers: EventModifiers = []) -> Action {
        guard modifiers.isSubset(of: passiveModifierFlags) else { return .ignore }
        let shift = modifiers.contains(.shift)
        if key == .space, !shift { return .togglePlay }
        if key == .marker {
            return shift ? .renameMarker : .addMarker
        }
        if key == .deleteBackward || key == .deleteForward {
            return .maybeDeleteMarker
        }
        return .ignore
    }
}
