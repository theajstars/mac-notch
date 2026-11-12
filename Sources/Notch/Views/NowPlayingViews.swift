import AppKit
import SwiftUI

// MARK: - Marquee

/// Single-line text that scrolls only when it doesn't fit: pause at the start, then a smooth
/// constant-speed scroll with one fixed gap before the copy, looping seamlessly.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = .white
    var height: CGFloat = 16
    var speed: CGFloat = 28        // points per second
    var gap: CGFloat = 28
    var pause: Double = 1.5
    /// Where the text sits when it fits (scrolling always starts at the leading edge).
    var alignment: Alignment = .leading
    /// Optional styled version of `text` (e.g. bold sender + dim preview). `text` must hold the same string.
    var styled: Text? = nil

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width
            if textWidth <= available + 0.5 {
                label.frame(width: available, height: height, alignment: alignment)
            } else {
                TimelineView(.animation) { ctx in
                    let travel = textWidth + gap
                    let scroll = Double(travel / speed)
                    let t = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: pause + scroll)
                    let x = t < pause ? 0 : -(CGFloat(t - pause) * speed).rounded(.toNearestOrEven)
                    // Two copies, each laid out at its own natural width; nothing is compressed.
                    ZStack(alignment: .leading) {
                        label.offset(x: x)
                        label.offset(x: x + travel)
                    }
                    .frame(width: available, height: height, alignment: .leading)
                    .clipped()
                    .mask(fadeMask(moving: t >= pause))
                }
            }
        }
        .frame(height: height)
        .background(alignment: .leading) {
            label.hidden().background(GeometryReader { g in
                Color.clear.preference(key: WidthKey.self, value: g.size.width)
            })
        }
        .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        .onChange(of: text) { _, _ in start = Date() }
    }

    @ViewBuilder private var label: some View {
        if let styled {
            styled.font(font).lineLimit(1).fixedSize(horizontal: true, vertical: false)
        } else {
            Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
    }

    private func fadeMask(moving: Bool) -> some View {
        LinearGradient(stops: [
            .init(color: moving ? .clear : .black, location: 0),
            .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.9),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    private struct WidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

// MARK: - Source logos (drawn, no runtime downloads)

struct SourceLogo: View {
    let source: MediaSourceKind?
    var size: CGFloat = 18

    var body: some View {
        Group {
            switch source {
            case .spotify: SpotifyLogo()
            case .youtube: YouTubeLogo()
            case .youtubeMusic: YouTubeMusicLogo()
            default:
                ZStack {
                    Circle().fill(Color.white.opacity(0.18))
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.55, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SpotifyLogo: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s)),
                     with: .color(Color(red: 0.11, green: 0.73, blue: 0.33)))
            func arc(_ y0: CGFloat, _ x0: CGFloat, _ x1: CGFloat, _ lift: CGFloat, _ w: CGFloat) {
                var p = Path()
                p.move(to: CGPoint(x: x0 * s, y: (y0 + 0.035) * s))
                p.addQuadCurve(to: CGPoint(x: x1 * s, y: (y0 + 0.07) * s),
                               control: CGPoint(x: 0.5 * s, y: (y0 - lift) * s))
                ctx.stroke(p, with: .color(.black), style: StrokeStyle(lineWidth: w * s, lineCap: .round))
            }
            arc(0.33, 0.22, 0.79, 0.10, 0.095)
            arc(0.50, 0.26, 0.74, 0.08, 0.078)
            arc(0.655, 0.30, 0.69, 0.06, 0.062)
        }
    }
}

private struct PlayTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct YouTubeLogo: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
                    .fill(Color(red: 1, green: 0, blue: 0))
                    .frame(width: s, height: s * 0.7)
                PlayTriangle().fill(.white)
                    .frame(width: s * 0.27, height: s * 0.3)
                    .offset(x: s * 0.03)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

private struct YouTubeMusicLogo: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(Color(red: 1, green: 0, blue: 0))
                Circle().stroke(.white, lineWidth: s * 0.065).frame(width: s * 0.6, height: s * 0.6)
                PlayTriangle().fill(.white)
                    .frame(width: s * 0.2, height: s * 0.24)
                    .offset(x: s * 0.025)
            }
            .frame(width: s, height: s)
        }
    }
}

