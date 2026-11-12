import AppKit
import Combine

/// Streams now-playing info from MediaRemote via `/usr/bin/perl notch-media.pl libNotchMedia.dylib stream`,
/// with a Spotify AppleScript fallback if the helper stops working.
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var source: MediaSourceKind?
    /// True while something we show is playing (and for a few seconds after it pauses).
    @Published private(set) var showInNotch = false
    @Published private(set) var status = "Off"

    private let settings: SettingsStore
    private let classifier = SourceClassifier()
    private var process: Process?
    private var buffer = Data()
    private var artwork: NSImage?
    private var failures = 0
    private var restartWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var usingFallback = false
    private var artworkCache: [String: NSImage] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore) {
        self.settings = settings
        settings.$nowPlayingEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                DispatchQueue.main.async { enabled ? self?.start() : self?.stop() }
            }
            .store(in: &cancellables)
        settings.$showOtherPlayers
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateVisibility() } }
            .store(in: &cancellables)
    }

    /// Whether the current item is one we display (supported source, or "other players" allowed).
    var isAllowed: Bool {
        guard info != nil, let source else { return false }
        return source.isSupported || settings.showOtherPlayers
    }

    var hasSession: Bool { settings.nowPlayingEnabled && isAllowed }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        startHelper()
    }

    func stop() {
        restartWork?.cancel()
        stopFallback()
        if let p = process {
            process = nil
            p.terminationHandler = nil
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            p.terminate()
        }
        info = nil
        source = nil
        artwork = nil
        status = "Off"
        updateVisibility()
    }

    private var helperPaths: (script: String, lib: String)? {
        let b = Bundle.main
        guard let script = b.path(forResource: "notch-media", ofType: "pl") else { return nil }
        let lib = b.path(forResource: "libNotchMedia", ofType: "dylib")
            ?? b.privateFrameworksPath.map { "\($0)/libNotchMedia.dylib" }
        guard let lib, FileManager.default.fileExists(atPath: lib) else { return nil }
        return (script, lib)
    }

    private func startHelper() {
        guard settings.nowPlayingEnabled else { return }
        guard let paths = helperPaths else {
            status = "Helper missing from app bundle"
            startFallback()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.lib, "stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { self?.helperExited(proc, code: code) }
        }
        do {
            try p.run()
            process = p
            buffer.removeAll()
            status = "Starting…"
        } catch {
            status = "Could not start perl: \(error.localizedDescription)"
            scheduleRestart()
        }
    }

    private func helperExited(_ p: Process, code: Int32) {
        guard p === process else { return }
        process = nil
        failures += 1
        status = code == 2 ? "MediaRemote unavailable (using Spotify fallback)" : "Helper exited (\(code)), restarting…"
        if code == 2 || failures >= 3 { startFallback() }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard settings.nowPlayingEnabled else { return }
        restartWork?.cancel()
        let delay = min(30, pow(2, Double(min(failures, 5))))
        let work = DispatchWorkItem { [weak self] in self?.startHelper() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Parsing

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if failures > 0 || usingFallback { failures = 0; stopFallback() }
            status = "Running"
            updateCounter &+= 1
            handle(obj)
        }
    }

    private func handle(_ d: [String: Any]) {
        guard (d["active"] as? Bool) == true, let title = d["title"] as? String, !title.isEmpty else {
            info = nil
            source = nil
            artwork = nil
            updateVisibility()
            return
        }
        if let s = d["artworkData"] as? String {
            artwork = Data(base64Encoded: s).flatMap(NSImage.init(data:))
        } else if d["artworkData"] is NSNull {
            artwork = nil
        }
        let ts = (d["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let new = NowPlayingInfo(
            title: title,
            artist: d["artist"] as? String ?? "",
            album: d["album"] as? String ?? "",
            duration: d["duration"] as? Double ?? 0,
            elapsed: d["elapsedTime"] as? Double ?? 0,
            timestamp: ts,
            rate: d["playbackRate"] as? Double ?? 1,
            isPlaying: (d["playing"] as? Bool) ?? ((d["playing"] as? NSNumber)?.boolValue ?? false),
            bundleID: d["bundleIdentifier"] as? String ?? "unknown",
            parentBundleID: d["parentApplicationBundleIdentifier"] as? String,
            artwork: artwork)
        apply(new)
    }

    private func apply(_ new: NowPlayingInfo) {
        var new = new
        let trackChanged = info?.trackKey != new.trackKey
        let bundleChanged = info?.bundleID != new.bundleID
        // MediaRemote's position for Spotify runs a few tenths of a second behind Spotify's own clock
        // (the one its lyrics view uses), so every Spotify update is checked against `player position`.
        if new.bundleID == Self.spotifyID, !usingFallback {
            let now = Date()
            if !trackChanged, let old = info, abs(new.elapsed(at: now) - old.elapsed(at: now)) > Self.positionJumpTolerance {
                // Spotify sometimes re-reports an old elapsed time with a fresh timestamp (seen: a song
                // at 1:17 reported as 0:03), which throws the lyrics far off until the next pause. Keep
                // the running position until Spotify says whether it really moved (a seek).
                new.elapsed = old.elapsed(at: now)
                new.timestamp = now
            }
            verifySpotifyPosition(of: new.trackKey)
        }
        info = new
        if trackChanged {
            let key = new.trackKey
            if let kind = classifier.classify(new, update: { [weak self] kind in
                guard let self, self.info?.trackKey == key else { return }
                self.source = kind
                self.updateVisibility()
            }) {
                source = kind
            } else if bundleChanged {
                source = nil   // wait for the browser's answer
            }
        }
        updateVisibility()
    }

    private static let spotifyID = "com.spotify.client"
    /// Seconds a same-track update may move the position before it is held for Spotify to confirm.
    private static let positionJumpTolerance: Double = 2
    /// Smallest gap to Spotify's own position worth correcting (the AppleScript call takes ~0.2 s,
    /// but Spotify samples its position near the end of it).
    private static let positionCorrectionTolerance: Double = 0.15

    /// Replaces the position with Spotify's own `player position`, if the track is still current.
    private func verifySpotifyPosition(of key: String) {
        // The name guards against reading the previous track's position right at a track change.
        let script = "tell application \"Spotify\" to return (player position as string) & linefeed & (name of current track)"
        AppleScriptRunner.run(script) { [weak self] out in
            guard let self, var i = self.info, i.trackKey == key,
                  let parts = out?.components(separatedBy: "\n"), parts.count >= 2, parts[1] == i.title,
                  let pos = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { return }
            let drift = pos - i.elapsed(at: Date())
            guard abs(drift) > Self.positionCorrectionTolerance else { return }
            DebugLog.write("now playing: Spotify position corrected by \(String(format: "%+.2f", drift))s")
            i.elapsed = pos
            i.timestamp = Date()
            self.info = i
        }
    }

    private func updateVisibility() {
        guard let info, hasSession else {
            hideWork?.cancel()
            showInNotch = false
            return
        }
        if info.isPlaying {
            hideWork?.cancel()
            showInNotch = true
        } else if showInNotch, hideWork == nil || hideWork!.isCancelled {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.info?.isPlaying != true { self.showInNotch = false }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    // MARK: - Commands

    /// Changes whenever the helper reports a real state change (used to verify commands landed).
    private var updateCounter = 0

    /// Play/pause/next/previous with fallbacks, in order:
    /// 1. MediaRemote send-command through the perl bridge (works for any player incl. browsers);
    /// 2. if no state change is observed within ~1.5 s: Spotify's AppleScript for Spotify,
    /// 3. otherwise a system media-key event (needs Accessibility permission to post events).
    func send(_ command: MediaCommand) {
        let before = updateCounter
        let wasSource = source
        // Optimistic UI for play/pause.
        if var i = info, command == .togglePlayPause || command == .play || command == .pause {
            let now = Date()
            i.elapsed = i.elapsed(at: now)
            i.timestamp = now
            i.isPlaying = command == .togglePlayPause ? !i.isPlaying : command == .play
            info = i
            updateVisibility()
        }
        if usingFallback, wasSource == .spotify {
            spotifyScript(command)
            return
        }
        guard let paths = helperPaths else { fallback(command, source: wasSource); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.lib, "send", String(command.rawValue)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.8 : 0)) {
                guard let self else { return }
                if !ok || self.updateCounter == before {
                    DebugLog.write("MediaRemote \(command) had no visible effect; falling back (source \(wasSource.map { "\($0)" } ?? "?"))")
                    self.fallback(command, source: wasSource)
                }
            }
        }
        do { try p.run() } catch { fallback(command, source: wasSource) }
    }

    /// Seeks via MediaRemote (helper `seek`), optimistic locally.
    func seek(to seconds: Double) {
        if var i = info {
            i.elapsed = seconds
            i.timestamp = Date()
            info = i
        }
        guard let paths = helperPaths else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.lib, "seek", String(format: "%.2f", seconds)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func fallback(_ command: MediaCommand, source: MediaSourceKind?) {
        if source == .spotify {
            spotifyScript(command)
        } else {
            MediaKeys.post(command)
        }
    }

    private func spotifyScript(_ command: MediaCommand) {
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        AppleScriptRunner.run("tell application \"Spotify\" to \(verb)", timeout: 30) { [weak self] _ in
            self?.pollSpotify()
        }
    }

    // MARK: - Debug

    /// `--demo-music[=spotify|youtube|youtubemusic]`: stops the helper and shows a fake track.
    func debugDemo(_ kind: String) {
        stop()
        status = "Demo"
        let art = NSImage(size: NSSize(width: 120, height: 120), flipped: false) { r in
            let g = NSGradient(colors: [.systemPink, .systemOrange, .systemPurple])
            g?.draw(in: r, angle: 45)
            return true
        }
        let src: MediaSourceKind = kind == "youtube" ? .youtube : kind == "youtubemusic" ? .youtubeMusic : .spotify
        info = NowPlayingInfo(
            title: "A Really Long Song Title That Definitely Needs To Scroll (Extended Mix)",
            artist: "The Marquee Collective feat. Somebody Famous", album: "Demo",
            duration: 245, elapsed: 61, timestamp: Date(), rate: 1, isPlaying: true,
            bundleID: src == .spotify ? "com.spotify.client" : "com.google.Chrome", parentBundleID: nil, artwork: art)
        source = src
        updateVisibility()
    }

    // MARK: - Spotify AppleScript fallback

    private func startFallback() {
        guard fallbackTimer == nil else { return }
        usingFallback = true
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSpotify() }
        }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t
        pollSpotify()
    }

    private func stopFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        usingFallback = false
    }

    private func pollSpotify() {
        guard usingFallback,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil
        else { return }
        let script = """
        tell application "Spotify"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string) & linefeed & (artwork url of t)
        end tell
        """
        AppleScriptRunner.run(script) { [weak self] out in
            guard let self, self.usingFallback, let out else { return }
            let lines = out.components(separatedBy: "\n")
            guard lines.count >= 6 else {
                if self.info?.bundleID == "com.spotify.client" { self.info = nil; self.updateVisibility() }
                return
            }
            let num: (String) -> Double = { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            let artURL = lines.count > 6 ? lines[6] : ""
            let info = NowPlayingInfo(
                title: lines[1], artist: lines[2], album: lines[3],
                duration: num(lines[4]) / 1000, elapsed: num(lines[5]), timestamp: Date(), rate: 1,
                isPlaying: lines[0] == "playing", bundleID: "com.spotify.client", parentBundleID: nil,
                artwork: self.artworkCache[artURL])
            self.apply(info)
            if self.artworkCache[artURL] == nil, let url = URL(string: artURL), url.scheme == "https" {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self.artworkCache[artURL] = img
                        if var i = self.info, i.bundleID == "com.spotify.client" { i.artwork = img; self.info = i }
                    }
                }.resume()
            }
        }
    }
}
