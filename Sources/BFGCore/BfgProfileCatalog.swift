/// Port of `com.bfgtools.calibration.core.BfgProfileCatalog`.
/// Shared, statically audited BFG Profile table.
public enum BfgProfileCatalog {
    private static let coreByIndex: [Int] = [
        20000, 10500, 18000, 36000,
        10500, 26000, 14000, 38000,
        13000, 22000, 39000, 45000,
        46000, 55000, 52000, 18000
    ]

    /// Every capacity the firmware table names, ascending and deduplicated.
    ///
    /// Used by the capacity sweep, which only ever tries values the firmware
    /// already ships with. That matters: a refusal then means "this module does
    /// not accept this known configuration", not "it disliked an arbitrary
    /// number", and the answer stays comparable across vehicles.
    public static var tabulatedCapacities: [Int] {
        Array(Set(coreByIndex)).sorted()
    }

    public static func expectedCore(_ profile: Int) -> Int {
        let value = profile & 0xFF
        let voltageCode = value & 0x0F
        let index = (value >> 4) & 0x0F
        if voltageCode < 0 || voltageCode > 2 { return -1 }

        // Confirmed voltage-specific exception in the BFG Profile table.
        if index == 5 && voltageCode == 2 { return 24500 }
        return coreByIndex[index]
    }

    public static func nominalVoltage(_ profile: Int) -> Int {
        switch profile & 0x0F {
        case 0: return 72
        case 1: return 60
        case 2: return 48
        default: return -1
        }
    }

    /// Voltage code carried in the low nibble of a profile byte.
    public static func voltageCode(forVoltage voltage: Int) -> Int {
        switch voltage {
        case 72: return 0
        case 48: return 2
        default: return 1
        }
    }

    /// Resolves the picker's `(voltage, capacity)` choice back into a profile.
    ///
    /// Port of the resolution in `MainActivity.performPrototypeWrite`. The
    /// firmware table holds duplicate effective capacities, so a still-valid
    /// current index wins; otherwise the lowest matching index is taken.
    /// Returns -1 when the capacity is not part of this voltage's table.
    public static func profileIndex(requestedMilliAh: Int, voltageCode: Int,
                                    preferring currentIndex: Int) -> Int {
        if currentIndex >= 0,
           expectedCore((currentIndex << 4) | voltageCode) == requestedMilliAh {
            return currentIndex
        }
        for index in 0...0xF where expectedCore((index << 4) | voltageCode) == requestedMilliAh {
            return index
        }
        return -1
    }

    /// Whether a capacity is one this table can name at all.
    ///
    /// Used to tell two very different situations apart. A vehicle whose capacity
    /// registers hold a *tabulated* value is one this table describes — its
    /// profile byte and its capacity registers have simply drifted apart, which
    /// is what a wrong or partial write leaves behind and what a correct write
    /// repairs. A vehicle holding a value the table cannot name is one the table
    /// genuinely does not describe, and writing from it would put the wrong
    /// capacity on the vehicle.
    public static func isTabulated(_ milliAh: Int) -> Bool {
        guard milliAh > 0 else { return false }
        return milliAh == 24500 || coreByIndex.contains(milliAh)
    }

    /// The byte that actually goes on the wire for a picker choice.
    ///
    /// The two are not the same thing and confusing them is silent: the table
    /// index alone (5 for 26Ah) is a *legal-looking* byte whose voltage nibble
    /// then reads as 5, which no firmware accepts. Writing the bare index sent
    /// 0x05 where 0x50 was meant, so the vehicle rejected every write and read
    /// back its old value — the failure looked like an old vehicle refusing to
    /// be written, not like a bug. Callers must use this, never profileIndex.
    /// Returns -1 when the capacity is not part of that voltage's table.
    public static func profileByte(requestedMilliAh: Int, voltageCode: Int,
                                   preferring currentIndex: Int) -> Int {
        let index = profileIndex(requestedMilliAh: requestedMilliAh,
                                 voltageCode: voltageCode,
                                 preferring: currentIndex)
        guard index >= 0 else { return -1 }
        return (index << 4) | voltageCode
    }
}
