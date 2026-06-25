import SwiftUI
import AppKit
import AVFoundation
import LocalCutCore

/// The multi-track timeline: a time ruler, one lane per track, clip blocks, and a
/// draggable playhead. Zoom is controlled by `model.pixelsPerSecond`.
struct TimelineView: View {
    @Bindable var model: EditorModel

    private let rulerHeight: CGFloat = 36
    private let laneHeight: CGFloat = 56
    private let gutterWidth: CGFloat = 56
    private let edgeZoneWidth: CGFloat = 8
    private let markerGlyphSize: CGFloat = 12
    @State private var renamingMarkerID: TimelineMarker.ID?
    @State private var renameDraft: String = ""

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

    private struct CaptionLineDrag: Equatable {
        let lineID: CaptionLine.ID
        let trackID: CaptionTrack.ID
        let candidateStart: CMTime
    }

    enum HoverEdge: Equatable {
        case left(Clip.ID)
        case right(Clip.ID)
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
        .background(MarkerKeyHandler(onAdd: { model.addMarkerAtPlayhead() },
                                     onRename: { beginRenamingSelectedMarker() },
                                     onDelete: { deleteSelectedMarkerIfAny() }))
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
    /// selected the existing clip / transition delete shortcut keeps firing.
    @discardableResult
    private func deleteSelectedMarkerIfAny() -> Bool {
        guard let id = model.selectedMarkerID else { return false }
        model.removeMarker(id: id)
        return true
    }

    // MARK: Header

