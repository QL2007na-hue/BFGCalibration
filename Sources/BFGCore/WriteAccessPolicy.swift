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

    public static func isReadOnlySerial(_ serial: String?) -> Bool {
        if allowsReadOnlySerials { return false }
        guard let serial else { return false }
        return serial.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("N")
    }

    /// 2.8.6 and 4.2.9 are the explicitly validated meter versions.
    /// Unknown and other versions remain usable, but require extra acknowledgement.
    public static func needsMeterCompatibilityWarning(_ rawVersion: Int) -> Bool {
        rawVersion != 0x0286 && rawVersion != 0x0429
    }
}
