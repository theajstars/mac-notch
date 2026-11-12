import AppKit
import SwiftUI

/// Click state, with two pages:
/// - Home: whatever is going on (call, now playing + lyrics, or a clock), battery, recent notifications.
/// - Notifications: recent list grouped by app on the left, full detail with actions on the right.
struct ExpandedView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var store: NotificationStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var player: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var calls: CallMonitor
    @ObservedObject var power: PowerMonitor
    @State private var copiedID: String?

    private struct AppGroup: Identifiable {
        let bundleID: String
        let items: [NotchNotification]
        var id: String { bundleID }
    }

    private var groups: [AppGroup] {
        var order: [String] = []
        var map: [String: [NotchNotification]] = [:]
        for n in store.visibleHistory {
            let key = n.bundleID.lowercased()
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(n)
        }
        return order.map { AppGroup(bundleID: map[$0]![0].bundleID, items: map[$0]!) }
    }

    private var selected: NotchNotification? {
        let all = store.visibleHistory
        return all.first { $0.id == vm.selectedID } ?? all.first
    }

    /// Media is shown only while something is actually playing (or just paused).
    private var hasActiveMedia: Bool { player.hasSession && player.showInNotch && player.info != nil }
    private var activeCall: ActiveCall? { settings.showCalls ? calls.call : nil }

    var body: some View {
        let g = vm.geometry
        let sideWidth = (vm.shapeSize.width - vm.gapWidth) / 2 - vm.topRadius - 18
        VStack(spacing: 0) {
            // Top band beside the camera housing.
            HStack(spacing: 0) {
                // With four tabs, "Notifications" plus its count is wider than the space beside the
                // camera and slid under it; then the selected tab drops its title (kept as tooltip).
                ViewThatFits(in: .horizontal) {
                    tabRow(titled: true)
                    tabRow(titled: false)
                }
                .frame(width: sideWidth, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    if vm.expandedTab == .notifications {
                        iconButton("trash", help: "Clear all") { store.clearAll() }
                            .disabled(store.visibleHistory.isEmpty)
                    }
                    iconButton("gearshape", help: "Settings") { vm.openSettings() }
                    iconButton("chevron.up", help: "Close") { vm.collapse() }
                }
                .frame(width: sideWidth)
            }
            .frame(height: max(g.notchSize.height, 28))

            if store.status.needsFullDiskAccess {
                FullDiskAccessPrompt(action: vm.openFullDiskAccess)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.18)))
                    .padding(.top, 6)
            }

            Group {
                switch vm.expandedTab {
                case .home: home
                case .devices: DevicesPage(vm: vm, settings: settings, calls: calls)
                case .shelf: ShelfPage(vm: vm, shelf: vm.launcher.shelf)
                case .notifications: notifications
                }
            }
            .transition(.opacity)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, vm.topRadius + 16)
        .padding(.bottom, 16)
    }

    private func tabRow(titled: Bool) -> some View {
        HStack(spacing: 2) {
            tabButton("Home", symbol: "house.fill", tab: .home, titled: titled)
            tabButton("Devices", symbol: "laptopcomputer.and.iphone", tab: .devices, titled: titled)
            if vm.launcher.settings.shelfEnabled || !vm.launcher.shelf.items.isEmpty {
                tabButton("Shelf", symbol: "tray.full.fill", tab: .shelf, titled: titled)
            }
            tabButton("Notifications", symbol: "bell.fill", tab: .notifications, count: store.visibleHistory.count,
                      titled: titled)
        }
    }

    /// Icon tabs; the selected one also shows its title (three titles don't fit beside the camera).
    private func tabButton(_ title: String, symbol: String, tab: NotchViewModel.ExpandedTab, count: Int? = nil,
                           titled: Bool = true) -> some View {
        let selected = vm.expandedTab == tab
        return Button { vm.expandedTab = tab } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                if selected && titled {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
                }
                if let count, count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4.5).padding(.vertical, 0.5)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
            .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - Home

    private var home: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 10) {
                if let call = activeCall {
                    callCard(call)
                }
                if hasActiveMedia {
                    mediaCard
                } else {
                    clockCard
                }
                // Next meeting (from the calendars your iPhone syncs), unless the media card needs the room.
                if settings.showCalendar, !(hasActiveMedia && (showsLyrics || activeCall != nil)) {
                    UpNextCard(calendar: vm.hub.calendar, compact: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 10) {
                if let s = power.state {
                    batteryCard(s)
                }
                recentCard
            }
            .frame(width: 220)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.07)))
    }

    private func cardHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase)
        }
        .foregroundStyle(.white.opacity(0.5))
    }

    private func callCard(_ call: ActiveCall) -> some View {
        card {
            HStack(spacing: 12) {
                AppIconView(bundleID: call.iconBundleID, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(call.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        CallTimerText(started: call.started)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Self.callGreen)
                    }
                    HStack(spacing: 10) {
                        Label(calls.micMuted == true ? "Muted" : "Mic on",
                              systemImage: calls.micMuted == true ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(calls.micMuted == true ? Self.lowRed : .white.opacity(0.6))
                        Label(calls.cameraIsIPhone ? "iPhone camera" : calls.cameraOn ? "Camera on" : "Camera off",
                              systemImage: calls.cameraIsIPhone ? "iphone.gen3" : calls.cameraOn ? "video.fill" : "video.slash.fill")
                            .foregroundStyle(calls.cameraOn ? Self.callGreen : .white.opacity(0.45))
                    }
                    .font(.system(size: 10.5, weight: .medium))
                }
                Spacer(minLength: 8)
                if let muted = calls.micMuted {
                    Button { calls.toggleMute() } label: {
                        Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(muted ? Self.lowRed : .white.opacity(0.14)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(muted ? "Unmute microphone" : "Mute microphone (system input)")
                }
                Button { calls.showCall(); vm.collapse() } label: {
                    Label("Show", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
    }

    private var showsLyrics: Bool {
        guard settings.showLyrics else { return false }
        if case .off = lyrics.state { return false }
        return true
    }

    private var mediaCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardHeader("Now Playing", symbol: "music.note")
                    Spacer()
                    if case .synced = lyrics.state, settings.showLyrics {
                        LyricsTimingControl(lyrics: lyrics)
                    }
                }
                PlayerControlsView(player: player, artSize: 72)
                if showsLyrics {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    LyricsContextView(lyrics: lyrics)
                }
            }
        }
    }

    private var clockCard: some View {
        card {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ctx.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(ctx.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Image(systemName: "music.note").font(.system(size: 10))
                        Text("Nothing playing").font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    private func batteryCard(_ s: PowerState) -> some View {
        let low = !s.onAC && s.percent <= 20
        let color: Color = low ? Self.lowRed : (s.charging || s.onAC ? Self.callGreen : .white)
        return card {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader("Battery", symbol: s.charging ? "bolt.fill" : "battery.100")
                HStack(spacing: 10) {
                    Text("\(s.percent)%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(low ? Self.lowRed : .white)
                    Spacer(minLength: 0)
                    BatteryGlyph(percent: s.percent, color: color, bolt: s.charging)
                }
                Text(Self.batteryStatus(s))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
    }

    static func batteryStatus(_ s: PowerState) -> String {
        if s.charged || (s.onAC && s.percent >= 100) { return "Fully charged" }
        if s.charging { return "Charging" + (s.minutesToFull.map { " · full in \($0.hoursMinutes)" } ?? "") }
        if s.onAC { return "Plugged in · not charging" }
        return "On battery" + (s.minutesToEmpty.map { " · \($0.hoursMinutes) left" } ?? "")
    }

    private var recentCard: some View {
        let recent = Array(store.visibleHistory.prefix(5))
        return card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    cardHeader("Notifications", symbol: "bell.fill")
                    Spacer()
                    if !store.visibleHistory.isEmpty {
                        Button("See all") { vm.expandedTab = .notifications }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if recent.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bell.slash").font(.system(size: 18))
                        Text("No notifications").font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(recent) { n in
                        NotificationListRow(notification: n)
                            .padding(.horizontal, -6)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { vm.open(n) }
                            .onTapGesture {
                                vm.selectedID = n.id
                                vm.expandedTab = .notifications
                            }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    private static let callGreen = Color(red: 0.19, green: 0.82, blue: 0.35)
    private static let lowRed = Color(red: 1, green: 0.27, blue: 0.23)

    // MARK: - Notifications

    @ViewBuilder private var notifications: some View {
        if store.visibleHistory.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bell.slash").font(.system(size: 22))
                Text("Nothing here yet").font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                list.frame(width: 230)
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1).padding(.vertical, 8)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                ForEach(groups) { group in
                    HStack(spacing: 6) {
                        AppIconView(bundleID: group.bundleID, size: 14)
                        Text(AppInfoProvider.shared.info(for: group.bundleID).name)
                            .font(.system(size: 10, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text("\(group.items.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 8).padding(.bottom, 2)

                    ForEach(group.items) { n in
                        row(n)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    private func row(_ n: NotchNotification) -> some View {
        let isSelected = n.id == selected?.id
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(n.summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(n.date.notchRelative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            if !n.body.isEmpty, n.body != n.summary {
                Text(n.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(isSelected ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { vm.open(n) }
        .onTapGesture { vm.selectedID = n.id }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let n = selected {
            let info = AppInfoProvider.shared.info(for: n.bundleID)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AppIconView(bundleID: n.bundleID, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.name).font(.system(size: 12, weight: .semibold))
                        Text(n.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    if n.isTest {
                        Text("TEST").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().stroke(.white.opacity(0.4)))
                    }
                }
                if !n.title.isEmpty {
                    Text(n.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                }
                if !n.subtitle.isEmpty {
                    Text(n.subtitle).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75)).textSelection(.enabled)
                }
                ScrollView(.vertical) {
                    Text(n.body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                if let chat = QuickActions.replyTarget(for: n) {
                    MessageReplyField(chat: chat)
                }

                HStack(spacing: 8) {
                    let exact = NotificationOpener.deepLink(for: n) != nil
                    Button {
                        vm.open(n)
                    } label: {
                        Label(exact ? "Open conversation" : "Open \(info.name)",
                              systemImage: exact ? "bubble.left.and.text.bubble.right" : "arrow.up.forward.app")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(info.url == nil && !exact)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(n.fullText, forType: .string)
                        copiedID = n.id
                    } label: {
                        Label(copiedID == n.id ? "Copied" : "Copy", systemImage: copiedID == n.id ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(PillButtonStyle())

                    Button {
                        let next = nextSelection(after: n)
                        store.dismiss(n.id)
                        vm.selectedID = next
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                    .buttonStyle(PillButtonStyle())
                    Spacer()
                }
            }
            .padding(.leading, 14)
            .padding(.top, 4)
        }
    }

    private func nextSelection(after n: NotchNotification) -> String? {
        let all = store.visibleHistory
        guard let i = all.firstIndex(where: { $0.id == n.id }) else { return nil }
        if i + 1 < all.count { return all[i + 1].id }
        return i > 0 ? all[i - 1].id : nil
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
