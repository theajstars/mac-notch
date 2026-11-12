import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreMediaIO

struct ActiveCall: Equatable {
    /// App whose icon is shown (the browser for web meetings).
    var iconBundleID: String
    /// "Zoom", "FaceTime", "Google Meet", "Chrome", …
    var name: String
    var started: Date
    /// For browsers: the meeting tab's host, used to bring that tab forward.
    var browserBundleID: String?
    var meetingHost: String?
}

/// Detects calls from which process is recording from the microphone (CoreAudio's per-process
/// objects, macOS 14.2+, no permission needed). Known call apps and browsers count as a call;
/// FaceTime and iPhone calls show up as `avconferenced`. Also reports the camera and lets the
/// call card mute the default input device.
@MainActor
final class CallMonitor: ObservableObject {
    @Published private(set) var call: ActiveCall?
    @Published private(set) var cameraOn = false
    /// The camera in use is an iPhone (Continuity Camera).
    @Published private(set) var cameraIsIPhone = false
    /// nil when the current input device can't be muted.
    @Published private(set) var micMuted: Bool?
    /// Flips once the call passes an hour, so the notch can widen for "1:02:33".
    @Published private(set) var pastHour = false

    private let settings: SettingsStore
    private var timer: Timer?
    private var candidateSince: Date?
    private var lastSeen = Date.distantPast
    private var isDemo = false
    /// We muted the input from the call card: unmute it when the call ends (or Notch quits) so the
    /// next call doesn't start silently muted.
    private var mutedByUs = false
    private var cancellables = Set<AnyCancellable>()

    /// Seconds a call app must hold the mic before the notch shows a call (skips dictation blips).
    private static let startDelay: TimeInterval = 2
    /// Seconds without the mic before the call ends (rejoins, device switches).
    private static let endDelay: TimeInterval = 4

    init(settings: SettingsStore) {
        self.settings = settings
        settings.$showCalls
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
            .store(in: &cancellables)
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        call = nil
        restoreMute()
        candidateSince = nil
        isDemo = false
    }

    // MARK: - Polling

    private func poll() {
        let now = Date()
        if isDemo {
            refreshDeviceState()
            pastHour = call.map { now.timeIntervalSince($0.started) >= 3600 } ?? false
            return
        }
        let candidates = Self.findCallApps(anyApp: settings.callsAnyApp)
        if let found = candidates.first {
            lastSeen = now
            if let c = call {
                // Same call, possibly handed to another process (e.g. FaceTime -> avconferenced).
                if let next = c.handedOff(to: candidates) {
                    DebugLog.write("call handed off: \(c.name) -> \(next.name) (\(next.iconBundleID))")
                    call = next
                }
            } else {
                let since = candidateSince ?? now
                candidateSince = since
                if now.timeIntervalSince(since) >= Self.startDelay {
                    var c = found
                    c.started = since
                    call = c
                    DebugLog.write("call started: \(c.name) (\(c.iconBundleID))")
                    if let browser = c.browserBundleID { identifyMeeting(in: browser) }
                }
            }
        } else {
            candidateSince = nil
            if let c = call, now.timeIntervalSince(lastSeen) > Self.endDelay {
                DebugLog.write("call ended: \(c.name) after \(Int(now.timeIntervalSince(c.started)))s")
                call = nil
                restoreMute()
            }
        }
        if call != nil { refreshDeviceState() } else if cameraOn || cameraIsIPhone { cameraOn = false; cameraIsIPhone = false }
        pastHour = call.map { now.timeIntervalSince($0.started) >= 3600 } ?? false
    }

    private func refreshDeviceState() {
        let cam = Self.cameraRunning()
        if cam != cameraOn { cameraOn = cam }
        let iphone = cam && Self.continuityCameraInUse()
        if iphone != cameraIsIPhone { cameraIsIPhone = iphone }
        let muted = Self.inputMuted()
        if muted != micMuted { micMuted = muted }
    }

    // MARK: - Actions

    func toggleMute() {
        guard let m = micMuted else { return }
        if Self.setInputMuted(!m) {
            micMuted = !m
            mutedByUs = !m
        }
    }

