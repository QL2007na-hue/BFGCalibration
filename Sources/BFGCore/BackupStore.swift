import Foundation

/// Per-vehicle parameter backup, ported from the Android `SharedPreferences`
/// store of the same name.
///
/// Android keyed every entry by Bluetooth MAC. iOS cannot read a MAC address at
/// all, so the 14-character serial — already this app's vehicle identity — is the
/// key instead. The retention rules are unchanged: the first backup and the
/// original dashboard bytes are written once and never overwritten, while the
/// pre-write snapshot is replaced on every write.
public final class BackupStore {

    public struct Backup {
        public let profile: Int
        public let capacity: Int
        public let time: Int64

        /// Android treats a backup as usable only when all three survived.
        public var valid: Bool { profile >= 0 && capacity > 0 && time > 0 }

        /// `MM-dd HH:mm:ss` in the vehicle's local time, matching the original.
        public var description: String {
            guard valid else { return "未保存" }
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            let stamp = Date(timeIntervalSince1970: Double(time) / 1000)
            return "\(BfgProfileCatalog.nominalVoltage(profile))V · "
                + "\(Self.formatCapacity(capacity))（\(formatter.string(from: stamp))）"
        }

        public static func formatCapacity(_ milliAh: Int) -> String {
            let value = Double(milliAh) / 1000
            return value == value.rounded()
                ? "\(Int(value))Ah"
                : String(format: "%.1fAh", value)
        }
    }

    private enum Suffix {
        static let profile = "profile"
        static let capacity = "capacity"
        static let time = "time"
        static let prewriteProfile = "prewrite_profile"
        static let prewriteCapacity = "prewrite_capacity"
        static let prewriteTime = "prewrite_time"
        static let prewriteDis92 = "prewrite_dis92"
        static let dis92Original = "dis92_original"
        static let lastConfirmedProfile = "last_confirmed_profile"
        static let lastConfirmedTime = "last_confirmed_time"
        static let ratedCapacity = "rated_capacity"
        static let prewriteRatedCapacity = "prewrite_rated_capacity"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Keys

    /// Android replaced the MAC's colons with underscores. The serial has no
    /// separators, so it is used as-is — but an empty serial is refused outright
    /// rather than silently sharing one bucket across every vehicle.
    private func key(_ serial: String, _ suffix: String) -> String? {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "\(trimmed)_\(suffix)"
    }

    private func flag(_ serial: String, _ suffix: String) -> Bool {
        guard let key = key(serial, suffix) else { return false }
        return defaults.object(forKey: key) != nil
    }

    // MARK: - First backup (written once, never overwritten)

    public func firstBackup(serial: String) -> Backup {
        Backup(profile: intValue(serial, Suffix.profile),
               capacity: intValue(serial, Suffix.capacity),
               time: int64Value(serial, Suffix.time))
    }

    /// Only the pre-operation state is used to create this one, so it stays the
    /// original parameters no matter how many writes follow.
    public func saveFirstBackupIfAbsent(serial: String, profile: Int, capacity: Int) {
        guard profile >= 0, capacity > 0 else { return }
        guard !flag(serial, Suffix.profile), !flag(serial, Suffix.capacity) else { return }
        guard let profileKey = key(serial, Suffix.profile),
              let capacityKey = key(serial, Suffix.capacity),
              let timeKey = key(serial, Suffix.time) else { return }
        defaults.set(profile, forKey: profileKey)
        defaults.set(capacity, forKey: capacityKey)
        defaults.set(Self.nowMillis(), forKey: timeKey)
    }

    public func saveDisConfigBackupIfAbsent(serial: String, raw: Int) {
        guard DisVoltageConfig.nominalVoltage(raw) >= 0 else { return }
        guard !flag(serial, Suffix.dis92Original),
              let key = key(serial, Suffix.dis92Original) else { return }
        defaults.set(raw, forKey: key)
    }

    public func disConfigBackup(serial: String) -> Int {
        intValue(serial, Suffix.dis92Original)
    }

    // MARK: - Rated capacity register (0x0E)

    /// The capacity word as it stood before any write by this tool.
    ///
    /// Kept separately from the profile/capacity pair above because it is a
    /// different physical register with its own rollback requirement: restoring
    /// the profile does not restore 0x0E, and leaving the two disagreeing is
    /// exactly the state the vehicle corrects on its own.
    public func ratedCapacityBackup(serial: String) -> Int {
        intValue(serial, Suffix.ratedCapacity)
    }

    public func saveRatedCapacityBackupIfAbsent(serial: String, raw: Int) {
        guard raw > 0 else { return }
        guard !flag(serial, Suffix.ratedCapacity),
              let key = key(serial, Suffix.ratedCapacity) else { return }
        defaults.set(raw, forKey: key)
    }

    /// Replaced on every capacity write, so a rollback targets the value that was
    /// actually there immediately before the last one.
    public func prewriteRatedCapacity(serial: String) -> Int {
        intValue(serial, Suffix.prewriteRatedCapacity)
    }