// MARK: - Artwork

struct ArtworkView: View {
    let image: NSImage?
    var size: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Little animated level bars shown while playing.
struct PlayingBars: View {
    let playing: Bool
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = sin(t * (5 + Double(i) * 1.7) + Double(i) * 1.3)
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: playing ? 4 + 8 * CGFloat((phase + 1) / 2) : 3)
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - Compact (closed notch) player

/// Dynamic-Island sized: album art in the left wing, source logo in the right wing. When lyrics
/// are on, the current line sits in a slim strip under the notch (same width).
struct CompactMusicView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var player: NowPlayingService
    @ObservedObject var lyrics: LyricsService

    var body: some View {
        let g = vm.geometry
        let h = g.notchSize.height
        let (left, right) = vm.wings
        if let info = player.info {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ArtworkView(image: info.artwork, size: h - 12, corner: 5)
                        .frame(width: left)
                    Color.clear.frame(width: vm.gapWidth)
                    SourceLogo(source: player.source, size: min(20, h - 14))
                        .frame(width: right)
                }
                .frame(height: h)
                if vm.showsLyricStrip {
                    LyricStripView(lyrics: lyrics)
                        .padding(.horizontal, 10)
                        .frame(height: NotchViewModel.lyricStripHeight - 4, alignment: .top)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, vm.topRadius)
        }
    }
}

// MARK: - Player with controls (hover card + expanded panel)

struct PlayerControlsView: View {
    @ObservedObject var player: NowPlayingService
    var artSize: CGFloat = 64

    var body: some View {
        if let info = player.info {
            HStack(alignment: .center, spacing: 14) {
                ArtworkView(image: info.artwork, size: artSize, corner: 10)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            MarqueeText(text: info.title, font: .system(size: 13, weight: .semibold), height: 17)
                            MarqueeText(text: info.artist.isEmpty ? (player.source?.displayName ?? "") : info.artist,
                                        font: .system(size: 11.5), color: .white.opacity(0.65), height: 15)
                        }
                        SourceLogo(source: player.source, size: 18)
                    }
                    ProgressRow(info: info, onSeek: { player.seek(to: $0) })
                    HStack(spacing: 22) {
                        Spacer(minLength: 0)
                        controlButton("backward.fill", size: 14) { player.send(.previous) }
                        controlButton(info.isPlaying ? "pause.fill" : "play.fill", size: 20) {
                            player.send(.togglePlayPause)
                        }
                        controlButton("forward.fill", size: 14) { player.send(.next) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// Elapsed / bar / duration. Drag (or click) the bar to seek when `onSeek` is set.
struct ProgressRow: View {
    let info: NowPlayingInfo
    var onSeek: ((Double) -> Void)? = nil
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = info.elapsed(at: ctx.date)
            let live = info.duration > 0 ? min(1, elapsed / info.duration) : 0
            let fraction = dragFraction ?? live
            let scrubbing = dragFraction != nil
            HStack(spacing: 8) {
                Text((dragFraction.map { $0 * info.duration } ?? elapsed).mmss).monospacedDigit()
                    .foregroundStyle(.white.opacity(scrubbing ? 0.9 : 0.55))
                GeometryReader { g in
                    let barHeight: CGFloat = scrubbing ? 6 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18)).frame(height: barHeight)
                        Capsule().fill(.white).frame(width: max(barHeight, g.size.width * fraction), height: barHeight)
                    }
                    .frame(width: g.size.width, height: g.size.height)
                    .contentShape(Rectangle())
                    .gesture(seekGesture(width: g.size.width))
                    .animation(.easeOut(duration: 0.12), value: scrubbing)
                }
                .frame(height: 12)
                Text(info.duration > 0 ? info.duration.mmss : "--:--").monospacedDigit()
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard onSeek != nil, info.duration > 0, width > 0 else { return }
                dragFraction = min(1, max(0, Double(v.location.x / width)))
            }
            .onEnded { v in
                guard let onSeek, info.duration > 0, width > 0 else { dragFraction = nil; return }
                let f = min(1, max(0, Double(v.location.x / width)))
                onSeek(f * info.duration)
                dragFraction = nil
            }
    }
}

