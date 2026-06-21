import SwiftUI
import AVFoundation

/// The multi-track timeline: a time ruler, one lane per track, clip blocks, and a
/// draggable playhead. Zoom is controlled by `model.pixelsPerSecond`.
struct TimelineView: View {
    @Bindable var model: EditorModel

    private let rulerHeight: CGFloat = 24
    private let laneHeight: CGFloat = 56
    private let gutterWidth: CGFloat = 56

    private var pps: CGFloat { CGFloat(model.pixelsPerSecond) }

    /// Content width in points, with headroom past the last clip.
    private var contentWidth: CGFloat {
        max(CGFloat(model.totalDuration) + 4, 10) * pps
    }

    private var tracks: [Track] {
        model.project.videoTracks + model.project.audioTracks
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

    private func clipBlock(_ clip: Clip, kind: TrackKind) -> some View {
        let width = max(CGFloat(clip.duration.seconds) * pps, 2)
        let x = CGFloat(clip.timelineStart.seconds) * pps
        let isSelected = model.selectedClipID == clip.id
        let baseColor: Color = kind == .video ? .blue : .green

        return RoundedRectangle(cornerRadius: 6)
            .fill(baseColor.opacity(0.35))
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
            .frame(width: width, height: laneHeight - 8)
            .offset(x: x, y: 4)
            .onTapGesture { model.selectedClipID = clip.id }
    }

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
