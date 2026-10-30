import AppKit
import SwiftUI

/// Lets the first click on a button work even though the app is never "active".
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Root

@MainActor
struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let layout = model.layout
        VStack(spacing: 0) {
            IslandContainer(model: model, mode: model.mode, layout: layout)
            Spacer(minLength: 0)
        }
        .padding(.top, layout.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
struct IslandContainer: View {
    @ObservedObject var model: IslandModel
    let mode: IslandMode
    let layout: IslandLayout

    var body: some View {
        let size = layout.size(for: mode)
        let shape = IslandShape(topRadius: layout.topRadius(for: mode),
                                bottomRadius: layout.bottomRadius(for: mode),
                                shoulder: layout.shoulder)

        ZStack {
            shape.fill(Color.black)
            content
                .padding(.horizontal, layout.shoulder)
                .transition(.asymmetric(
                    insertion: AnyTransition.opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
                    removal: AnyTransition.opacity.animation(.easeIn(duration: 0.08))))
                .id(mode.contentKey)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: Color.black.opacity(mode.isExpanded ? 0.35 : 0), radius: 14, x: 0, y: 6)
        .opacity(mode == .hidden ? 0 : 1)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: layout)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .hidden:
            Color.clear
        case .idle:
            if layout.hasNotch {
                StatusEarsView(model: model, layout: layout)
            } else if model.mascot != .off {
                MascotView(model: model, size: 17)
            } else {
                Color.clear
            }
        case .music:
            CompactMusicView(model: model, layout: layout)
        case .peek:
            PeekMusicView(model: model, layout: layout)
        case .focus:
            FocusCompactView(model: model, layout: layout)
        case .prayer(let alert):
            PrayerCompactView(alert: alert, layout: layout)
        case .meeting(let alert):
            MeetingCompactView(alert: alert, layout: layout)
        case .notice(let notice):
            NoticeView(notice: notice, layout: layout)
        case .expanded:
            ExpandedView(model: model, layout: layout)
        }
    }
}

// MARK: - Compact states

/// At rest on a notched screen: mascot (or battery) left of the camera, clock right of it.
@MainActor
struct StatusEarsView: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if model.mascot != .off {
                    MascotView(model: model, size: 24)
                } else if let battery = model.battery {
                    HStack(spacing: 3) {
                        Image(systemName: BatteryBadge.symbol(for: battery))
                            .font(.system(size: 12))
                            .foregroundColor(BatteryBadge.tint(for: battery))
                        Text("\(battery.percent)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(Color.white.opacity(0.85))
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: IslandLayout.wing)

            Spacer(minLength: layout.notchWidth)   // nothing under the camera

            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: IslandLayout.wing)
        }
    }
}

@MainActor
struct CompactMusicView: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        let isPlaying = model.track?.isPlaying ?? false
        if layout.hasNotch {
            // Artwork in the left ear, (dancing mascot +) equalizer in the right ear, camera in between.
            HStack(spacing: 0) {
                ArtworkView(image: model.artwork, size: 22, radius: 6)
                    .frame(width: IslandLayout.wing)
                Spacer(minLength: layout.notchWidth)
                HStack(spacing: 5) {
                    if model.mascot != .off {
                        MascotView(model: model, size: 21)
                    }
                    EqualizerView(isPlaying: isPlaying, color: model.accent, height: model.mascot != .off ? 12 : 14)
                }
                .frame(width: IslandLayout.wing)
            }
        } else {
            HStack(spacing: 0) {
                ArtworkView(image: model.artwork, size: 18, radius: 5)
                Spacer(minLength: 8)
                if model.mascot != .off {
                    MascotView(model: model, size: 18)
                        .padding(.trailing, 4)
                }
                EqualizerView(isPlaying: isPlaying, color: model.accent, height: 13)
            }
            .padding(.leading, 5)
            .padding(.trailing, 11)
        }
    }
}

@MainActor
struct PeekMusicView: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        if layout.hasNotch {
            // Same ears as the compact island, plus the title just below the camera.
            VStack(spacing: 0) {
                CompactMusicView(model: model, layout: layout)
                    .frame(height: layout.notchHeight)
                Text(model.track?.title ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                ArtworkView(image: model.artwork, size: 22, radius: 6)
                Text(model.track?.title ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                EqualizerView(isPlaying: model.track?.isPlaying ?? false, color: model.accent, height: 14)
            }
            .padding(.leading, 4)
            .padding(.trailing, 13)
        }
    }
}

struct NoticeView: View {
    let notice: IslandNotice
    let layout: IslandLayout

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(notice.tint.color)
                .frame(width: 18)
            Text(notice.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            // With a notch: title in the left ear, value in the right ear.
            Spacer(minLength: layout.hasNotch ? layout.notchWidth + 12 : 6)
            if let level = notice.level {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(4, 54 * CGFloat(min(1, max(0, level)))))
                }
                .frame(width: 54, height: 4)
            }
            Text(notice.detail)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(notice.tint.color)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Expanded states

/// Top row of the open island on a notched screen: mascot + clock left of the camera, battery right.
@MainActor
struct OpenStatusRow: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        HStack(spacing: 0) {
            if model.mascot != .off {
                MascotView(model: model, size: 22)
                    .padding(.trailing, 4)
            }
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(Color.white.opacity(0.85))
            }
            Spacer(minLength: layout.notchWidth + 16)
            if let battery = model.battery {
                HStack(spacing: 4) {
                    Text("\(battery.percent)%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color.white.opacity(0.85))
                    Image(systemName: BatteryBadge.symbol(for: battery))
                        .font(.system(size: 13))
                        .foregroundColor(BatteryBadge.tint(for: battery))
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: layout.notchHeight)
    }
}

