import SwiftUI
import AVFoundation

/// The multi-track timeline: a time ruler, one lane per track, clip blocks, and a
/// draggable playhead. Zoom is controlled by `model.pixelsPerSecond`.
struct TimelineView: View {
    @Bindable var model: EditorModel

    private let rulerHeight: CGFloat = 24
    private let laneHeight: CGFloat = 56
    private let gutterWidth: CGFloat = 56
    private let edgeZoneWidth: CGFloat = 8

    private var pps: CGFloat { CGFloat(model.pixelsPerSecond) }

    /// Content width in points, with headroom past the last clip.
    private var contentWidth: CGFloat {
        max(CGFloat(model.totalDuration) + 4, 10) * pps
    }

    private var tracks: [Track] {
        model.project.videoTracks + model.project.audioTracks
    }

    // MARK: - Drag state

    enum DragMode: Equatable {
        case trimmingLeft(clipID: Clip.ID, candidate: CMTime)
        case trimmingRight(clipID: Clip.ID, candidate: CMTime)
        case moving(clipID: Clip.ID, candidateStart: CMTime, sourceTrackID: Track.ID, targetTrackIndex: Int)
    }

    @State private var dragMode: DragMode?
    @State private var hoverEdge: HoverEdge?

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
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { trackIndex, track in
                        Divider()
                        lane(for: track, trackIndex: trackIndex)
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

    private func lane(for track: Track, trackIndex: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(track.clips) { clip in
                clipBlock(clip, kind: track.kind, trackID: track.id, trackIndex: trackIndex)
            }
        }
        .frame(height: laneHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Clip block with trim/drag interaction

    private func clipBlock(_ clip: Clip, kind: TrackKind, trackID: Track.ID, trackIndex: Int) -> some View {
        let displayValues = clipDisplayValues(clip, trackIndex: trackIndex)
        let width = displayValues.width
        let x = displayValues.x
        let isSelected = model.selectedClipID == clip.id
        let baseColor: Color = kind == .video ? .blue : .green

        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(baseColor.opacity(isDragging(clip.id) ? 0.2 : 0.35))
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
                                      lineWidth: isSelected ? 2 : 1))

            // Edge zones for trim handles
            HStack(spacing: 0) {
                trimHandle(edge: .left, clip: clip)
                Spacer(minLength: 0)
                trimHandle(edge: .right, clip: clip)
            }
        }
        .frame(width: width, height: laneHeight - 8)
        .offset(x: x, y: displayValues.yOffset)
        .opacity(displayValues.opacity)
        .onTapGesture { model.selectedClipID = clip.id }
        .gesture(bodyDragGesture(clip: clip, kind: kind, trackID: trackID, trackIndex: trackIndex))
        .onHover { hovering in
            if !hovering { hoverEdge = nil }
        }
    }

    private func trimHandle(edge: EditorModel.TrimEdge, clip: Clip) -> some View {
        let isHovered: Bool = switch (edge, hoverEdge) {
        case (.left, .left(clip.id)): true
        case (.right, .right(clip.id)): true
        default: false
        }

        return Rectangle()
            .fill(isHovered ? Color.white.opacity(0.15) : Color.clear)
            .frame(width: edgeZoneWidth)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoverEdge = edge == .left ? .left(clip.id) : .right(clip.id)
                    NSCursor.resizeLeftRight.push()
                } else {
                    if hoverEdge == (edge == .left ? .left(clip.id) : .right(clip.id)) {
                        hoverEdge = nil
                    }
                    NSCursor.pop()
                }
            }
            .gesture(trimDragGesture(clip: clip, edge: edge))
    }

    // MARK: - Display values with drag offset

    private struct ClipDisplayValues {
        let width: CGFloat
        let x: CGFloat
        let yOffset: CGFloat
        let opacity: Double
    }

    private func clipDisplayValues(_ clip: Clip, trackIndex: Int) -> ClipDisplayValues {
        guard let mode = dragMode else {
            let width = max(CGFloat(clip.duration.seconds) * pps, 2)
            let x = CGFloat(clip.timelineStart.seconds) * pps
            return ClipDisplayValues(width: width, x: x, yOffset: 4, opacity: 1)
        }

        switch mode {
        case .trimmingLeft(let id, let candidate) where id == clip.id:
            let candidateEnd = clip.timelineEnd
            let displayStart = candidate
            let displayDuration = candidateEnd - displayStart
            let width = max(CGFloat(displayDuration.seconds) * pps, 2)
            let x = CGFloat(displayStart.seconds) * pps
            return ClipDisplayValues(width: width, x: x, yOffset: 4, opacity: 1)

        case .trimmingRight(let id, let candidate) where id == clip.id:
            let displayDuration = candidate - clip.timelineStart
            let width = max(CGFloat(displayDuration.seconds) * pps, 2)
            let x = CGFloat(clip.timelineStart.seconds) * pps
            return ClipDisplayValues(width: width, x: x, yOffset: 4, opacity: 1)

        case .moving(let id, let candidateStart, _, let targetIdx) where id == clip.id:
            let width = max(CGFloat(clip.duration.seconds) * pps, 2)
            let x = CGFloat(candidateStart.seconds) * pps
            let trackDelta = targetIdx - trackIndex
            let yOffset: CGFloat = 4 + CGFloat(trackDelta) * (laneHeight + 1)
            return ClipDisplayValues(width: width, x: x, yOffset: yOffset, opacity: 0.7)

        default:
            let width = max(CGFloat(clip.duration.seconds) * pps, 2)
            let x = CGFloat(clip.timelineStart.seconds) * pps
            return ClipDisplayValues(width: width, x: x, yOffset: 4, opacity: 1)
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

    private func trimDragGesture(clip: Clip, edge: EditorModel.TrimEdge) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let baseX: CGFloat = switch edge {
                case .left: CGFloat(clip.timelineStart.seconds) * pps
                case .right: CGFloat(clip.timelineEnd.seconds) * pps
                }
                let newX = baseX + value.translation.width
                var candidate = CMTime(seconds: max(0, Double(newX / pps)), preferredTimescale: 600)

                // Snap unless Option is held.
                if !NSEvent.modifierFlags.contains(.option) {
                    candidate = model.resolveSnap(candidate: candidate, excluding: clip.id)
                }

                switch edge {
                case .left:
                    dragMode = .trimmingLeft(clipID: clip.id, candidate: candidate)
                case .right:
                    dragMode = .trimmingRight(clipID: clip.id, candidate: candidate)
                }
            }
            .onEnded { _ in
                commitDrag()
            }
    }

    private func bodyDragGesture(clip: Clip, kind: TrackKind, trackID: Track.ID, trackIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let originalX = CGFloat(clip.timelineStart.seconds) * pps
                let newX = originalX + value.translation.width
                var candidateStart = CMTime(seconds: max(0, Double(newX / pps)), preferredTimescale: 600)

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

    private func commitDrag() {
        guard let mode = dragMode else { return }
        dragMode = nil

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

    // MARK: - Playhead

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
