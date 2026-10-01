import Foundation

/// A full snapshot of a vehicle's register space, taken so that a write can be
/// measured against it.
///
/// The protocol exposes no way to read the firmware itself — the original
/// client states plainly that it implements no OTA or arbitrary NVM access.
/// What *is* reachable is the register space, and that is enough for the two
/// things that actually matter here:
///
///   * **Adaptation.** The static profile table may not describe a given
///     firmware revision. Comparing what the vehicle reports against the table
///     turns that from an invisible assumption into a check.
///   * **Collateral damage.** Dumping before and after a write shows whether
///     anything moved besides the address that was targeted, which is the
///     clearest early warning that a write reached further than intended.
public struct RegisterDump: Codable, Equatable {

    /// Firmware versions, which together identify the build this dump describes.
    public struct Fingerprint: Codable, Equatable {
        public let dashboard: Int
        public let colorDisplay: Int
        public let centre: Int
        public let meter: Int

        public init(dashboard: Int, colorDisplay: Int, centre: Int, meter: Int) {
            self.dashboard = dashboard
            self.colorDisplay = colorDisplay
            self.centre = centre
            self.meter = meter
        }

        /// `D2-1-5-5_C5-1-2-1_...`, used as a key for "same build" comparisons.
        public var identifier: String {
            "D\(dashboard)_C\(colorDisplay)_M\(centre)_F\(meter)"
        }

        /// All four versions read successfully.
        public var isComplete: Bool {
            dashboard >= 0 && colorDisplay >= 0 && centre >= 0 && meter >= 0
        }
    }

    public struct Entry: Codable, Equatable {
        public let module: Int
        public let index: Int
        public let length: Int
        public let value: Int
        /// Read twice with the same result. An unstable register is one whose
        /// value cannot be relied on — including as a backup.
        public let stable: Bool
        public let responded: Bool

        public init(module: Int, index: Int, length: Int, value: Int,
                    stable: Bool, responded: Bool) {
            self.module = module
            self.index = index
            self.length = length
            self.value = value
            self.stable = stable
            self.responded = responded
        }
    }

    public struct Change: Equatable {
        public let module: Int
        public let index: Int
        public let before: Int
        public let after: Int

        public init(module: Int, index: Int, before: Int, after: Int) {
            self.module = module
            self.index = index
            self.before = before
            self.after = after
        }
    }

    public static let dashboardModule = 0x01
    public static let meterModule = 0x10
    /// Probed in addition to the two the original scans: the BLE board and the
    /// centre controller both answer on the same bus.
    public static let probedModules = [0x01, 0x04, 0x09, 0x10]

    public let serial: String
    public let fingerprint: Fingerprint
    public let timestamp: Int64
    public let entries: [Entry]

    public init(serial: String, fingerprint: Fingerprint, timestamp: Int64,
                entries: [Entry]) {
        self.serial = serial
        self.fingerprint = fingerprint
        self.timestamp = timestamp
        self.entries = entries
    }

    // MARK: - Queries

    public func entry(module: Int, index: Int) -> Entry? {
        entries.first { $0.module == module && $0.index == index }
    }

    /// Addresses that answered at all, for a compact summary.
    public var respondedCount: Int { entries.filter(\.responded).count }

    /// Addresses that answered differently when read twice. Any of these in a
    /// module about to be written means the backup cannot be trusted.
    public var unstable: [Entry] { entries.filter { $0.responded && !$0.stable } }

    public func respondedCount(module: Int) -> Int {
        entries.filter { $0.module == module && $0.responded }.count
    }

    /// Whether every address of `module` was read back consistently. A module
    /// with unreadable or unstable addresses cannot be backed up.
    public func isFullyReadable(module: Int) -> Bool {
        let moduleEntries = entries.filter { $0.module == module }
        guard !moduleEntries.isEmpty else { return false }
        return moduleEntries.allSatisfy { $0.responded && $0.stable }
    }

    /// Addresses whose value differs between two dumps. Entries present in only
    /// one dump are reported with `-1` on the missing side.
    public func changes(from other: RegisterDump) -> [Change] {
        var result: [Change] = []
        let keys = Set(entries.map { [$0.module, $0.index] })
            .union(other.entries.map { [$0.module, $0.index] })
        for key in keys {
            let module = key[0], index = key[1]
            let a = other.entry(module: module, index: index)
            let b = entry(module: module, index: index)
            let before = (a?.responded ?? false) ? a!.value : -1
            let after = (b?.responded ?? false) ? b!.value : -1
            if before != after {
                result.append(Change(module: module, index: index,
                                     before: before, after: after))
            }
        }
        return result.sorted { ($0.module, $0.index) < ($1.module, $1.index) }
    }

    // MARK: - Adaptation

    /// What this vehicle reports for a profile, versus what the static table
    /// claims. A mismatch means the table does not describe this firmware, and
    /// writing from it would put the wrong capacity on the vehicle.
    public enum TableAgreement: Equatable {
        case agrees
        /// The table and the vehicle disagree; `reported` is what the vehicle
        /// actually holds.
        case disagrees(expected: Int, reported: Int)
        /// One of the two values could not be read, so nothing can be concluded.
        case inconclusive
    }

    public func agreement() -> TableAgreement {
        guard let profileEntry = entry(module: RegisterDump.meterModule, index: 0x00),
              profileEntry.responded, profileEntry.stable else { return .inconclusive }
        guard let capacityEntry = entry(module: RegisterDump.meterModule, index: 0x1C),
              capacityEntry.responded, capacityEntry.stable else { return .inconclusive }

        let expected = BfgProfileCatalog.expectedCore(profileEntry.value)
        guard expected > 0 else { return .inconclusive }

        // The vehicle's own capacity register is the primary witness, but a
        // meter that has never measured — a lithium pack on a lead-acid module,
        // for instance — reports 0 there. That is "no measurement", not "0 mAh",
        // and calling it a disagreement turned every such vehicle into an
        // unexplained refusal. Fall back to the register pair the compatibility
        // scan already trusts, and stay inconclusive only when both are silent.
        let reported: Int
        if capacityEntry.value > 0 {
            reported = capacityEntry.value
        } else if let fallback = entry(module: RegisterDump.meterModule, index: 0x0E),
                  fallback.responded, fallback.stable, fallback.value > 0 {
            reported = fallback.value
        } else {
            return .inconclusive
        }
        return expected == reported ? .agrees : .disagrees(expected: expected, reported: reported)
    }

    // MARK: - Serialisation

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RegisterDump {
        try JSONDecoder().decode(RegisterDump.self, from: data)
    }
}