    @discardableResult
    public func savePrewriteRatedCapacity(serial: String, raw: Int) -> Bool {
        guard raw > 0, let key = key(serial, Suffix.prewriteRatedCapacity) else { return false }
        defaults.set(raw, forKey: key)
        return true
    }

    // MARK: - Pre-write snapshot (replaced on every write)

    public func prewriteBackup(serial: String) -> Backup {
        Backup(profile: intValue(serial, Suffix.prewriteProfile),
               capacity: intValue(serial, Suffix.prewriteCapacity),
               time: int64Value(serial, Suffix.prewriteTime))
    }

    /// The dashboard config as it stood immediately before the last write, or -1.
    ///
    /// Distinct from `disConfigBackup`, which is the *original* value captured
    /// once and never overwritten: this one is replaced on every write, so it is
    /// the value a dashboard write would have to put back.
    public func prewriteDisConfig(serial: String) -> Int {
        intValue(serial, Suffix.prewriteDis92)
    }

    /// Records the parameters as they were immediately before a write.
    ///
    /// Returns `false` when the snapshot could not be persisted and read back
    /// intact, which the caller must treat as a reason to abort the write rather
    /// than proceed without a way back.
    @discardableResult
    public func savePrewriteSnapshot(serial: String, profile: Int, capacity: Int,
                              disConfigRaw: Int) -> Bool {
        guard let timeKey = key(serial, Suffix.prewriteTime) else { return false }
        let stamp = Self.nowMillis()
        defaults.set(stamp, forKey: timeKey)

        if profile >= 0, capacity > 0,
           let profileKey = key(serial, Suffix.prewriteProfile),
           let capacityKey = key(serial, Suffix.prewriteCapacity) {
            defaults.set(profile, forKey: profileKey)
            defaults.set(capacity, forKey: capacityKey)
        }
        if disConfigRaw >= 0, let key = key(serial, Suffix.prewriteDis92) {
            defaults.set(disConfigRaw, forKey: key)
        }

        // The snapshot doubles as a chance to establish the permanent backups.
        saveFirstBackupIfAbsent(serial: serial, profile: profile, capacity: capacity)
        saveDisConfigBackupIfAbsent(serial: serial, raw: disConfigRaw)

        defaults.synchronize()

        // Android verified each field survived the commit; a snapshot that did
        // not land is indistinguishable from having no backup at all.
        guard int64Value(serial, Suffix.prewriteTime) == stamp else { return false }
        if profile >= 0, capacity > 0 {
            guard intValue(serial, Suffix.prewriteProfile) == profile,
                  intValue(serial, Suffix.prewriteCapacity) == capacity else { return false }
        }
        if disConfigRaw >= 0 {
            guard intValue(serial, Suffix.prewriteDis92) == disConfigRaw else { return false }
        }
        return true
    }

    // MARK: - Last confirmed target

    public func saveLastConfirmed(serial: String, profile: Int) {
        guard let profileKey = key(serial, Suffix.lastConfirmedProfile),
              let timeKey = key(serial, Suffix.lastConfirmedTime) else { return }
        defaults.set(profile, forKey: profileKey)
        defaults.set(Self.nowMillis(), forKey: timeKey)
    }

    public func lastConfirmedProfile(serial: String) -> Int {
        intValue(serial, Suffix.lastConfirmedProfile)
    }

    /// The page only offers the second restore button when the two backups
    /// actually disagree; offering a choice between identical values is noise.
    public func alternativesDiffer(serial: String) -> Bool {
        let first = firstBackup(serial: serial)
        let recent = prewriteBackup(serial: serial)
        guard first.valid, recent.valid else { return false }
        return first.profile != recent.profile || first.capacity != recent.capacity
    }

    /// Drops every entry belonging to one vehicle. Used when the user clears
    /// local data: leaving a backup behind would keep offering a restore for a
    /// vehicle whose credentials are gone.
    public func clear(serial: String) {
        let suffixes = [Suffix.profile, Suffix.capacity, Suffix.time,
                        Suffix.prewriteProfile, Suffix.prewriteCapacity, Suffix.prewriteTime,
                        Suffix.prewriteDis92, Suffix.dis92Original,
                        Suffix.lastConfirmedProfile, Suffix.lastConfirmedTime]
        for suffix in suffixes {
            guard let key = key(serial, suffix) else { continue }
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Primitives

    private func intValue(_ serial: String, _ suffix: String) -> Int {
        guard let key = key(serial, suffix), defaults.object(forKey: key) != nil else { return -1 }
        return defaults.integer(forKey: key)
    }

    private func int64Value(_ serial: String, _ suffix: String) -> Int64 {
        guard let key = key(serial, suffix), defaults.object(forKey: key) != nil else { return 0 }
        return Int64(defaults.integer(forKey: key))
    }

    private static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
