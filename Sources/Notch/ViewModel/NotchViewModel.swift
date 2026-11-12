import AppKit
import Combine
import SwiftUI

/// UI state for one notch window (one per screen). History lives in the shared NotificationStore.
@MainActor
final class NotchViewModel: ObservableObject {
    enum State: Equatable { case idle, music, call, timer, battery, moment, drop, compact, peek, musicPeek, callPeek, timerPeek, expanded }
    /// Resting states: what the notch shows when nothing else is going on.
    static let resting: [State] = [.idle, .music, .call, .timer]

    @Published private(set) var state: State = .idle
    @Published private(set) var current: NotchNotification?
    @Published private(set) var pendingCount = 0
    @Published var selectedID: NotchNotification.ID?
    /// Which page the expanded panel shows: the activity overview or the notification history.
    enum ExpandedTab: Equatable { case home, devices, shelf, notifications }
    @Published var expandedTab: ExpandedTab = .home
    /// Notification pinned at the top of the music hover panel (just shown, or arrived while it was open).
    @Published private(set) var peekHighlight: NotchNotification?
    private var lastShown: (item: NotchNotification, at: Date)?
    @Published var geometry: NotchGeometry

    let store: NotificationStore
    let settings: SettingsStore
    let player: NowPlayingService
    let lyrics: LyricsService
    let calls: CallMonitor
    let power: PowerMonitor
    /// What the brief battery moment is showing (plugged in / low).
    @Published private(set) var batteryEvent: PowerEvent?
    private var pendingBattery: (event: PowerEvent, at: Date)?
    private var batteryWork: DispatchWorkItem?
    let hub: ContinuityHub
    /// Launcher services: the timer in the wings, the shelf.
    let launcher: LauncherServices
    let timers: TimerService
    /// The device / Continuity moment on screen, and ones waiting behind notifications.
    @Published private(set) var moment: Moment?
    private var pendingMoments: [(moment: Moment, at: Date)] = []
    private var momentWork: DispatchWorkItem?
    /// Files are being dragged somewhere on screen (set by the window controller).
    @Published private(set) var isDraggingFiles = false
    var openSettings: () -> Void = {}
    var openFullDiskAccess: () -> Void = {}

    /// Size of the panel that hosts the shape; big enough for the expanded state.
    static let panelSize = CGSize(width: 720, height: 470)

