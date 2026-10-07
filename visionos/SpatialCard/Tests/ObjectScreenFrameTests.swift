import XCTest
import simd

/// v3 H1: the screen frame read straight off the object anchor's bounding box. Object tracking does not exist
/// in the simulator, so every part of this — the axis choice, both sign decisions, the composed mapping and
/// the persistence round-trip — is checked here rather than on the wearer's headset.
final class ObjectScreenFrameTests: XCTestCase {
    /// The measured AI Passport scan: 58.6 × 94 mm of screen on a 5.2 mm slab, origin at the centre.
    private let passport = ObjectScreenFrame.Box.aiPassport

    private func pose(position: SIMD3<Float> = [0, 0.9, -0.5], eulerDeg: SIMD3<Float> = .zero) -> simd_float4x4 {
        let r = eulerDeg * (.pi / 180)
        let q = simd_quatf(angle: r.z, axis: [0, 0, 1])
            * simd_quatf(angle: r.y, axis: [0, 1, 0])
            * simd_quatf(angle: r.x, axis: [1, 0, 0])
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    private func column(_ m: simd_float4x4, _ i: Int) -> SIMD3<Float> {
        SIMD3<Float>(m[i].x, m[i].y, m[i].z)
    }

    // MARK: - Axis choice

    /// The thin axis is the screen's normal, and it is **measured** — the whole point of reading the box at
    /// runtime instead of hard-coding "+Y" from the scan the plan happened to describe.
    func testNormalAxisIsTheThinnestOne() {
        XCTAssertEqual(ObjectScreenFrame.normalAxis(extent: passport.extent), .y)
        XCTAssertEqual(ObjectScreenFrame.normalAxis(extent: [0.005, 0.06, 0.09]), .x)
        XCTAssertEqual(ObjectScreenFrame.normalAxis(extent: [0.06, 0.09, 0.005]), .z)
        // A degenerate box must not produce a singular frame: Y is the convention everything downstream uses.
        XCTAssertEqual(ObjectScreenFrame.normalAxis(extent: .zero), .y)
        XCTAssertEqual(ObjectScreenFrame.normalAxis(extent: [0.05, 0.05, 0.05]), .y)
    }

    /// +Z is the *long* remaining axis — the image-anchor convention the gate, the follower and the card
    /// layout have all been written against since v1 (+Z = the bottom edge of a portrait screen).
    func testReaderAxisIsTheLongRemainingOne() {
        XCTAssertEqual(ObjectScreenFrame.readerAxis(extent: passport.extent, normal: .y), .z)
        XCTAssertEqual(ObjectScreenFrame.readerAxis(extent: [0.094, 0.0052, 0.0586], normal: .y), .x)
    }

    // MARK: - The mapping

    /// With no flips the frame is the identity rotation and a pure 2.6 mm lift onto the top face: exactly what
    /// `Tools/fake-track-hand.json`'s `objectOffset` is written to cancel, so the harness recovers the screen
    /// pose to the last bit.
    func testUnflippedFrameIsTheTopFaceOfTheSlab() {
        let frame = ObjectScreenFrame(box: passport)
        let offset = frame.offset
        XCTAssertEqual(offset.columns.3.x, 0, accuracy: 1e-7)
        XCTAssertEqual(offset.columns.3.y, 0.0026, accuracy: 1e-7, "half of the 5.2 mm thin axis")
        XCTAssertEqual(offset.columns.3.z, 0, accuracy: 1e-7)
        XCTAssertEqual(column(offset, 0), SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(column(offset, 1), SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(column(offset, 2), SIMD3<Float>(0, 0, 1))
    }

    /// A box whose thin axis is X still produces the one frame everything downstream understands: +Y normal,
    /// +Z the long edge, right-handed.
    func testThinXBoxIsRotatedOntoTheYConvention() {
        let frame = ObjectScreenFrame(box: .init(center: .zero, extent: [0.0052, 0.0586, 0.094]))
        XCTAssertEqual(frame.axis, .x)
        let offset = frame.offset
        XCTAssertEqual(column(offset, 1), SIMD3<Float>(1, 0, 0), "the frame's +Y is the box's thin axis")
        XCTAssertEqual(column(offset, 2), SIMD3<Float>(0, 0, 1), "…and its +Z the long remaining one")
        let determinant = simd_determinant(simd_float3x3(columns: (column(offset, 0), column(offset, 1), column(offset, 2))))
        XCTAssertEqual(determinant, 1, accuracy: 1e-5, "right-handed, not mirrored")
        XCTAssertEqual(offset.columns.3.x, 0.0026, accuracy: 1e-7, "origin on the thin axis' top face")
    }

    /// The side flip turns the frame over **and moves its origin to the other face**. Rotating alone would
    /// leave the card hanging 5.2 mm inside the device — on the wrong side of the slab it is supposed to sit on.
    func testSideFlipMovesTheOriginToTheOtherFace() {
        let frame = ObjectScreenFrame(box: passport)
        let flipped = frame.offset(for: .init(side: true))
        XCTAssertEqual(flipped.columns.3.y, -0.0026, accuracy: 1e-7)
        XCTAssertEqual(column(flipped, 1), SIMD3<Float>(0, -1, 0), "the normal points the other way")
        XCTAssertEqual(column(flipped, 2), SIMD3<Float>(0, 0, -1), "a 180° turn about X takes +Z with it")
        XCTAssertEqual(column(flipped, 0), SIMD3<Float>(1, 0, 0), "…and leaves +X alone")
    }

    /// The yaw flip is a half-turn about the normal: the bottom edge moves to the other end, the normal does not.
    func testYawFlipTurnsTheFrameInItsOwnPlane() {
        let frame = ObjectScreenFrame(box: passport)
        let flipped = frame.offset(for: .init(yaw: true))
        XCTAssertEqual(flipped.columns.3.y, 0.0026, accuracy: 1e-7, "the screen is still on the same face")
        XCTAssertEqual(column(flipped, 1), SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(column(flipped, 2), SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(column(flipped, 0), SIMD3<Float>(-1, 0, 0))
        // Both together is a half-turn about Z: the two flips compose, they do not cancel.
        let both = frame.offset(for: .init(side: true, yaw: true))
        XCTAssertEqual(column(both, 0), SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(column(both, 1), SIMD3<Float>(0, -1, 0))
        XCTAssertEqual(column(both, 2), SIMD3<Float>(0, 0, 1))
    }

    // MARK: - The two decisions

    /// A passport lying face up on a desk in front of a seated reader: the screen already faces the wearer and
    /// its long axis already points at them, so nothing is flipped.
    func testFaceUpOnTheDeskInFrontOfTheReaderNeedsNoFlip() {
        let decision = ObjectScreenFrame.decision(box: passport, objectPose: pose(position: [0, 0.75, -0.5]),
                                                  headPosition: [0, 1.25, 0])
        XCTAssertFalse(decision.flips.side)
        XCTAssertFalse(decision.flips.yaw)
        XCTAssertGreaterThan(decision.headDot, 0)
    }

    /// The same device face **down** (rolled 180°): its +Y now points at the floor, so the screen is the other
    /// face of the box and the frame is turned over. This is the failure the `--screen-side` flag exists for,
    /// caught automatically.
    func testFaceDownDeviceFlipsTheSide() {
        let decision = ObjectScreenFrame.decision(box: passport,
                                                  objectPose: pose(position: [0, 0.75, -0.5], eulerDeg: [180, 0, 0]),
                                                  headPosition: [0, 1.25, 0])
        XCTAssertTrue(decision.flips.side)
        XCTAssertLessThan(decision.headDot, 0)
    }

    /// Lying flat but turned away from the reader: the side is right (it is face up) and the *yaw* is wrong —
    /// the bottom edge is pointing away, which would draw the card upside down over the device.
    func testFlatButTurnedAwayFlipsTheYaw() {
        let decision = ObjectScreenFrame.decision(box: passport,
                                                  objectPose: pose(position: [0, 0.75, -0.5], eulerDeg: [0, 180, 0]),
                                                  headPosition: [0, 1.25, 0])
        XCTAssertFalse(decision.flips.side)
        XCTAssertTrue(decision.flips.yaw)
    }

    /// Held up in front of the wearer (pitched 80° toward them, past `heldUpTilt`): "the bottom edge is the one
    /// nearer the reader" stops meaning anything, so the test becomes "the bottom edge points down".
    func testHeldUpDeviceJudgesTheYawByGravity() {
        // Pitched 80° back: the screen normal tips toward the reader and the frame's +Z swings downward.
        let upright = ObjectScreenFrame.decision(box: passport,
                                                 objectPose: pose(position: [0, 1.1, -0.4], eulerDeg: [80, 0, 0]),
                                                 headPosition: [0, 1.5, 0])
        XCTAssertGreaterThan(upright.tilt * 180 / .pi, 30, "this is the held-up branch")
        XCTAssertFalse(upright.flips.side, "the screen is facing the wearer")
        XCTAssertFalse(upright.flips.yaw, "+Z already points down")

        // The same hand, the passport rolled over in it: the screen still faces the reader (head·n 0.57) but
        // its bottom edge now points at the ceiling, so only the yaw is turned.
        let inverted = ObjectScreenFrame.decision(box: passport,
                                                  objectPose: pose(position: [0, 1.1, -0.4], eulerDeg: [80, 0, 180]),
                                                  headPosition: [0, 1.5, 0])
        XCTAssertFalse(inverted.flips.side)
        XCTAssertTrue(inverted.flips.yaw)
    }

    /// The decision is taken once and then *applied*: mapping the object pose through the chosen offset has to
    /// put the screen's normal toward the wearer, which is the property the whole H1 mapping exists for.
    func testDecidedFrameFacesTheWearer() {
        let object = pose(position: [0.1, 0.75, -0.45], eulerDeg: [180, 35, 0])
        let head = SIMD3<Float>(0, 1.3, 0)
        let decision = ObjectScreenFrame.decision(box: passport, objectPose: object, headPosition: head)
        var frame = ObjectScreenFrame(box: passport)
        frame.adopt(decision.flips)
        let screen = object * frame.offset
        let origin = SIMD3<Float>(screen.columns.3.x, screen.columns.3.y, screen.columns.3.z)
        let normal = simd_normalize(column(screen, 1))
        XCTAssertGreaterThan(simd_dot(normal, simd_normalize(head - origin)), 0, "the screen faces the reader")
        // …and the origin is on the face, 2.6 mm from the box centre, not at its middle.
        let centre = SIMD3<Float>(object.columns.3.x, object.columns.3.y, object.columns.3.z)
        XCTAssertEqual(simd_length(origin - centre), 0.0026, accuracy: 1e-5)
    }

    // MARK: - Persistence

    func testFlipsRoundTripThroughDefaults() {
        for flips in [ObjectScreenFrame.Flips(), .init(side: true), .init(yaw: true), .init(side: true, yaw: true)] {
            XCTAssertEqual(ObjectScreenFrame.decode(ObjectScreenFrame.encode(flips)), flips)
        }
        XCTAssertEqual(ObjectScreenFrame.encode(.init(side: true, yaw: false)), [1, 0])
        // Anything else stored under the key is not a record, and must not be read as "no flips".
        XCTAssertNil(ObjectScreenFrame.decode([]))
        XCTAssertNil(ObjectScreenFrame.decode([1]))
        XCTAssertNil(ObjectScreenFrame.decode([1, 2]))
        XCTAssertNil(ObjectScreenFrame.decode([0, 1, 0]))
        XCTAssertEqual(ObjectScreenFrame.defaultsKey("AI-Passport"), "spatialcard.screenFrame.v1.AI-Passport")
    }

    /// The frame is only "decided" once something actually decided it: until then `CardTracker` keeps asking.
    func testFrameIsUndecidedUntilItIsAdopted() {
        var frame = ObjectScreenFrame(box: passport)
        XCTAssertFalse(frame.isDecided)
        frame.adopt(.init(side: true))
        XCTAssertTrue(frame.isDecided)
        XCTAssertEqual(frame.flips.side, true)
    }

    /// The one line the headset prints per anchor. It is evidence, so its shape is pinned.
    func testDescribeNamesTheAxisAndBothSigns() {
        var frame = ObjectScreenFrame(box: passport)
        let decision = ObjectScreenFrame.decision(box: passport, objectPose: pose(position: [0, 0.75, -0.5]),
                                                  headPosition: [0, 1.25, 0])
        frame.adopt(decision.flips)
        let line = frame.describe(decision: decision)
        XCTAssertTrue(line.hasPrefix("[obj] box centre (0.0, 0.0, 0.0) mm extent (58.6, 5.2, 94.0) mm"), line)
        XCTAssertTrue(line.contains("normal axis Y"), line)
        XCTAssertTrue(line.contains("screen side +Y"), line)
        XCTAssertTrue(line.contains("yaw 0 (reader at +Z)"), line)
    }

    // MARK: - V3-1b: the box the headset actually reports

    /// The runtime `ObjectAnchor.boundingBox` is **not** the offline usdz analysis: it is Z-thin (60 × 95 ×
    /// 8.5 mm), so the screen normal is the object's +Z and the 95 mm reader axis is its +Y. Everything that
    /// assumed "the object's +Y is the screen normal" is wrong on this box — which is how V3-1 stood the passport
    /// on end on the desk for a whole session.
    func testHeadsetBoxIsZThinWithAYReaderAxis() {
        let box = ObjectScreenFrame.Box.aiPassportHeadset
        let frame = ObjectScreenFrame(box: box)
        XCTAssertEqual(frame.axis, .z, "the 8.5 mm axis is the normal")
        XCTAssertEqual(frame.readerAxis, .y, "the 95 mm axis is the screen's long edge")
        XCTAssertEqual(ObjectScreenFrame.normalAxis(extent: box.extent), .z)
    }

    /// The composed mapping on that box: object +Z becomes the screen's +Y (its normal) and object +Y becomes the
    /// screen's ±Z (its reader axis), with the origin lifted onto the face by half the 8.5 mm thickness.
    func testHeadsetBoxOffsetMapsZToTheNormalAndYToTheReaderAxis() {
        let frame = ObjectScreenFrame(box: .aiPassportHeadset)
        let offset = frame.offset
        // The screen frame's +Y expressed in object coordinates is the offset's second column.
        XCTAssertEqual(column(offset, 1), SIMD3<Float>(0, 0, 1), "object +Z → screen +Y")
        let reader = column(offset, 2)
        XCTAssertEqual(abs(reader.y), 1, accuracy: 1e-6, "object ±Y → screen +Z")
        XCTAssertEqual(reader.x, 0, accuracy: 1e-6)
        XCTAssertEqual(reader.z, 0, accuracy: 1e-6)
        // Right-handed, and the origin is the centre of the face rather than the centre of the slab.
        XCTAssertEqual(simd_dot(simd_cross(column(offset, 0), column(offset, 1)), column(offset, 2)), 1, accuracy: 1e-5)
        XCTAssertEqual(offset.columns.3.z, 0.00425, accuracy: 1e-6)

        // The yaw flip turns the reader axis round without touching the normal.
        let flipped = frame.offset(for: .init(side: false, yaw: true))
        XCTAssertEqual(column(flipped, 1), SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(column(flipped, 2), -reader)
    }

    /// The log line has to name the axis the frame actually reads. V3-1 hard-coded `±Z`, so the headset printed
    /// `reader at -Z` for a frame whose reader axis was Y — the one line that could have pointed at the mismatch.
    func testDescribeNamesTheRealReaderAxisOnTheHeadsetBox() {
        let box = ObjectScreenFrame.Box.aiPassportHeadset
        var frame = ObjectScreenFrame(box: box)
        // A device lying flat in front of a wearer: the object pose is the screen pose pushed back through the
        // frame, which is exactly what the `--fake-track` harness emits.
        let screen = pose(position: [0, 1.05, -0.6])
        let objectPose = screen * frame.offset(for: .init()).inverse
        let decision = ObjectScreenFrame.decision(box: box, objectPose: objectPose, headPosition: [0, 1.59, 0])
        frame.adopt(decision.flips)
        let line = frame.describe(decision: decision)
        XCTAssertTrue(line.hasPrefix("[obj] box centre (0.0, 0.0, 0.0) mm extent (60.0, 95.0, 8.5) mm"), line)
        XCTAssertTrue(line.contains("normal axis Z"), line)
        XCTAssertTrue(line.contains("reader at +Y") || line.contains("reader at -Y"),
                      "the reader axis is Y on a Z-thin box, not Z: \(line)")

        // And the sign follows both flips, not just the yaw one.
        var flipped = ObjectScreenFrame(box: box)
        flipped.adopt(.init(side: false, yaw: true))
        XCTAssertTrue(flipped.describe(decision: nil).contains("reader at -Y"), flipped.describe(decision: nil))
        var both = ObjectScreenFrame(box: box)
        both.adopt(.init(side: true, yaw: true))
        XCTAssertTrue(both.describe(decision: nil).contains("reader at +Y"), both.describe(decision: nil))
    }
}