/// "Musik" tab of the open island.
@MainActor
struct MusicTabView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let track = model.track {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button(action: { model.player?.openPlayerApp() }) {
                        ArtworkView(image: model.artwork, size: 54, radius: 12)
                    }
                    .buttonStyle(PressScaleStyle())
                    .help("Buka \(track.source.displayName)")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title.isEmpty ? "Tanpa judul" : track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.6))
                            .lineLimit(1)
                        Text(track.source.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.35))
                    }

                    Spacer(minLength: 8)

                    EqualizerView(isPlaying: track.isPlaying, color: model.accent, height: 16)
                }

                ProgressRow(track: track, sampledAt: model.sampledAt, tint: model.accent)

                if model.automationDenied {
                    Text("Izinkan Automation di System Settings agar tombol kontrol aktif")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(height: 28)
                } else {
                    HStack(spacing: 34) {
                        IslandButton(symbol: "backward.fill", size: 15) { model.player?.previous() }
                        IslandButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 20) { model.player?.playPause() }
                        IslandButton(symbol: "forward.fill", size: 15) { model.player?.next() }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        } else {
            HStack(alignment: .center, spacing: 12) {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.55))
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundColor(.white)
                        Text("Belum ada lagu dari Spotify atau Apple Music")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.4))
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                if let battery = model.battery {
                    BatteryBadge(battery: battery)
                }
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Building blocks

/// The island's outline.
/// - Pill: rounded rectangle with `topRadius` / `bottomRadius`.
/// - Around a notch: flat top with small outward "shoulders" (concave curves) where it
///   meets the bezel, like the hardware notch, and rounded bottom corners.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var shoulder: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), shoulder) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            shoulder = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4, rect.height / 2))
        let body = rect.insetBy(dx: s, dy: 0)
        let limit = min(body.width, body.height) / 2
        let t = s > 0 ? 0 : max(0, min(topRadius, limit))
        let b = max(0, min(bottomRadius, limit))

        var path = Path()
        if s > 0 {
            // Top edge spans the full rect; the shoulders curve down into the body.
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: body.maxX, y: rect.minY + s),
                              control: CGPoint(x: body.maxX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: body.minX + t, y: body.minY))
            path.addLine(to: CGPoint(x: body.maxX - t, y: body.minY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                        tangent2End: CGPoint(x: body.maxX, y: body.minY + t),
                        radius: t)
        }
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - b))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                    tangent2End: CGPoint(x: body.maxX - b, y: body.maxY),
                    radius: b)
        path.addLine(to: CGPoint(x: body.minX + b, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX, y: body.maxY - b),
                    radius: b)
        if s > 0 {
            path.addLine(to: CGPoint(x: body.minX, y: rect.minY + s))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                              control: CGPoint(x: body.minX, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: body.minX, y: body.minY + t))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                        tangent2End: CGPoint(x: body.minX + t, y: body.minY),
                        radius: t)
        }
        path.closeSubpath()
        return path
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.30), Color(white: 0.16)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Little animated bars, tinted with the album-art colour.
struct EqualizerView: View {
    let isPlaying: Bool
    let color: Color
    let height: CGFloat

    private let barCount = 4
    private let barWidth: CGFloat = 2.6
    private let spacing: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: barHeight(index: index, time: time))
                }
            }
            .frame(height: height)
        }
        .frame(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing, height: height)
    }

    private func barHeight(index: Int, time: Double) -> CGFloat {
        let minimum: CGFloat = 3
        guard isPlaying else { return minimum }
        let i = Double(index)
        let a = abs(sin(time * (6.0 + i * 1.7) + i * 1.3))
        let b = abs(sin(time * (3.1 + i * 0.9) + i * 2.1))
        let level = a * 0.65 + b * 0.35
        return minimum + CGFloat(level) * (height - minimum)
    }
}

struct ProgressRow: View {
    let track: TrackInfo
    let sampledAt: Date
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let elapsed = track.isPlaying ? context.date.timeIntervalSince(sampledAt) : 0
            let position = track.duration > 0
                ? min(track.duration, max(0, track.position + elapsed))
                : max(0, track.position + elapsed)
            let fraction = track.duration > 0 ? position / track.duration : 0

            HStack(spacing: 8) {
                Text(format(position))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.white.opacity(0.55))
                    .frame(width: 34, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                    }
                }
                .frame(height: 4)

                Text(track.duration > 0 ? "-" + format(track.duration - position) : "")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.white.opacity(0.55))
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .frame(height: 14)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct BatteryBadge: View {
    let battery: BatteryState

    var body: some View {
        HStack(spacing: 6) {
            Text("\(battery.percent)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
            Image(systemName: BatteryBadge.symbol(for: battery))
                .font(.system(size: 22))
                .foregroundColor(BatteryBadge.tint(for: battery))
        }
    }

    static func symbol(for battery: BatteryState) -> String {
        if battery.isPluggedIn { return "battery.100.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    static func tint(for battery: BatteryState) -> Color {
        if battery.isPluggedIn { return NoticeTint.green.color }
        if battery.percent <= 20 { return NoticeTint.red.color }
        return .white
    }
}

struct IslandButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
