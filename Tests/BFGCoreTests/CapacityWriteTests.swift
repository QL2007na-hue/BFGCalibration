import XCTest
@testable import BFGCore

/// The second write site, pinned from the outside.
///
/// Every other test in this suite guards a *policy* decision. These guard a
/// physical one: there is now a second place the tool can put bytes on the wire,
/// aimed at the register the state-of-charge is computed from. The assertions
/// below exist so that widening it cannot happen by accident — the address is a
/// literal in the builder, the value must be plausible, and the switch that
/// permits it is off unless someone turns it on.
final class CapacityWriteTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WriteAccessPolicy.allowsCapacityWrite = false
        WriteAccessPolicy.expertMode = false
    }

    override func tearDown() {
        WriteAccessPolicy.allowsCapacityWrite = false
        WriteAccessPolicy.expertMode = false
        super.tearDown()
    }

    // MARK: - Frame bytes

    /// 55000 is 0xD6D8; the wire carries it little-endian, matching readLe16.
    func testFrameEncodesLittleEndian() {
        XCTAssertEqual(NinebotFrame.writeCapacityRated(55000),
                       [0x5A, 0xA5, 0x02, 0x3E, 0x10, 0x02, 0x0E, 0xD8, 0xD6])
    }

    func testFrameForTheVehiclesCurrentValue() {
        XCTAssertEqual(NinebotFrame.writeCapacityRated(26000),
                       [0x5A, 0xA5, 0x02, 0x3E, 0x10, 0x02, 0x0E, 0x90, 0x65])
    }

    /// The address is a literal, never a parameter. This test fails the moment
    /// someone makes the builder generic — which is exactly when it should fail.
    func testAddressCannotBeInfluencedByTheValue() {
        for value in [0, 1, 255, 256, 5000, 65535, 999_999, -1] {
            let frame = NinebotFrame.writeCapacityRated(value)
            XCTAssertEqual(frame[6], 0x0E, "index drifted for value \(value)")
            XCTAssertEqual(frame[5], 0x02, "cmd drifted for value \(value)")
            XCTAssertEqual(frame[4], 0x10, "destination drifted for value \(value)")
            XCTAssertEqual(frame.count, 9)
        }
    }

    func testValueIsClampedInto16Bits() {
        XCTAssertEqual(NinebotFrame.writeCapacityRated(-5)[7], 0x00)
        XCTAssertEqual(NinebotFrame.writeCapacityRated(999_999).count, 9)
    }

    func testCapacityWriteIndexMatchesTheBuilder() {
        XCTAssertEqual(NinebotFrame.capacityWriteIndex, 0x0E)
        XCTAssertEqual(NinebotFrame.writeCapacityRated(1234)[6],
                       UInt8(NinebotFrame.capacityWriteIndex))
        XCTAssertEqual(WriteAccessPolicy.capacityWriteIndex, NinebotFrame.capacityWriteIndex)
    }

    // MARK: - Policy: off unless asked, and separate from expert mode

    func testCapacityWriteIsOffByDefault() {
        XCTAssertFalse(WriteAccessPolicy.allowsCapacityWrite)
        XCTAssertFalse(WriteAccessPolicy.isWritableCapacity(55000))
    }

    /// The two switches must stay independent. Expert mode releases "unvalidated",
    /// not "write to another register" — conflating them would silently hand every
    /// expert-mode rider a second write site they never agreed to.
    func testExpertModeDoesNotImplyCapacityWrite() {
        WriteAccessPolicy.expertMode = true
        XCTAssertFalse(WriteAccessPolicy.allowsCapacityWrite)
        XCTAssertFalse(WriteAccessPolicy.isWritableCapacity(55000))
    }

    func testBoundsMatchTheReadSideResolver() {
        WriteAccessPolicy.allowsCapacityWrite = true
        XCTAssertFalse(WriteAccessPolicy.isWritableCapacity(4999))
        XCTAssertTrue(WriteAccessPolicy.isWritableCapacity(5000))
        XCTAssertTrue(WriteAccessPolicy.isWritableCapacity(55000))
        XCTAssertTrue(WriteAccessPolicy.isWritableCapacity(100_000))
        XCTAssertFalse(WriteAccessPolicy.isWritableCapacity(100_001))
        XCTAssertFalse(WriteAccessPolicy.isWritableCapacity(0))
        XCTAssertFalse(WriteAccessPolicy.isWritableCapacity(-1))
    }

    /// Bounds are shared with the read path on purpose: a value the tool would
    /// refuse to believe is a value it must refuse to write.
    func testBoundsAgreeWithCapacityCompatibilityResolver() {
        for value in [0, 1, 4999, 5000, 26000, 55000, 100_000, 100_001, 200_000] {
            XCTAssertEqual(WriteAccessPolicy.isWritableCapacity(value) && WriteAccessPolicy.allowsCapacityWrite,
                           CapacityCompatibilityResolver.isPlausible(value) && WriteAccessPolicy.allowsCapacityWrite,
                           "disagreement at \(value)")
        }
    }

    // MARK: - Backup slots

    func testRatedCapacitySlotsAreSeparateFromProfileSlots() {
        let defaults = UserDefaults(suiteName: "capacity-write-tests")!
        defaults.removePersistentDomain(forName: "capacity-write-tests")
        let store = BackupStore(defaults: defaults)
        XCTAssertEqual(store.ratedCapacityBackup(serial: "TEST123"), -1)
        store.saveRatedCapacityBackupIfAbsent(serial: "TEST123", raw: 26000)
        XCTAssertEqual(store.ratedCapacityBackup(serial: "TEST123"), 26000)
        // First value is written once and never replaced.
        store.saveRatedCapacityBackupIfAbsent(serial: "TEST123", raw: 55000)
        XCTAssertEqual(store.ratedCapacityBackup(serial: "TEST123"), 26000)
        // Pre-write slot is replaced on every write.
        XCTAssertTrue(store.savePrewriteRatedCapacity(serial: "TEST123", raw: 26000))
        XCTAssertTrue(store.savePrewriteRatedCapacity(serial: "TEST123", raw: 55000))
        XCTAssertEqual(store.prewriteRatedCapacity(serial: "TEST123"), 55000)
        // And it does not touch the profile/capacity pair.
        XCTAssertFalse(store.firstBackup(serial: "TEST123").valid)
    }

    func testZeroIsNeverAcceptedAsABackup() {
        let defaults = UserDefaults(suiteName: "capacity-write-tests-2")!
        defaults.removePersistentDomain(forName: "capacity-write-tests-2")
        let store = BackupStore(defaults: defaults)
        store.saveRatedCapacityBackupIfAbsent(serial: "T2", raw: 0)
        XCTAssertEqual(store.ratedCapacityBackup(serial: "T2"), -1)
        XCTAssertFalse(store.savePrewriteRatedCapacity(serial: "T2", raw: 0))
    }

    // MARK: - Probe register allowlist

    /// A probe writes a register its own current value back, so a successful
    /// probe changes nothing. What it must never do is reach an address nobody
    /// vetted, which is why the builder checks the allowlist itself.
    func testProbeBuilderRefusesAddressesOffTheAllowlist() {
        for register in [0x00, 0x01, 0x02, 0x0C, 0x1C + 1, 0xFF, -1] {
            XCTAssertNil(NinebotFrame.writeBfgWord(register: register, value: 26000),
                         "builder accepted unvetted register \(register)")
        }
    }

    func testProbeBuilderAcceptsTheAllowlist() {
        for register in WriteAccessPolicy.probeRegisterAllowlist {
            let frame = NinebotFrame.writeBfgWord(register: register, value: 26000)
            XCTAssertNotNil(frame)
            XCTAssertEqual(frame?.count, 9)
            XCTAssertEqual(frame?[6], UInt8(register))
            XCTAssertEqual(frame?[5], 0x02)
            XCTAssertEqual(frame?[4], 0x10)
        }
    }

    func testProbeAllowlistStaysClosed() {
        XCTAssertEqual(WriteAccessPolicy.probeRegisterAllowlist,
                       CapacityCompatibilityResolver.registers,
                       "probe targets drifted from the registers the read side trusts")
    }

    func testProbeIsOffByDefaultAndIndependent() {
        XCTAssertFalse(WriteAccessPolicy.allowsRegisterProbe)
        XCTAssertFalse(WriteAccessPolicy.canProbe(register: 0x0E))
        WriteAccessPolicy.expertMode = true
        XCTAssertFalse(WriteAccessPolicy.canProbe(register: 0x0E))
        WriteAccessPolicy.allowsCapacityWrite = true
        XCTAssertFalse(WriteAccessPolicy.canProbe(register: 0x0E))
        WriteAccessPolicy.allowsRegisterProbe = true
        XCTAssertTrue(WriteAccessPolicy.canProbe(register: 0x0E))
        XCTAssertFalse(WriteAccessPolicy.canProbe(register: 0x00))
    }

    func testProbeWordIsLittleEndian() {
        XCTAssertEqual(NinebotFrame.writeBfgWord(register: 0x0F, value: 26000),
                       [0x5A, 0xA5, 0x02, 0x3E, 0x10, 0x02, 0x0F, 0x90, 0x65])
    }

    // MARK: - Capacity sweep

    /// A sweep must start at the vehicle own value: the first candidate is the
    /// baseline itself, so a run that is interrupted before any real change has
    /// still written nothing the vehicle did not already hold.
    func testSweepStartsAtTheVehicleValue() {
        let c = WriteAccessPolicy.sweepCandidates(from: 26000)
        XCTAssertEqual(c.first, 26000)
        XCTAssertTrue(c.allSatisfy { $0 >= 26000 })
        XCTAssertEqual(c, c.sorted(), "candidates must ascend")
    }

    /// Only firmware-table values. A refusal then means "this module does not
    /// accept this known configuration" rather than "it disliked a number".
    func testSweepUsesOnlyTabulatedCapacities() {
        let table = Set(BfgProfileCatalog.tabulatedCapacities)
        for current in [0, 10500, 26000, 45000, 55000, 99999] {
            for v in WriteAccessPolicy.sweepCandidates(from: current) {
                XCTAssertTrue(table.contains(v), "candidate \(v) is not in the table")
            }
        }
    }

    func testTabulatedCapacitiesAreSortedAndUnique() {
        let t = BfgProfileCatalog.tabulatedCapacities
        XCTAssertEqual(t, t.sorted())
        XCTAssertEqual(t.count, Set(t).count)
        XCTAssertTrue(t.contains(26000))
        XCTAssertTrue(t.contains(55000))
        XCTAssertTrue(t.contains(10500))
    }

    func testSweepCandidatesAreEmptyAboveTheLargestTabulatedValue() {
        XCTAssertTrue(WriteAccessPolicy.sweepCandidates(from: 55001).isEmpty)
        XCTAssertEqual(WriteAccessPolicy.sweepCandidates(from: 55000), [55000])
    }

    /// The fifth switch is independent of the other four.
    func testSweepIsOffByDefaultAndIndependent() {
        XCTAssertFalse(WriteAccessPolicy.allowsCapacitySweep)
        WriteAccessPolicy.expertMode = true
        XCTAssertFalse(WriteAccessPolicy.allowsCapacitySweep)
        WriteAccessPolicy.allowsCapacityWrite = true
        XCTAssertFalse(WriteAccessPolicy.allowsCapacitySweep)
        WriteAccessPolicy.allowsRegisterProbe = true
        XCTAssertFalse(WriteAccessPolicy.allowsCapacitySweep)
    }

    /// A sweep writes values it did not read, so its frame builder must still be
    /// the allowlist-gated one — a sweep is not a licence to write elsewhere.
    func testSweepFramesStayOnTheCapacityRegister() {
        for v in WriteAccessPolicy.sweepCandidates(from: 26000) {
            let f = NinebotFrame.writeBfgWord(register: NinebotFrame.capacityWriteIndex, value: v)
            XCTAssertNotNil(f)
            XCTAssertEqual(f?[6], 0x0E)
            XCTAssertEqual(f?.count, 9)
        }
        XCTAssertNil(NinebotFrame.writeBfgWord(register: 0x00, value: 26000),
                     "the sweep path must not be able to reach the profile byte")
    }
}