    private var queue: [NotchNotification] = []
    private var compactWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var autoPeekWork: DispatchWorkItem?
    /// True while the music card is showing because the track changed (not because of hover).
    private(set) var isAutoPeek = false
    private(set) var isHovering = false
    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry, store: NotificationStore, settings: SettingsStore,
         player: NowPlayingService, lyrics: LyricsService, calls: CallMonitor, power: PowerMonitor,
         hub: ContinuityHub, launcher: LauncherServices) {
        self.geometry = geometry
        self.launcher = launcher
        self.timers = launcher.timers
        self.store = store
        self.settings = settings
        self.player = player
        self.lyrics = lyrics
        self.calls = calls
        self.power = power
        self.hub = hub
        hub.moments
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.showMoment($0) }
            .store(in: &cancellables)
        // Calls take over the resting state from music, and hand it back when they end.
        calls.$call
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    if Self.resting.contains(self.state) { self.state = self.restingState }
                    if self.state == .callPeek, self.calls.call == nil { self.collapse() }
                }
            }
            .store(in: &cancellables)
        // A running timer rests in the wings (below calls, above music).
        timers.$timer
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    if Self.resting.contains(self.state) { self.state = self.restingState }
                    if self.state == .timerPeek, self.timers.timer == nil { self.collapse() }
                }
            }
            .store(in: &cancellables)
        power.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.showBattery($0) }
            .store(in: &cancellables)
        // Music comes and goes underneath notifications.
        player.$showInNotch
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if Self.resting.contains(self.state) { self.state = self.restingState }
            }
            .store(in: &cancellables)
        // Track changes: briefly drop down so you can see what's playing.
        player.$info
            .map { $0?.trackKey }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                guard key != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.autoPeekIfResting() }
            }
            .store(in: &cancellables)
        store.arrivals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.enqueue($0) }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    var topRadius: CGFloat {
        switch state {
        case .idle: return 6
        case .music, .call, .timer, .battery, .moment, .compact: return 8
        case .peek, .musicPeek, .callPeek, .timerPeek, .drop: return 12
        case .expanded: return 14
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .idle: return 8
        case .music, .call, .timer, .battery, .moment, .compact: return 12
        case .peek, .musicPeek, .callPeek, .timerPeek, .drop: return 20
        case .expanded: return 26
        }
    }

    /// Dynamic-Island style wing: about as wide as the notch is tall.
    var wing: CGFloat { geometry.notchSize.height + 6 }

    /// Clearance kept on each side of the camera housing.
    var gapPadding: CGFloat { geometry.hasNotch ? 4 : 0 }

    /// Width of the no-draw zone over the camera (housing + clearance).
    var gapWidth: CGFloat { geometry.notchSize.width + 2 * gapPadding }

    /// Strip under the compact notch (notification label or lyric line).
    static let lyricStripHeight: CGFloat = 20
    static let stripFont = Font.system(size: 11.5, weight: .semibold)

    /// The compact notification shows its label in the strip under the notch.
    var showsLabelStrip: Bool { state == .compact && current != nil }

    /// Lyric line under the compact music notch (hidden in gaps / without lyrics).
    var showsLyricStrip: Bool {
        state == .music && settings.showLyrics && settings.showLyricStrip && lyrics.currentLine != nil
    }

    /// Notifications listed in the music hover panel.
    static let peekListLimit = 5
    static let peekRowHeight: CGFloat = 30

    private var musicPeekHeight: CGFloat {
        var hgt = geometry.notchSize.height                          // top band beside the camera
        if peekHighlight != nil { hgt += 78 }                        // pinned notification card
        hgt += 70                                                    // compact player
        if case .synced = lyrics.state, settings.showLyrics { hgt += 62 + (lyrics.hasExtraLine ? 16 : 0) }
        let count = store.visibleHistory.count
        hgt += 24 + (count == 0 ? 22 : CGFloat(min(count, Self.peekListLimit)) * Self.peekRowHeight)
        return hgt + 14
    }

    /// (left wing, right wing) for the compact states. Calls widen both wings symmetrically so the
    /// timer ("57:00", or "1:02:33" past an hour) keeps the same margin as the icon opposite it.
    var wings: (CGFloat, CGFloat) {
        if state == .call { return calls.pastHour ? (wing + 24, wing + 24) : (wing + 12, wing + 12) }
        if state == .timer, let t = timers.timer, (t.remaining() ?? t.elapsed()) >= 3600 { return (wing + 12, wing + 12) }
        if state == .timer { return (wing, wing + 8) }
        if state == .moment, case .text(let t, _)? = moment?.right, t.count > 3 { return (wing + 8, wing + 8) }
        return (wing, wing)
    }

    var shapeSize: CGSize {
        let w = geometry.notchSize.width, h = geometry.notchSize.height
        switch state {
        case .idle: return CGSize(width: w + 2 * topRadius, height: h)
        case .compact, .music, .call, .timer, .battery, .moment:
            let (l, r) = wings
            let strip = (showsLyricStrip || showsLabelStrip || state == .battery || state == .moment) ? Self.lyricStripHeight : 0
            return CGSize(width: gapWidth + 2 * topRadius + l + r, height: h + strip)
        case .callPeek: return CGSize(width: max(w + 2 * topRadius + 2 * 150, 440), height: h + 64)
        case .timerPeek: return CGSize(width: max(w + 2 * topRadius + 2 * 150, 440), height: h + 64)
        case .drop: return CGSize(width: max(w + 2 * topRadius + 2 * 130, 400), height: h + 92)
        case .peek: return CGSize(width: max(w + 2 * topRadius + 2 * 150, 470), height: h + 112)
        case .musicPeek: return CGSize(width: 480, height: min(musicPeekHeight, Self.panelSize.height - 20))
        case .expanded: return CGSize(width: 660, height: 430)
        }
    }

    /// The idle shape is drawn invisibly so it can grow out of the hardware notch.
    var shapeOpacity: Double { state == .idle ? 0 : 1 }

    /// Region (in shape coordinates, top-centred) that should receive the mouse.
    var hitSize: CGSize {
        if state == .idle {
            let h = geometry.notchSize.height
            return geometry.hasNotch ? CGSize(width: geometry.notchSize.width, height: h)
                                     : CGSize(width: 200, height: max(4, h * 0.6))
        }
        return shapeSize
    }

    // MARK: - Notifications

    private func enqueue(_ n: NotchNotification) {
        queue.append(n)
        pendingCount = queue.count
        if state == .musicPeek && !isAutoPeek {
            // The music hover panel is open: pin the new one at the top instead of queueing it.
            peekHighlight = n
            lastShown = (n, Date())
            queue.removeAll { $0.id == n.id }
            pendingCount = queue.count
        } else if (Self.resting + [.battery, .moment]).contains(state) || (state == .musicPeek && isAutoPeek) {
            if state == .moment, let m = moment { requeueMoment(m) }
            showNext()
        } else if state == .compact {
            // Others are waiting now: don't hold the current one for the full duration.
            scheduleAdvance(after: min(settings.displayDuration, 2.0))
        }
    }

    /// What the notch shows when nothing else is going on: a call, then music, then nothing.
    var restingState: State {
        if settings.showCalls, calls.call != nil { return .call }
        if timers.timer != nil { return .timer }
        return player.showInNotch ? .music : .idle
    }

    // MARK: - Battery moment

    private func showBattery(_ event: PowerEvent) {
        switch event {
        case .pluggedIn: guard settings.showCharging else { return }
        case .low: guard settings.lowBatteryAlerts else { return }
        }
        // Busy with a notification or a card: show it once things settle (if still relevant).
        let canShow = (Self.resting + [.battery]).contains(state) || (state == .musicPeek && isAutoPeek)
        guard canShow, !isHovering else {
            pendingBattery = (event, Date())
            return
        }
        presentBattery(event)
    }

    private func presentBattery(_ event: PowerEvent) {
        pendingBattery = nil
        isAutoPeek = false
        autoPeekWork?.cancel()
        batteryEvent = event
        state = .battery
        batteryWork?.cancel()
        let isLow: Bool = { if case .low = event { return true } else { return false } }()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .battery else { return }
            self.showNext()   // a device moment may be waiting
        }
        batteryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isLow ? 5 : 3), execute: work)
    }

    /// A battery event that was held back while a notification was showing (fresh ones only).
    private func takePendingBattery() -> PowerEvent? {
        guard let p = pendingBattery else { return nil }
        pendingBattery = nil
        return Date().timeIntervalSince(p.at) < 20 ? p.event : nil
    }

    // MARK: - Device moments

    private func showMoment(_ m: Moment) {
        let canShow = Self.resting.contains(state) || (state == .musicPeek && isAutoPeek)
        guard canShow, !isHovering else {
            pendingMoments.append((m, Date()))
            return
        }
        presentMoment(m)
    }

    private func presentMoment(_ m: Moment) {
        isAutoPeek = false
        autoPeekWork?.cancel()
        moment = m
        state = .moment
        scheduleMomentEnd(after: m.duration)
    }

    private func scheduleMomentEnd(after delay: TimeInterval) {
        momentWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .moment, !self.isHovering else { return }
            self.showNext()
        }
        momentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A notification interrupted this moment: show it again afterwards.
    private func requeueMoment(_ m: Moment) {
        momentWork?.cancel()
        pendingMoments.insert((m, Date()), at: 0)
    }

    /// Oldest moment that's still fresh (30 s); stale ones are dropped.
    private func takePendingMoment() -> Moment? {
        pendingMoments.removeAll { Date().timeIntervalSince($0.at) > 30 }
        guard !pendingMoments.isEmpty else { return nil }
        return pendingMoments.removeFirst().moment
    }

    /// Click on a moment: run its action (open link, reveal file, join meeting) and move on.
    func activateMoment() {
        guard state == .moment, let m = moment else { return }
        guard m.action != nil else {
            expand(tab: .devices)
            return
        }
        m.perform()
        momentWork?.cancel()
        showNext()
    }

    // MARK: - AirDrop drop zone

    func setDraggingFiles(_ on: Bool) {
        guard on != isDraggingFiles else { return }
        isDraggingFiles = on
        if !on, state == .drop {
            // Give a drop that just happened time to be handled first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.state == .drop else { return }
                self.collapse()
            }
        }
    }

    /// Files dropped on the notch: hand them to AirDrop's device picker.
    func dropFiles(_ urls: [URL]) {
        isDraggingFiles = false
        collapse()
        AirDropMonitor.send(urls)
    }

    /// Files dropped on the Shelf zone: keep them on the notch for later.
    func shelveFiles(_ urls: [URL]) {
        isDraggingFiles = false
        launcher.shelf.add(urls)
        collapse()
        launcher.emit(Moment(kind: .launcher, left: .symbol("tray.full.fill", ContinuityColors.orange), right: .text("\(launcher.shelf.items.count)"),
                             title: "Shelf", detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files added",
                             duration: 2.5, action: .run { [weak self] in self?.expand(tab: .shelf) }, actionHint: "Click to open the Shelf"))
    }

    /// The drop zone shows when either target is on.
    var acceptsFileDrops: Bool { settings.airDropDropZone || launcher.settings.shelfEnabled }

    private func autoPeekIfResting(attempt: Int = 0) {
        // Music may only just be starting (still idle): try again shortly.
        if state == .idle, attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.autoPeekIfResting(attempt: attempt + 1)
            }
            return
        }
        guard state == .music, !isHovering else { return }
        isAutoPeek = true
        state = .musicPeek
        autoPeekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isAutoPeek, !self.isHovering, self.state == .musicPeek else { return }
            self.isAutoPeek = false
            self.collapse()
        }
        autoPeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func showNext() {
        compactWork?.cancel()
        isAutoPeek = false
        guard !queue.isEmpty else {
            if let b = takePendingBattery() { presentBattery(b) }
            else if let m = takePendingMoment() { presentMoment(m) }
            else { moment = nil; state = restingState }
            return
        }
        current = queue.removeFirst()
        pendingCount = queue.count
        if let c = current { lastShown = (c, Date()) }
        state = .compact
        // Shorter dwell while others are waiting.
        let dwell = queue.isEmpty ? settings.displayDuration : min(settings.displayDuration, 2.0)
        scheduleAdvance(after: dwell)
    }

    private func scheduleAdvance(after dwell: TimeInterval) {
        compactWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .compact else { return }
            self.showNext()
        }
        compactWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    // MARK: - Interaction

    /// Debug (`--peek` launch flag): keep the hover state so the peek card can be inspected.
    var debugPinHover = false

    func setHovering(_ inside: Bool) {
        if debugPinHover && !inside { return }
        guard inside != isHovering else { return }
        isHovering = inside
        hoverWork?.cancel()
        if inside, isDraggingFiles, acceptsFileDrops, state != .expanded {
            // A file drag reached the notch: offer AirDrop straight away.
            autoPeekWork?.cancel()
            compactWork?.cancel()
            momentWork?.cancel()
            isAutoPeek = false
            state = .drop
            return
        }
        if inside {
            let work = DispatchWorkItem { [weak self] in self?.hoverBegan() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isHovering else { return }
                if [.peek, .musicPeek, .callPeek, .timerPeek, .expanded, .drop].contains(self.state) { self.collapse() }
                if self.state == .moment { self.scheduleMomentEnd(after: 1.2) }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func hoverBegan() {
        guard isHovering else { return }
        switch state {
        case .compact:
            compactWork?.cancel()
            if player.hasSession {
                // Music + notification: the panel shows both, with this notification on top.
                peekHighlight = current
                state = .musicPeek
            } else {
                state = .peek
            }
        case .music:
            peekHighlight = recentlyShown
            state = .musicPeek
        case .call:
            state = .callPeek
        case .timer:
            state = .timerPeek
        case .moment:
            // Hold the moment while the pointer is on it, so it can be clicked.
            momentWork?.cancel()
        case .drop:
            break
        case .battery:
            // Hovering ends the battery moment and behaves like hovering the resting notch.
            batteryWork?.cancel()
            state = restingState
            hoverBegan()
        case .musicPeek:
            isAutoPeek = false   // hovering takes over from the auto-peek timer
        case .idle:
            // A paused session can still be controlled from the idle notch.
            if player.hasSession {
                peekHighlight = recentlyShown
                state = .musicPeek
            } else {
                current = store.visibleHistory.first
                state = .peek
            }
        case .peek, .callPeek, .timerPeek, .expanded:
            break
        }
    }

    /// A notification shown in the last ~10 s (so hovering never buries a new message).
    private var recentlyShown: NotchNotification? {
        guard let l = lastShown, Date().timeIntervalSince(l.at) < 10,
              store.visibleHistory.contains(where: { $0.id == l.item.id }) else { return nil }
        return l.item
    }

    /// Opens the expanded panel. Clicking a specific notification (or the notch while one is showing)
    /// lands on the notification history; otherwise it opens on the Home overview.
    func expand(selecting id: NotchNotification.ID? = nil, tab: ExpandedTab? = nil) {
        compactWork?.cancel()
        let showingNotification = (state == .compact || state == .peek) ? current?.id : nil
        let focused = id ?? peekHighlight?.id ?? showingNotification
        selectedID = focused ?? store.visibleHistory.first?.id
        expandedTab = tab ?? (focused != nil ? .notifications : .home)
        peekHighlight = nil
        state = .expanded
    }

    /// Opens the notification history from outside (status menu).
    func showExpanded() {
        current = current ?? store.visibleHistory.first
        expand(tab: .notifications)
    }

    /// Double-click: open the notification's conversation (or app) and fold the notch away.
    func open(_ n: NotchNotification) {
        NotificationOpener.open(n)
        collapse()
    }

    func collapse() {
        isAutoPeek = false
        if state == .moment { momentWork?.cancel() }
        peekHighlight = nil
        showNext()   // queued notifications, then a held-back battery moment, then the resting state
    }
}
