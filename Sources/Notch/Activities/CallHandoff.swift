import Foundation

extension ActiveCall {
    /// The call after this poll, given every app now recording (highest priority first), or nil
    /// to keep it as is. The call stays with its app while that app still holds the mic, so a
    /// call app that opens the mic mid-call (WhatsApp on launch) doesn't take over a Meet call.
    /// Once the app lets go, another non-browser app may take it (FaceTime -> avconferenced).
    func handedOff(to candidates: [ActiveCall]) -> ActiveCall? {
        guard !candidates.contains(where: { $0.iconBundleID == iconBundleID }),
              let next = candidates.first(where: { $0.browserBundleID == nil }) else { return nil }
        var c = self
        c.iconBundleID = next.iconBundleID
        c.name = next.name
        c.browserBundleID = nil
        c.meetingHost = nil
        return c
    }
}
