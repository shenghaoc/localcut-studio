import SwiftUI
import AVFoundation
import AppKit

/// The multi-track timeline: a time ruler, one lane per track, clip blocks, and a
/// draggable playhead. Zoom is controlled by `model.pixelsPerSecond`.
struct TimelineView: View {
    @Bindable var model: EditorModel

    private let rulerHeight: CGFloat = 24
    private let laneHeight: CGFloat = 56
    private let gutterWidth: CGFloat = 56
    private let edgeHitZone: CGFloat = 8
    private let snapPixelThreshold: CGFloat = 8

    private var pps: CGFloat { CGFloat(model.pixelsPerSecond) }

    /// Content width in points, with headroom past the last clip.
    private var contentWidth: CGFloat {
        max(CGFloat(model.totalDuration) + 4, 10) * pps
    }

    private var tracks: [Track] {
        model.project.videoTracks + model.project.audioTracks
    }

    @State private var dragState: DragState?
    @State private var isCursorPushed = false
    @State private var isHoveringEdge = false

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
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Timeline").font(.headline)
            Spacer()
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: $model.pixelsPerSecond, in: 20...300)
                .frame(width: 140)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            }
        }
        .frame(width: gutterWidth)
    }

    // MARK: Scrollable timeline content

    private var timelineScroller: some View {
        ScrollView([.horizontal]) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ruler
                    ForEach(tracks) { track in
                        Divider()
                        lane(for: track)
                    }
                }
                playhead
            }
            .frame(width: contentWidth, alignment: .topLeading)
        }
    }

    private var ruler: some View {
        Canvas { context, size in
            let step = tickStep()
            var t = 0.0
            while CGFloat(t) * pps <= size.width {
                let x = CGFloat(t) * pps
                let isMajor = (t.truncatingRemainder(dividingBy: step * 5) < 0.0001)
                var line = Path()
                line.move(to: CGPoint(x: x, y: isMajor ? 6 : 12))
                line.addLine(to: CGPoint(x: x, y: rulerHeight))
                context.stroke(line, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                if isMajor {
                    let text = Text(TimeFormatting.timecode(t)).font(.system(size: 9)).foregroundStyle(.secondary)
                    context.draw(text, at: CGPoint(x: x + 2, y: 6), anchor: .topLeading)
                }
                t += step
            }
        }
        .frame(height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.seek(toSeconds: Double(value.location.x / pps))
                }
        )
    }

    private func lane(for track: Track) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(track.clips) { clip in
                clipBlock(clip, kind: track.kind)
            }
        }
        .frame(height: laneHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Clip block with drag gesture

    private func clipBlock(_ clip: Clip, kind: TrackKind) -> some View {
        let baseWidth = max(CGFloat(clip.duration.seconds) * pps, 2)
        let baseX = CGFloat(clip.timelineStart.seconds) * pps
        let isSelected = model.selectedClipID == clip.id
        let baseColor: Color = kind == .video ? .blue : .green

        let isBeingDragged = dragState?.clipID == clip.id
        let visualX: CGFloat
        let visualWidth: CGFloat
        if let state = dragState, state.clipID == clip.id {
            switch state.kind {
            case .trimmingLeft:
                let deltaTime = state.translation.width / pps
                visualX = baseX + deltaTime
                visualWidth = max(baseWidth - deltaTime, 2)
            case .trimmingRight:
                visualWidth = max(baseWidth + state.translation.width / pps, 2)
                visualX = baseX
            case .moving:
                visualX = baseX + state.translation.width / pps
                visualWidth = baseWidth
            }
        } else {
            visualX = baseX
            visualWidth = baseWidth
        }

        let dragOpacity: Double = isBeingDragged ? 0.75 : 1
        let dragShadow: CGFloat = isBeingDragged ? 4 : 0

        return RoundedRectangle(cornerRadius: 6)
            .fill(baseColor.opacity(0.35 * dragOpacity))
            .overlay(alignment: .leading) {
                Text(model.project.media(for: clip.mediaID)?.name ?? "Clip")
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .foregroundStyle(.primary)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : baseColor.opacity(0.6),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .frame(width: visualWidth, height: laneHeight - 8)
            .offset(x: visualX, y: 4)
            .shadow(radius: dragShadow)
            .onTapGesture { model.selectedClipID = clip.id }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if dragState == nil {
                            let kind: DragState.Kind
                            if value.startLocation.x < edgeHitZone {
                                kind = .trimmingLeft
                            } else if value.startLocation.x > baseWidth - edgeHitZone {
                                kind = .trimmingRight
                            } else {
                                kind = .moving
                            }
                            dragState = DragState(
                                kind: kind,
                                clipID: clip.id,
                                initialTimelineStart: clip.timelineStart,
                                initialSourceStart: clip.sourceStart,
                                initialDuration: clip.duration,
                                translation: value.translation)
                        } else {
                            dragState?.translation = value.translation
                        }
                    }
                    .onEnded { value in
                        commitDrag(finalLocation: value.location, at: value.translation)
                    }
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                handleHover(phase, clipWidth: baseWidth)
            }
    }

    // MARK: - Drag commit

    private func commitDrag(finalLocation location: CGPoint, at translation: CGSize) {
        guard let state = dragState else { return }
        defer { dragState = nil }

        let snapThreshold = Double(snapPixelThreshold / pps)
        let snapEnabled = !NSEvent.modifierFlags.contains(.option)

        switch state.kind {
        case .trimmingLeft:
            let deltaTime = translation.width / pps
            let rawTimelineStart = state.initialTimelineStart + CMTime(seconds: Double(deltaTime), preferredTimescale: 600)
            let final = snapEnabled
                ? model.resolveSnap(candidate: rawTimelineStart, thresholdSeconds: snapThreshold)
                : rawTimelineStart
            model.trimClip(id: state.clipID, edge: .left, to: final)

        case .trimmingRight:
            let deltaTime = translation.width / pps
            let rawTimelineEnd = state.initialTimelineStart + state.initialDuration + CMTime(seconds: Double(deltaTime), preferredTimescale: 600)
            let final = snapEnabled
                ? model.resolveSnap(candidate: rawTimelineEnd, thresholdSeconds: snapThreshold)
                : rawTimelineEnd
            model.trimClip(id: state.clipID, edge: .right, to: final)

        case .moving:
            let deltaTime = translation.width / pps
            let rawStart = state.initialTimelineStart + CMTime(seconds: Double(deltaTime), preferredTimescale: 600)
            let snapped = snapEnabled
                ? model.resolveSnap(candidate: rawStart, thresholdSeconds: snapThreshold)
                : rawStart

            // Determine target track index from the final Y location.
            let allTracks = model.project.videoTracks + model.project.audioTracks
            let laneY = location.y - rulerHeight
            let rawTrackIndex = max(0, min(allTracks.count - 1, Int(laneY / laneHeight)))

            // Map to same-kind track index.
            let targetTrack = allTracks[rawTrackIndex]
            let sameKindTracks: [Track] = targetTrack.kind == .video ? model.project.videoTracks : model.project.audioTracks
            let sameKindIndex = sameKindTracks.firstIndex { $0.id == targetTrack.id } ?? 0

            model.moveClip(id: state.clipID, toTrackIndex: sameKindIndex, start: snapped)
        }
    }

    // MARK: - Hover cursor

    private func handleHover(_ phase: HoverPhase, clipWidth: CGFloat) {
        switch phase {
        case .active(let point):
            let onEdge = point.x < edgeHitZone || point.x > clipWidth - edgeHitZone
            if onEdge != isHoveringEdge {
                if isCursorPushed { NSCursor.pop(); isCursorPushed = false }
                isHoveringEdge = onEdge
                if onEdge {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.openHand.push()
                }
                isCursorPushed = true
            }
        case .ended:
            if isCursorPushed { NSCursor.pop(); isCursorPushed = false }
            isHoveringEdge = false
        }
    }

    // MARK: Playhead

    private var playhead: some View {
        let x = CGFloat(model.currentTime) * pps
        return Rectangle()
            .fill(Color.red)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .offset(x: x)
            .allowsHitTesting(false)
    }

    /// Choose a tick spacing (seconds) that stays legible at the current zoom.
    private func tickStep() -> Double {
        let targetPixels: CGFloat = 60
        let raw = Double(targetPixels / pps)
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300]
        return candidates.first { $0 >= raw } ?? 600
    }
}

// MARK: - Drag state

private struct DragState {
    let kind: Kind
    let clipID: Clip.ID
    let initialTimelineStart: CMTime
    let initialSourceStart: CMTime
    let initialDuration: CMTime
    var translation: CGSize

    enum Kind {
        case trimmingLeft, trimmingRight, moving
    }
}
