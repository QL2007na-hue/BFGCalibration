import XCTest
@testable import BFGCore

/// Covers the reverse lookup the write flow needs: the page sends the voltage
/// and capacity the user picked, and the client has to recover the profile byte.
final class BfgProfileCatalogTests: XCTestCase {

    func testVoltageCodeMatchesTheProfileNibble() {
        XCTAssertEqual(0, BfgProfileCatalog.voltageCode(forVoltage: 72))
        XCTAssertEqual(1, BfgProfileCatalog.voltageCode(forVoltage: 60))
        XCTAssertEqual(2, BfgProfileCatalog.voltageCode(forVoltage: 48))
        // Anything else is treated as the 60V family, matching Android.
        XCTAssertEqual(1, BfgProfileCatalog.voltageCode(forVoltage: 0))
        XCTAssertEqual(1, BfgProfileCatalog.voltageCode(forVoltage: 96))
    }

    func testCapacityResolvesToItsIndex() {
        XCTAssertEqual(0, BfgProfileCatalog.profileIndex(requestedMilliAh: 20000,
                                                        voltageCode: 0, preferring: -1))
        XCTAssertEqual(3, BfgProfileCatalog.profileIndex(requestedMilliAh: 36000,
                                                        voltageCode: 1, preferring: -1))
        // 18000 sits at index 2 and index 15; without a held index the lowest wins.
        XCTAssertEqual(2, BfgProfileCatalog.profileIndex(requestedMilliAh: 18000,
                                                        voltageCode: 2, preferring: -1))
        XCTAssertEqual(15, BfgProfileCatalog.profileIndex(requestedMilliAh: 18000,
                                                         voltageCode: 2, preferring: 15))
    }

    /// 10500 appears at both index 1 and index 4; the held index must survive.
    func testDuplicateCapacityKeepsTheCurrentIndex() {
        XCTAssertEqual(4, BfgProfileCatalog.profileIndex(requestedMilliAh: 10500,
                                                        voltageCode: 0, preferring: 4))
        XCTAssertEqual(1, BfgProfileCatalog.profileIndex(requestedMilliAh: 10500,
                                                        voltageCode: 0, preferring: 1))
        XCTAssertEqual(1, BfgProfileCatalog.profileIndex(requestedMilliAh: 10500,
                                                        voltageCode: 0, preferring: -1))
    }

    /// A stale index that no longer matches the requested capacity is ignored.
    func testStaleCurrentIndexIsIgnored() {
        XCTAssertEqual(3, BfgProfileCatalog.profileIndex(requestedMilliAh: 36000,
                                                        voltageCode: 0, preferring: 1))
    }

    /// Index 5 is 24500 at 48V rather than the table's 26000.
    func testVoltageSpecificExceptionIsHonoured() {
        XCTAssertEqual(5, BfgProfileCatalog.profileIndex(requestedMilliAh: 24500,
                                                        voltageCode: 2, preferring: -1))
        XCTAssertEqual(5, BfgProfileCatalog.profileIndex(requestedMilliAh: 26000,
                                                        voltageCode: 0, preferring: -1))
        XCTAssertEqual(-1, BfgProfileCatalog.profileIndex(requestedMilliAh: 26000,
                                                         voltageCode: 2, preferring: -1))
    }

    /// The index and the wire byte are different values, and using the index as
    /// the byte is what made every real write fail: 26Ah at 72V became 0x05 —
    /// index 0 with voltage code 5, which no firmware accepts — and the vehicle
    /// answered every read-back with its unchanged 0x50.
    func testProfileByteCarriesTheIndexInItsHighNibble() {
        XCTAssertEqual(0x50, BfgProfileCatalog.profileByte(requestedMilliAh: 26000,
                                                           voltageCode: 0, preferring: -1))
        // The current index wins when it still resolves to the same capacity.
        XCTAssertEqual(0x50, BfgProfileCatalog.profileByte(requestedMilliAh: 26000,
                                                           voltageCode: 0, preferring: 5))
        XCTAssertEqual(0xC0, BfgProfileCatalog.profileByte(requestedMilliAh: 46000,
                                                           voltageCode: 0, preferring: 5))
        XCTAssertEqual(0x51, BfgProfileCatalog.profileByte(requestedMilliAh: 26000,
                                                           voltageCode: 1, preferring: -1))
        XCTAssertEqual(-1, BfgProfileCatalog.profileByte(requestedMilliAh: 12345,
                                                         voltageCode: 0, preferring: -1))
        // The exact value the real vehicle rejected.
        XCTAssertNotEqual(0x05, BfgProfileCatalog.profileByte(requestedMilliAh: 26000,
                                                              voltageCode: 0, preferring: 5))
    }

    /// Every byte this function can produce must be one the table understands,
    /// otherwise the vehicle is being sent a capacity it cannot decode.
    func testProfileByteIsAlwaysDecodable() {
        for voltage in [72, 60, 48] {
            let code = BfgProfileCatalog.voltageCode(forVoltage: voltage)
            for capacity in [10500, 13000, 18000, 20000, 22000, 26000, 36000, 38000,
                             39000, 45000, 46000, 52000, 55000] {
                let byte = BfgProfileCatalog.profileByte(requestedMilliAh: capacity,
                                                         voltageCode: code, preferring: -1)
                // The table's one voltage-specific exception is 48V index 5,
                // which is 24500 rather than 26000 — so 26Ah genuinely is not
                // offered at 48V and -1 is the right answer there. Anything else
                // being rejected would mean the table lookup is broken.
                if byte < 0 {
                    XCTAssertEqual(voltage, 48, "0x\(String(code, radix: 16)) rejected \(capacity)mAh")
                    XCTAssertEqual(capacity, 26000, "48V must reject only the exception capacity")
                    continue
                }
                XCTAssertEqual(BfgProfileCatalog.nominalVoltage(byte), voltage,
                               "byte 0x\(String(byte, radix: 16)) must decode to \(voltage)V")
                XCTAssertGreaterThan(BfgProfileCatalog.expectedCore(byte), 0,
                                     "byte 0x\(String(byte, radix: 16)) must be a known capacity")
            }
        }
    }

    func testUnknownCapacityIsRejected() {
        XCTAssertEqual(-1, BfgProfileCatalog.profileIndex(requestedMilliAh: 12345,
                                                         voltageCode: 1, preferring: -1))
        XCTAssertEqual(-1, BfgProfileCatalog.profileIndex(requestedMilliAh: 0,
                                                         voltageCode: 1, preferring: -1))
    }

    /// Every entry in the table must survive a round trip through the picker.
    /// The held index is supplied because duplicate capacities are only
    /// distinguishable by it.
    func testEveryTableEntryRoundTrips() {
        for voltageCode in 0...2 {
            for index in 0...0xF {
                let profile = (index << 4) | voltageCode
                let capacity = BfgProfileCatalog.expectedCore(profile)
                XCTAssertEqual(index,
                               BfgProfileCatalog.profileIndex(requestedMilliAh: capacity,
                                                              voltageCode: voltageCode,
                                                              preferring: index),
                               "index \(index) voltageCode \(voltageCode)")
            }
        }
    }
}
