/// Port of `com.bfgtools.calibration.core.WriteAccessPolicy`.
public enum WriteAccessPolicy {
    /// The N-prefix rule is a *default*, not a measured property of the vehicle.
    ///
    /// The original wrote it because those models were never validated, so it
    /// refuses every write to them. The owner of such a vehicle — who can see
    /// the vehicle, its wiring and its history — can opt out for one session
    /// after an explicit confirmation. Nothing else changes: the pre-write
    /// snapshot, the risk gate, the post-write comparison and the rollback path
    /// all still apply, and the dashboard firmware allowlist is untouched.
    public static var allowsReadOnlySerials = false

    /// Expert mode: one switch that releases every *policy* limit at once.
    ///
    /// What it releases is the right to *try*, never the safety net around the
    /// attempt. Every write still takes a full two-pass snapshot of the module,
    /// still refuses to send a frame when that snapshot cannot be saved, still
    /// writes exactly one byte to one fixed address (module 0x10, index 0x00),
    /// still reads back, still diffs the whole module and still offers two
    /// rollback paths.
    ///
    /// The limits it lifts all say the same thing — "nobody has validated this
    /// combination" — which is a statement about the author's test coverage,
    /// not about the vehicle in front of the rider. On a vehicle whose serial
    /// was simply never in that coverage (an N-prefix or a 3U-prefix machine)
    /// the limit is a dead end with no way out, which is what this switch is for.
    ///
    /// Session-scoped on purpose: cleared on relaunch, so a limit released once
    /// is never silently inherited by the next rider of the phone.
    public static var expertMode = false

    public static func isReadOnlySerial(_ serial: String?) -> Bool {
        if expertMode || allowsReadOnlySerials { return false }
        guard let serial else { return false }
        return serial.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("N")
    }

    /// An unvalidated dashboard/meter firmware pair. The original refuses the
    /// write outright; expert mode proceeds under the normal safety rails.
    public static func allowsUnverifiedCombination() -> Bool { expertMode }

    /// A capacity the built-in table cannot name. Expert mode lets the owner
    /// supply the profile byte directly rather than refusing the write.
    public static func allowsOffTableCapacity() -> Bool { expertMode }

    /// Whether a partially readable module may still be written to.
    ///
    /// A module that answers on only some addresses cannot be fully backed up,
    /// so the original refuses to touch it — and those are precisely the
    /// vehicles that need the tool. Expert mode allows the write, but the
    /// caller must surface the exact list of addresses it could not read and
    /// state plainly that those bytes cannot be restored afterwards.
    public static func allowsPartialBackup() -> Bool { expertMode }

    /// 2.8.6 and 4.2.9 are the explicitly validated meter versions.
    /// Unknown and other versions remain usable, but require extra acknowledgement.
    public static func needsMeterCompatibilityWarning(_ rawVersion: Int) -> Bool {
        if expertMode { return false }
        return rawVersion != 0x0286 && rawVersion != 0x0429
    }

    /// Expert mode waits longer before the write goes out: a mis-tap has to
    /// stay reversible for long enough to notice it.
    public static func riskGateSeconds(isDashboard: Bool) -> Int {
        if expertMode { return isDashboard ? 60 : 15 }
        return isDashboard ? TimedRiskGate.dashboardSeconds : TimedRiskGate.meterSeconds
    }

    /// And watches the profile register for longer afterwards, because a forced
    /// revert is exactly what an unvalidated vehicle is expected to do.
    public static func watchSeconds() -> Double { expertMode ? 90 : 30 }
}
