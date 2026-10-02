import XCTest
@testable import BFGCore

final class RegisterDumpTests: XCTestCase {

    private func entry(_ module: Int, _ index: Int, _ value: Int,
                       stable: Bool = true, responded: Bool = true) -> RegisterDump.Entry {
        RegisterDump.Entry(module: module, index: index, length: 2, value: value,
                           stable: stable, responded: responded)
    }

    private func dump(_ entries: [RegisterDump.Entry],
                      meter: Int = 0x0429) -> RegisterDump {
        RegisterDump(serial: "BFGTEST0000001",
                     fingerprint: .init(dashboard: 0x0259, colorDisplay: 0x0155,
                                        centre: 0x05CA, meter: meter),
                     timestamp: 1_700_000_000_000,
                     entries: entries)
    }

    // MARK: - Diff

    func testDiffReportsOnlyChangedAddresses() {
        let before = dump([entry(0x10, 0x00, 0x31), entry(0x10, 0x1C, 26000),
                           entry(0x01, 0x92, 0xC2)])
        let after = dump([entry(0x10, 0x00, 0x21), entry(0x10, 0x1C, 26000),
                          entry(0x01, 0x92, 0xC2)])

        let changes = after.changes(from: before)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].module, 0x10)
        XCTAssertEqual(changes[0].index, 0x00)
        XCTAssertEqual(changes[0].before, 0x31)
        XCTAssertEqual(changes[0].after, 0x21)
    }

    /// The point of the whole comparison: a write that disturbs more than its
    /// target has to be visible.
    func testDiffFlagsCollateralChanges() {
        let before = dump([entry(0x10, 0x00, 0x31), entry(0x10, 0x1C, 26000),
                           entry(0x10, 0x1E, 26000)])
        let after = dump([entry(0x10, 0x00, 0x21), entry(0x10, 0x1C, 18000),
                          entry(0x10, 0x1E, 26000)])

        let changes = after.changes(from: before)
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.contains { $0.index == 0x1C && $0.after == 18000 })
    }

    func testDiffIgnoresUnchangedAndOrdersByAddress() {
        let before = dump([entry(0x09, 0x02, 1), entry(0x01, 0x1A, 1), entry(0x10, 0x00, 1)])
        let after = dump([entry(0x09, 0x02, 2), entry(0x01, 0x1A, 2), entry(0x10, 0x00, 1)])
        let changes = after.changes(from: before)
        XCTAssertEqual(changes.map { [$0.module, $0.index] }, [[0x01, 0x1A], [0x09, 0x02]])
    }

    /// A register that stopped answering is a change, not an absence.
    func testDiffTreatsLostResponseAsChange() {
        let before = dump([entry(0x10, 0x00, 0x31)])
        let after = dump([entry(0x10, 0x00, 0, responded: false)])
        let changes = after.changes(from: before)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].after, -1)
    }

    // MARK: - Readability

    func testModuleFullyReadableRequiresEveryAddress() {
        let entries = (0..<4).map { entry(0x10, $0, 1) }
        XCTAssertTrue(dump(entries).isFullyReadable(module: 0x10))

        let withTimeout = (0..<3).map { entry(0x10, $0, 1) }
            + [entry(0x10, 3, 0, responded: false)]
        XCTAssertFalse(dump(withTimeout).isFullyReadable(module: 0x10))
    }

    /// A register that reads differently twice cannot serve as a backup.
    func testUnstableRegisterBlocksReadability() {
        let entries = [entry(0x10, 0x00, 0x31), entry(0x10, 0x1C, 26000, stable: false)]
        let d = dump(entries)
        XCTAssertFalse(d.isFullyReadable(module: 0x10))
        XCTAssertEqual(d.unstable.map(\.index), [0x1C])
    }

    func testUnknownModuleIsNotReadable() {
        XCTAssertFalse(dump([entry(0x10, 0x00, 1)]).isFullyReadable(module: 0x04))
    }

    // MARK: - Table agreement

    /// 0x51 is index 5 at 60V, which the static table puts at 26000.
    func testAgreementWhenVehicleMatchesTheTable() {
        let d = dump([entry(0x10, 0x00, 0x51), entry(0x10, 0x1C, 26000)])
        XCTAssertEqual(d.agreement(), .agrees)
    }

    /// The case that matters: the vehicle holds a capacity the table cannot
    /// name, so the table does not describe this firmware and writing from it
    /// would put the wrong capacity on the vehicle.
    func testDisagreementIsDetectedWhenTheVehicleIsOffTable() {
        let d = dump([entry(0x10, 0x00, 0x51), entry(0x10, 0x1C, 21000)])
        XCTAssertEqual(d.agreement(),
                       .disagrees(expected: 26000, reported: 21000))
    }

    /// The state the real vehicle was in and the reason this rule had to change:
    /// its profile byte still read 0x50 (26000 on this table) while its capacity
    /// registers read 20000 — a value the table names, index 0. That is a drifted
    /// pair, not a foreign firmware, and refusing there left no way out: the only
    /// action that repairs the vehicle is the write the refusal forbids.
    func testDriftedButTabulatedCapacityIsNotADisagreement() {
        let d = dump([entry(0x10, 0x00, 0x50), entry(0x10, 0x1C, 0),
                      entry(0x10, 0x0E, 20000)])
        XCTAssertEqual(d.agreement(), .inconclusive)
    }

    /// 20000 is index 0 of the table, so it is a capacity the table can name.
    func testTabulatedCapacitiesAreRecognised() {
        XCTAssertTrue(BfgProfileCatalog.isTabulated(20000))
        XCTAssertTrue(BfgProfileCatalog.isTabulated(26000))
        XCTAssertTrue(BfgProfileCatalog.isTabulated(46000))
        // The table's one voltage-specific exception.
        XCTAssertTrue(BfgProfileCatalog.isTabulated(24500))
        XCTAssertFalse(BfgProfileCatalog.isTabulated(21000))
        XCTAssertFalse(BfgProfileCatalog.isTabulated(50000))
        XCTAssertFalse(BfgProfileCatalog.isTabulated(0))
        XCTAssertFalse(BfgProfileCatalog.isTabulated(-1))
    }

    func testAgreementIsInconclusiveWithoutBothReadings() {
        XCTAssertEqual(dump([entry(0x10, 0x00, 0x51)]).agreement(), .inconclusive)
        XCTAssertEqual(dump([entry(0x10, 0x1C, 26000)]).agreement(), .inconclusive)
        XCTAssertEqual(
            dump([entry(0x10, 0x00, 0x51), entry(0x10, 0x1C, 26000, stable: false)])
                .agreement(),
            .inconclusive)
    }

    /// Index 5 is 24500 at 48V rather than the table's 26000, so a vehicle
    /// holding that is agreeing, not disagreeing.
    func testVoltageSpecificExceptionStillAgrees() {
        let d = dump([entry(0x10, 0x00, 0x52), entry(0x10, 0x1C, 24500)])
        XCTAssertEqual(d.agreement(), .agrees)
    }

    // MARK: - Fingerprint and serialisation

    func testFingerprintIdentifierDistinguishesBuilds() {
        let a = dump([], meter: 0x0429).fingerprint
        let b = dump([], meter: 0x0286).fingerprint
        XCTAssertNotEqual(a.identifier, b.identifier)
        XCTAssertTrue(a.isComplete)
        XCTAssertFalse(RegisterDump.Fingerprint(dashboard: -1, colorDisplay: 0,
                                                centre: 0, meter: 0).isComplete)
    }

    func testRoundTripsThroughJSON() throws {
        let original = dump([entry(0x10, 0x00, 0x31), entry(0x10, 0x1C, 26000, stable: false),
                             entry(0x04, 0x01, 0, responded: false)])
        let restored = try RegisterDump.decode(try original.json())
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.unstable.map(\.index), [0x1C])
    }
}