    private var header: some View {
        EditorPanelHeader("Timeline") {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $model.pixelsPerSecond, in: 20...300)
                .frame(width: 140)
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
                .accessibilityElement(children: .combine)
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel(captionTrackAccessibilityLabel(track))
            }
        }
        .frame(width: gutterWidth)
    }

    private func trackAccessibilityLabel(_ track: Track) -> String {
        let kind = track.kind == .video ? "video" : "audio"
        let count = track.clips.count
        let clipLabel = count == 1 ? "1 clip" : "\(count) clips"
        return "\(track.name), \(kind) track, \(clipLabel)"
    }

    private func captionTrackAccessibilityLabel(_ track: CaptionTrack) -> String {
        let count = track.lines.count
        let lineLabel = count == 1 ? "1 caption line" : "\(count) caption lines"
        let muted = track.isMuted ? ", muted" : ""
        return "\(track.name), caption track, \(lineLabel)\(muted)"
    }

    // MARK: Scrollable timeline content

    private var timelineScroller: some View {
        ScrollView([.horizontal]) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ruler
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { trackIndex, track in
                        Divider()
                        lane(for: track, trackIndex: trackIndex)
                    }
                    ForEach(captionTracks) { track in
                        Divider()
                        captionLane(for: track)
                    }
                }
                PlayheadView(model: model, pps: pps)
            }
            .frame(width: contentWidth, alignment: .topLeading)
        }
    }

    private var ruler: some View {
        let markers = model.project.markers
        let beatMarkers = model.showBeatMarkers ? model.projectedBeatMarkers() : []
        let selectedMarkerID = model.selectedMarkerID
        return ZStack(alignment: .topLeading) {
            // Scrub gesture lives on the Canvas — *not* the ZStack — so the
            // marker glyph's `onTapGesture` actually wins on a press that lands
            // on a glyph. `DragGesture(minimumDistance: 0)` on the outer ZStack
            // would otherwise intercept every touch (Gemini review #3).
            Canvas { context, size in
                let step = tickStep()
                // Ticks sit in the lower half of the ruler so the marker band
                // above them stays visually distinct.
                let tickTop = rulerHeight - 12
                var t = 0.0
                while CGFloat(t) * pps <= size.width {
                    let x = CGFloat(t) * pps
                    let isMajor = (t.truncatingRemainder(dividingBy: step * 5) < 0.0001)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: isMajor ? tickTop : tickTop + 6))
                    line.addLine(to: CGPoint(x: x, y: rulerHeight))
                    context.stroke(line, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                    if isMajor {
                        let text = Text(TimeFormatting.timecode(t)).font(.system(size: 9)).foregroundStyle(.secondary)
                        context.draw(text, at: CGPoint(x: x + 2, y: tickTop), anchor: .topLeading)
                    }
                    t += step
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
                context.stroke(beatPath, with: .color(.yellow.opacity(0.65)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(rulerScrubGesture)

            ForEach(markers) { marker in
                markerGlyph(marker, isSelected: marker.id == selectedMarkerID)
            }
        }
        .frame(height: rulerHeight)
    }

    /// Scrub gesture that also clears any marker selection on a fresh press,
    /// so dragging the playhead off the marker band releases focus from a
    /// previously-selected marker. Lives on the Canvas — *not* the parent
    /// ZStack — so marker glyph taps still win when the press lands on a glyph.
    private var rulerScrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if model.selectedMarkerID != nil { model.selectedMarkerID = nil }
                model.seek(toSeconds: Double(value.location.x / pps))
            }
    }

    /// One marker glyph + label drawn at the marker's `time`. The popover
    /// reopens whenever `renamingMarkerID` matches this marker's id.
    ///
    /// Only the diamond glyph is hit-tested (Codex review #4); the floating
    /// label above sits inside a 60pt-wide layout box so it can centre and
    /// overflow neighbouring glyphs visually, but with `allowsHitTesting(false)`
    /// so clicks past the diamond fall through to the ruler scrub gesture
    /// instead of selecting the marker.
    @ViewBuilder
    private func markerGlyph(_ marker: TimelineMarker, isSelected: Bool) -> some View {
        let x = CGFloat(marker.time.seconds) * pps
        let fill: Color = marker.colour.map { Color(cgColor: $0.cgColor) } ?? Color.accentColor
        let strokeColor: Color = isSelected ? .accentColor : .black.opacity(0.4)
        let strokeWidth: CGFloat = isSelected ? 2 : 1
        let labelWidth: CGFloat = 60
        VStack(spacing: 1) {
            Text(marker.name)
                .font(.system(size: 9))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.regularMaterial.opacity(0.8)))
                .frame(width: labelWidth)
                .allowsHitTesting(false)
            MarkerDiamond()
                .fill(fill)
                .overlay(MarkerDiamond().stroke(strokeColor, lineWidth: strokeWidth))
                .frame(width: markerGlyphSize, height: markerGlyphSize)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
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
                .frame(width: 160)
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

    private func lane(for track: Track, trackIndex: Int) -> some View {
        let placements = TransitionLayout.placements(for: track.clips, cuts: transitionCuts)
        let effectiveStarts = Dictionary(uniqueKeysWithValues: placements.map { ($0.clip.id, $0.effectiveStart) })
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedClipID = nil
                    model.selectedTransitionClipID = nil
                    model.selectedMarkerID = nil
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
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedClipID = nil
                    model.selectedTransitionClipID = nil
                    model.selectedMarkerID = nil
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
            .fill(Color.indigo.opacity(captionDrag?.lineID == line.id ? 0.25 : 0.38))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.indigo.opacity(0.75), lineWidth: 1))
            .overlay(alignment: .leading) {
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .foregroundStyle(.primary)
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
                Button("Delete Caption Line", role: .destructive) {
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
                .fill(Color.orange.opacity(isSelected ? 0.5 : 0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.accentColor : Color.orange.opacity(0.8),
                                      lineWidth: isSelected ? 2 : 1))
                .overlay(
                    Image(systemName: type.symbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(.white))
                .frame(width: width, height: laneHeight - 16)
                .offset(x: x, y: 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedClipID = nil
                    model.selectedMediaID = nil
                    model.selectedMarkerID = nil
                    model.selectedTransitionClipID = placement.clip.id
                }
                .accessibilityLabel("\(type.displayName) transition")
                .accessibilityAddTraits(.isButton)
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
        let valueLabel = Text("Starts \(TimeFormatting.timecode(effectiveStart.seconds)), \(TimeFormatting.timecode(clip.duration.seconds)) long")

        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(baseColor.opacity(isDragging(clip.id) ? 0.2 : 0.35))
                .overlay(alignment: .leading) {
                    Text(clipName ?? "Clip")
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .foregroundStyle(.primary)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : baseColor.opacity(0.6),
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
            model.selectedClipID = clip.id
            model.selectedTransitionClipID = nil
            model.selectedMarkerID = nil
        }
        .contextMenu {
            Button("Split at Playhead") {
                model.selectedClipID = clip.id
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
                model.selectedClipID = clip.id
                model.deleteSelectedClip()
            }
        }
        .gesture(bodyDragGesture(clip: clip, kind: kind, trackID: trackID, trackIndex: trackIndex, shift: shift))
        .accessibilityLabel(nameLabel)
        .accessibilityValue(valueLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            if !hovering { hoverEdge = nil }
        }
    }

    private func trimHandle(edge: EditorModel.TrimEdge, clip: Clip, shift: CMTime) -> some View {
        let activeEdge: HoverEdge = edge == .left ? .left(clip.id) : .right(clip.id)
        let isHovered = hoverEdge == activeEdge

        return Rectangle()
            .fill(isHovered ? Color.white.opacity(0.15) : Color.clear)
            .frame(width: edgeZoneWidth)
            .contentShape(Rectangle())
            .onHover { hovering in
                let inTrimDrag: Bool = switch dragMode {
                case .trimmingLeft, .trimmingRight: true
                default: false
                }
                if hovering {
                    hoverEdge = activeEdge
                    if !inTrimDrag { NSCursor.resizeLeftRight.push() }
                } else {
                    if hoverEdge == activeEdge {
                        hoverEdge = nil
                    }
                    if !inTrimDrag { NSCursor.pop() }
                }
            }
            .onDisappear {
                if hoverEdge == activeEdge {
                    hoverEdge = nil
                    NSCursor.pop()
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
            let width = max(CGFloat(clip.duration.seconds) * pps, 2)
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
            let width = max(CGFloat(clip.duration.seconds) * pps, 2)
            let trackDelta = targetIdx - trackIndex
            let yOffset: CGFloat = 4 + CGFloat(trackDelta) * (laneHeight + 1)
            return ClipDisplayValues(width: width, x: effectiveX(candidateStart.seconds), yOffset: yOffset, opacity: 0.7)

        default:
            let width = max(CGFloat(clip.duration.seconds) * pps, 2)
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
                        trailingEdgeOffset: clip.duration)
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

        switch mode {
        case .trimmingLeft(let id, let candidate):
            NSCursor.pop()
            model.trimClip(id: id, edge: .left, to: candidate)

        case .trimmingRight(let id, let candidate):
            NSCursor.pop()
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
}

// MARK: - Playhead

/// The red scrubber line. Isolated so it can re-evaluate on every
/// `currentTime` tick without invalidating the rest of `TimelineView`.
private struct PlayheadView: View {
    var model: EditorModel
    var pps: CGFloat

    var body: some View {
        Rectangle()
            .fill(.red)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .offset(x: CGFloat(model.currentTime) * pps)
            .allowsHitTesting(false)
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

/// AppKit local-event monitor that adds / renames / deletes markers from the
/// timeline keyboard shortcuts. The monitor lives for the lifetime of the
/// timeline view but is scoped two ways: it only fires for events targeted at
/// the *hosting* window (Gemini review #1 — multi-project windows each install
/// their own monitor and must not fight over each other's keys), and it
/// defers to any text-input first responder so typing into caption / inspector
/// fields isn't stolen.
///
/// `Delete` only consumes the event when there is a selected marker — when
/// none is selected, the event falls through to the existing toolbar
/// `.keyboardShortcut(.delete, modifiers: [])` that drives clip / transition
/// deletion. That's the contract the spec calls out (R4.5).
private struct MarkerKeyHandler: NSViewRepresentable {
    let onAdd: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.onAdd = onAdd
        context.coordinator.onRename = onRename
        context.coordinator.onDelete = onDelete
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onAdd = onAdd
        context.coordinator.onRename = onRename
        context.coordinator.onDelete = onDelete
    }

    @MainActor
    final class Coordinator {
        var onAdd: (() -> Void)?
        var onRename: (() -> Void)?
        var onDelete: (() -> Bool)?
        weak var view: NSView?
        // `nonisolated(unsafe)` so `deinit` can clear it without hopping actors;
        // mutation only happens via `install`, called on the main actor, so the
        // unsafety here is a compiler-visible footnote rather than a real race.
        nonisolated(unsafe) private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Read every NSEvent / NSWindow field we need on the delivery
                // queue (.main) *before* entering assumeIsolated. Capturing the
                // non-Sendable NSEvent (or NSWindow) inside the isolated
                // closure would be a Swift 6 "sending risks data races" error,
                // and the return type of `assumeIsolated` must itself be
                // Sendable — so we funnel a `Bool` verdict out and materialise
                // the `NSEvent?` on the way back. (See the matching pattern on
                // the player's endObserver in `EditorModel.init`.)
                let chars = event.charactersIgnoringModifiers ?? ""
                let modifiers = event.modifierFlags
                let keyCode = event.keyCode
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                let consume: Bool = MainActor.assumeIsolated {
                    self?.handle(chars: chars,
                                 modifiers: modifiers,
                                 keyCode: keyCode,
                                 eventWindowID: eventWindowID) ?? false
                }
                return consume ? nil : event
            }
        }

        deinit {
            if let m = monitor {
                DispatchQueue.main.async { NSEvent.removeMonitor(m) }
            }
        }

        /// Returns whether the event should be consumed (true) or passed
        /// through (false). Doing the consume/pass decision as a `Bool` keeps
        /// `NSEvent` out of `MainActor.assumeIsolated`'s Sendable return type;
        /// the inputs are all Sendable primitives extracted at the call site.
        private func handle(chars: String,
                            modifiers: NSEvent.ModifierFlags,
                            keyCode: UInt16,
                            eventWindowID: ObjectIdentifier?) -> Bool {
            // Only fire for events targeted at the timeline's own window.
            // Without this guard, every open project window installs a monitor
            // and the most-recently-active one steals M / Delete keys from
            // whichever window the user is actually typing into (Gemini #1-2).
            guard let hostWindow = view?.window,
                  let eventWindowID,
                  ObjectIdentifier(hostWindow) == eventWindowID else {
                return false
            }
            // Anything other than plain or Shift modifiers (Command/Option/etc.)
            // belongs to a different command; never swallow those.
            let stripped = modifiers
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.shift, .capsLock, .numericPad, .function])
            guard stripped.isEmpty else { return false }
            // Don't steal keys from any first responder that owns a text input
            // (rename popovers, inspector fields, the caption editor).
            if let responder = hostWindow.firstResponder,
               responder is NSText || responder is NSTextField || responder is NSTextView {
                return false
            }

            let shift = modifiers.contains(.shift)
            // Delete / Backspace: only consume when a marker is selected so
            // the existing clip / transition delete shortcut keeps firing.
            let isDelete = (keyCode == 0x33 || keyCode == 0x75)

            if chars == "m" || chars == "M" {
                if shift { onRename?() } else { onAdd?() }
                return true
            }
            if isDelete, onDelete?() == true { return true }
            return false
        }
    }
}