    /// Undoes a mute Notch made (call ended, calls turned off, or quitting).
    func restoreMute() {
        guard mutedByUs else { return }
        mutedByUs = false
        if Self.inputMuted() == true, Self.setInputMuted(false) {
            micMuted = false
            DebugLog.write("call: restored microphone (Notch had muted it)")
        }
    }

    /// Brings the call app (or the meeting tab) to the front.
    func showCall() {
        guard let c = call else { return }
        if let browser = c.browserBundleID, let host = c.meetingHost,
           let script = Self.focusTabScript(browser: browser, host: host) {
            AppleScriptRunner.run(script, timeout: 5) { _ in }
            return
        }
        let id = c.iconBundleID
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    // MARK: - Who is using the microphone

    private static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "ru.keepcoder.Telegram": "Telegram",
        "org.telegram.desktop": "Telegram",
        "com.skype.skype": "Skype",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "org.whispersystems.signal-desktop": "Signal",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.mobilephone": "Phone",
        "com.ringcentral.glip": "RingCentral",
        "com.gotomeeting.GoToMeeting": "GoTo",
    ]

    /// Browsers by bundle-id prefix (their helper processes do the recording).
    static let browsers: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
        "org.chromium.Chromium": "Chromium",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
        "org.mozilla.firefox": "Firefox",
        "com.apple.Safari": "Safari",
    ]

    /// System processes that use the mic for things that aren't calls.
    private static let ignored = ["com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.assistantd",
                                  "com.apple.Siri", "com.apple.SpeechRecognitionCore", "com.apple.accessibility",
                                  "com.apple.dictation", "com.apple.controlcenter", "com.theajstars.notch"]

    private static func matches(_ id: String, _ prefix: String) -> Bool {
        id == prefix || id.hasPrefix(prefix + ".")
    }

    /// Every app recording right now, one entry per app, highest priority first.
    private static func findCallApps(anyApp: Bool) -> [ActiveCall] {
        var found: [(ActiveCall, Int)] = []   // (call, priority): call app 3, FaceTime/phone 2, browser 1, other 0
        for (pid, rawID) in micProcesses() {
            let id = rawID
            if ignored.contains(where: { matches(id, $0) }) { continue }
            var candidate: (ActiveCall, Int)?
            if id == "com.apple.avconferenced" || matches(id, "com.apple.TelephonyUtilities") {
                candidate = (facetimeOrPhone(), 2)
            } else if let (key, name) = callApps.first(where: { matches(id, $0.key) }) {
                candidate = (ActiveCall(iconBundleID: key, name: name, started: Date()), 3)
            } else if let (key, name) = browsers.first(where: { matches(id, $0.key) }) {
                candidate = (ActiveCall(iconBundleID: key, name: shortBrowserName(name), started: Date(),
                                        browserBundleID: key), 1)
            } else if id.hasPrefix("com.apple.WebKit"),
                      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first != nil {
                candidate = (ActiveCall(iconBundleID: "com.apple.Safari", name: "Safari", started: Date(),
                                        browserBundleID: "com.apple.Safari"), 1)
            } else if anyApp, let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular, let appID = app.bundleIdentifier {
                candidate = (ActiveCall(iconBundleID: appID, name: app.localizedName ?? appID, started: Date()), 0)
            }
            if let c = candidate, !found.contains(where: { $0.0.iconBundleID == c.0.iconBundleID }) { found.append(c) }
        }
        // Stable: within a priority, CoreAudio's order decides, as before.
        return found.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
    }

    private static func shortBrowserName(_ s: String) -> String {
        s.replacingOccurrences(of: "Google ", with: "").replacingOccurrences(of: " Browser", with: "")
            .replacingOccurrences(of: "Microsoft ", with: "")
    }

    private static func facetimeOrPhone() -> ActiveCall {
        let running = { (id: String) in NSRunningApplication.runningApplications(withBundleIdentifier: id).first != nil }
        if running("com.apple.mobilephone"), !running("com.apple.FaceTime") {
            return ActiveCall(iconBundleID: "com.apple.mobilephone", name: "Phone", started: Date())
        }
        return ActiveCall(iconBundleID: "com.apple.FaceTime", name: "FaceTime", started: Date())
    }

    /// (pid, bundle id) of every process currently recording audio.
    private static func micProcesses() -> [(pid_t, String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [(pid_t, String)] = []
        for obj in ids {
            var running: UInt32 = 0
            guard getScalar(obj, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { continue }
            var pid: pid_t = -1
            _ = getScalar(obj, kAudioProcessPropertyPID, &pid)
            out.append((pid, bundleID(obj) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""))
        }
        return out
    }

    private static func getScalar<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T,
                                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) } == noErr
    }

    private static func bundleID(_ obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ref) == noErr,
              let s = ref?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Microphone mute (default input device)

    private static func defaultInput() -> AudioObjectID? {
        var dev = AudioObjectID(0)
        guard getScalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &dev),
              dev != 0 else { return nil }
        return dev
    }

    private static func inputMuted() -> Bool? {
        guard let dev = defaultInput() else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var v: UInt32 = 0
        guard getScalar(dev, kAudioDevicePropertyMute, &v, scope: kAudioDevicePropertyScopeInput) else { return nil }
        return v != 0
    }

    private static func setInputMuted(_ muted: Bool) -> Bool {
        guard let dev = defaultInput() else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    // MARK: - Camera

    private static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == 0 else { return false }
        for d in devices {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == 0, running != 0 {
                return true
            }
        }
        return false
    }

    /// Continuity Camera devices (macOS 14+) report whether another app is capturing from them.
    /// Enumerating devices doesn't need camera permission.
    private static func continuityCameraInUse() -> Bool {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera], mediaType: .video, position: .unspecified)
        return session.devices.contains { $0.isInUseByAnotherApplication }
    }

    // MARK: - Web meetings

    private static let meetingHosts: [(String, String)] = [
        ("meet.google.com", "Google Meet"),
        ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"),
        ("zoom.us", "Zoom"),
        ("app.slack.com", "Slack"),
        ("discord.com", "Discord"),
        ("whereby.com", "Whereby"),
        ("web.whatsapp.com", "WhatsApp"),
        ("meet.jit.si", "Jitsi"),
        ("around.co", "Around"),
        ("app.gather.town", "Gather"),
    ]

    /// Asks the browser for its tab URLs (same Automation permission the music classifier uses)
    /// and renames the call after the meeting site, e.g. "Google Meet".
    private func identifyMeeting(in browser: String) {
        guard let appName = Self.browsers[browser], browser != "org.mozilla.firefox",
              NSRunningApplication.runningApplications(withBundleIdentifier: browser).first != nil else { return }
        let script = """
        set out to ""
        tell application "\(appName)"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        AppleScriptRunner.run(script, timeout: 10) { [weak self] output in
            guard let self, var c = self.call, c.browserBundleID == browser, let output else { return }
            for line in output.split(separator: "\n") {
                guard let host = URL(string: String(line))?.host?.lowercased() else { continue }
                if let (h, name) = Self.meetingHosts.first(where: { host == $0.0 || host.hasSuffix("." + $0.0) }) {
                    c.name = name
                    c.meetingHost = h
                    self.call = c
                    DebugLog.write("call is a web meeting: \(name)")
                    return
                }
            }
        }
    }

    private static func focusTabScript(browser: String, host: String) -> String? {
        guard let appName = browsers[browser], browser != "org.mozilla.firefox" else { return nil }
        let select = browser == "com.apple.Safari" ? "set current tab of w to t" : "set active tab index of w to i"
        return """
        tell application "\(appName)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if (URL of t) contains "\(host)" then
                        \(select)
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
            activate
        end tell
        """
    }

    // MARK: - Debug

    /// `--demo-call[=zoom|facetime|meet]`: a fake call that started a minute ago.
    func debugDemo(_ kind: String) {
        isDemo = true
        switch kind {
        case "facetime": call = ActiveCall(iconBundleID: "com.apple.FaceTime", name: "FaceTime", started: Date() - 61)
        case "meet": call = ActiveCall(iconBundleID: "com.google.Chrome", name: "Google Meet", started: Date() - 3725,
                                       browserBundleID: "com.google.Chrome", meetingHost: "meet.google.com")
        default: call = ActiveCall(iconBundleID: "us.zoom.xos", name: "Zoom", started: Date() - 61)
        }
        refreshDeviceState()
        start()
    }
}