/// Hover panel while media is playing: a pinned recent notification (if any), a compact player,
/// lyrics (only when synced lyrics exist) and the recent notifications list. Notifications are
/// never hidden behind the player.
struct MusicPeekView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var player: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var store: NotificationStore

    var body: some View {
        let g = vm.geometry
        let side = (vm.shapeSize.width - vm.gapWidth) / 2 - vm.topRadius - 16
        VStack(alignment: .leading, spacing: 0) {
            // Top band beside the camera housing.
            HStack(spacing: 0) {
                Text("Now Playing").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: side, alignment: .leading)
                Spacer(minLength: 0)
                Group {
                    if case .synced = lyrics.state, vm.settings.showLyrics {
                        LyricsTimingControl(lyrics: lyrics)
                    } else {
                        Text(player.source?.displayName ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .frame(width: side, alignment: .trailing)
            }
            .frame(height: g.notchSize.height)

            if let n = vm.peekHighlight {
                PinnedNotificationCard(notification: n)
                    .onTapGesture(count: 2) { vm.open(n) }
                    .onTapGesture { vm.expand(selecting: n.id) }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            CompactPlayerRow(player: player)
                .padding(.top, 4)

            if case .synced = lyrics.state, vm.settings.showLyrics {
                LyricsContextView(lyrics: lyrics)
                    .padding(.top, 8)
            }

            // Notifications are always listed under the player.
            // Count in a pill beside the title; "View all" opens the full list on the Notifications tab.
            HStack(spacing: 6) {
                Text("Notifications").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                let count = store.visibleHistory.count
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                Spacer()
                if count > 0 {
                    Button { vm.expand(tab: .notifications) } label: {
                        HStack(spacing: 2) {
                            Text("View all")
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open all notifications")
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 4)

            if store.visibleHistory.isEmpty {
                Text("No notifications").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .frame(height: 22)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(store.visibleHistory) { n in
                            NotificationListRow(notification: n)
                                .frame(height: NotchViewModel.peekRowHeight)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { vm.open(n) }
                                .onTapGesture { vm.expand(selecting: n.id) }
                        }
                    }
                }
                .frame(height: CGFloat(min(store.visibleHistory.count, NotchViewModel.peekListLimit)) * NotchViewModel.peekRowHeight)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, vm.topRadius + 16)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.25), value: vm.peekHighlight?.id)
    }
}

/// Art + title/artist + small controls on one row, progress underneath.
struct CompactPlayerRow: View {
    @ObservedObject var player: NowPlayingService

    var body: some View {
        if let info = player.info {
            HStack(alignment: .center, spacing: 10) {
                ArtworkView(image: info.artwork, size: 44, corner: 7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            MarqueeText(text: info.title, font: .system(size: 12.5, weight: .semibold), height: 16)
                            MarqueeText(text: info.artist.isEmpty ? (player.source?.displayName ?? "") : info.artist,
                                        font: .system(size: 11), color: .white.opacity(0.6), height: 14)
                        }
                        HStack(spacing: 2) {
                            smallButton("backward.fill", 11) { player.send(.previous) }
                            smallButton(info.isPlaying ? "pause.fill" : "play.fill", 15) { player.send(.togglePlayPause) }
                            smallButton("forward.fill", 11) { player.send(.next) }
                        }
                    }
                    ProgressRow(info: info, onSeek: { player.seek(to: $0) })
                }
            }
            .frame(height: 56)
        }
    }

    private func smallButton(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// One notification in a list: icon, "Sender - preview", relative time.
struct NotificationListRow: View {
    let notification: NotchNotification

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(bundleID: notification.bundleID, size: 18)
            CompactView.styled(notification.stripParts)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(notification.date.notchRelative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 6)
    }
}

/// The just-arrived notification, pinned above the player.
struct PinnedNotificationCard: View {
    let notification: NotchNotification

    var body: some View {
        let parts = notification.stripParts
        HStack(alignment: .top, spacing: 10) {
            AppIconView(bundleID: notification.bundleID, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(parts.primary).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(notification.date.notchRelative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
                Text(NotchNotification.oneLine([notification.subtitle, notification.body]
                        .filter { !$0.isEmpty }.joined(separator: " · ")))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(height: 70, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)))
        .contentShape(Rectangle())
    }
}
