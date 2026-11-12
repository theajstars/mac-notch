import SwiftUI

private let callGreen = Color(red: 0.19, green: 0.82, blue: 0.35)
private let lowRed = Color(red: 1, green: 0.27, blue: 0.23)

/// "12:04" / "1:02:33" since `started`, ticking every second.
struct CallTimerText: View {
    let started: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(max(0, ctx.date.timeIntervalSince(started)).mmss).monospacedDigit()
        }
    }
}

// MARK: - Call

/// Resting state during a call: app icon in the left wing (with a red mic-slash badge when the
/// mic is muted), green running timer in the right wing.
struct CompactCallView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var calls: CallMonitor

    var body: some View {
        let h = vm.geometry.notchSize.height
        let (left, right) = vm.wings
        let iconSize = min(22, h - 12)
        // Icon and timer sit the same visible distance from the notch's outer edges. App icons carry
        // ~10% transparent margin, so the timer gets that much more.
        let inset = (vm.wing - iconSize) / 2
        let timerInset = inset + iconSize * 0.1
        if let call = calls.call {
            HStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    AppIconView(bundleID: call.iconBundleID, size: iconSize)
                    if calls.micMuted == true {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 11, height: 11)
                            .background(Circle().fill(lowRed))
                            .offset(x: 4, y: 3)
                    }
                }
                .padding(.leading, inset)
                .frame(width: left, alignment: .leading)
                Color.clear.frame(width: vm.gapWidth)
                CallTimerText(started: call.started)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(callGreen)
                    .padding(.trailing, timerInset)
                    .frame(width: right, alignment: .trailing)
            }
            .frame(height: h)
            .padding(.horizontal, vm.topRadius)
        }
    }
}

/// Hover card during a call: who, how long, mic / camera state, Mute and Show.
struct CallPeekView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var calls: CallMonitor

    var body: some View {
        let h = vm.geometry.notchSize.height
        let side = (vm.shapeSize.width - vm.gapWidth) / 2 - vm.topRadius - 16
        if let call = calls.call {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Circle().fill(callGreen).frame(width: 6, height: 6)
                        Text("On a call").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(width: side, alignment: .leading)
                    Spacer(minLength: 0)
                    CallTimerText(started: call.started)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(callGreen)
                        .frame(width: side, alignment: .trailing)
                }
                .frame(height: h)

                HStack(spacing: 12) {
                    AppIconView(bundleID: call.iconBundleID, size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(call.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 10) {
                            indicator(calls.micMuted == true ? "mic.slash.fill" : "mic.fill",
                                      calls.micMuted == true ? "Muted" : "Mic on",
                                      calls.micMuted == true ? lowRed : .white.opacity(0.6))
                            indicator(calls.cameraIsIPhone ? "iphone.gen3" : calls.cameraOn ? "video.fill" : "video.slash.fill",
                                      calls.cameraIsIPhone ? "iPhone camera" : calls.cameraOn ? "Camera on" : "Camera off",
                                      calls.cameraOn ? callGreen : .white.opacity(0.45))
                        }
                    }
                    Spacer(minLength: 8)
                    if let muted = calls.micMuted {
                        Button { calls.toggleMute() } label: {
                            Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(muted ? lowRed : .white.opacity(0.14)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .help(muted ? "Unmute microphone" : "Mute microphone (system input)")
                    }
                    Button { calls.showCall(); vm.collapse() } label: {
                        Label("Show", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .help("Bring the call to the front")
                }
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, vm.topRadius + 16)
            .padding(.bottom, 10)
        }
    }

    private func indicator(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(color)
    }
}

// MARK: - Battery

/// Small battery outline filled to the charge level, with a bolt while charging.
struct BatteryGlyph: View {
    let percent: Int
    let color: Color
    var bolt = false

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, 21 * CGFloat(percent) / 100))
                    .padding(2)
            }
            .frame(width: 25, height: 12)
            .overlay {
                if bolt {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 0.5)
                }
            }
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.4)).frame(width: 1.5, height: 4)
        }
    }
}

/// Brief moment when power is connected or the battery runs low: percentage in the left wing,
/// battery glyph in the right wing, status in the strip under the notch.
struct CompactBatteryView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var power: PowerMonitor
    let event: PowerEvent

    var body: some View {
        let h = vm.geometry.notchSize.height
        let (left, right) = vm.wings
        let s = power.state
        let pct = s?.percent ?? 0
        let isLow: Bool = { if case .low = event { return true } else { return false } }()
        let color = isLow ? lowRed : callGreen
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("\(pct)%")
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(color)
                    .frame(width: left)
                Color.clear.frame(width: vm.gapWidth)
                BatteryGlyph(percent: pct, color: color, bolt: !isLow && (s?.charging ?? false))
                    .frame(width: right)
            }
            .frame(height: h)
            Text(statusText(isLow: isLow))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: NotchViewModel.lyricStripHeight - 4, alignment: .top)
        }
        .padding(.horizontal, vm.topRadius)
    }

    private func statusText(isLow: Bool) -> String {
        guard let s = power.state else { return "" }
        if isLow {
            return "Low battery" + (s.minutesToEmpty.map { " · \($0.hoursMinutes) left" } ?? "")
        }
        if s.charged || s.percent >= 100 { return "Fully charged" }
        if s.charging { return "Charging" + (s.minutesToFull.map { " · full in \($0.hoursMinutes)" } ?? "") }
        return s.onAC ? "Plugged in · charging paused" : "On battery"
    }
}
