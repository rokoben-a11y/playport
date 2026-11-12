// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import XCTest
@testable import PlayportKit

/// The iPhone Duo's open inner display (951 × 669 points, regular × regular):
/// every preset's controls sit in the safe area's bottom 40%, clear of the
/// 80-point centre column over the fold (ControlBand).
final class ControlBandTests: XCTestCase {
    static let inner = (width: 951.0, height: 669.0)
    static let insets = ControlInsets(top: 20, left: 20, bottom: 20, right: 20)

    static var presets: [(String, ControlLayout)] {
        ControlLayoutTests.options.map { ("gamepad \($0.dpad) \($0.rightStick)", ControlLayout.gamepad(dpad: $0.dpad, rightStick: $0.rightStick)) }
            + [("keyboardMouse", .keyboardMouse()), ("pointClick", .pointClick())]
    }

    func inside(_ r: TouchRect, _ a: TouchRect, accuracy e: Double = 0.001) -> Bool {
        r.x >= a.x - e && r.y >= a.y - e && r.maxX <= a.maxX + e && r.maxY <= a.maxY + e
    }

    func testEveryPresetIsInTheBottomBandClearOfTheFold() {
        let area = Self.insets.area(width: Self.inner.width, height: Self.inner.height)
        let band = TouchRect(x: area.x, y: area.y + area.height * 0.6, width: area.width, height: area.height * 0.4)
        let gap = TouchRect(x: area.x + area.width / 2 - 40, y: area.y, width: 80, height: area.height)
        for (name, layout) in Self.presets {
            let targets = layout.bandTargets(width: Self.inner.width, height: Self.inner.height, insets: Self.insets)
            XCTAssertEqual(targets.map(\.id), layout.controls.map(\.id), name)
            var placed: [TouchTarget] = []
            for t in targets {
                switch t.kind {
                case .look, .pointer: continue   // surfaces keep the whole safe area
                case .stick(_, let zone?), .keyStick(_, let zone?):
                    XCTAssertTrue(inside(zone, band), "\(name) \(t.id) zone \(zone)")
                    XCTAssertTrue(zone.maxX <= gap.x + 0.001 || zone.x >= gap.maxX - 0.001, "\(name) \(t.id) zone over the fold")
                    continue   // a floating stick's frame is where it is drawn at rest
                default: break
                }
                XCTAssertTrue(inside(t.frame, band), "\(name) \(t.id) \(t.frame) not in band \(band)")
                XCTAssertTrue(t.frame.maxX <= gap.x + 0.001 || t.frame.x >= gap.maxX - 0.001, "\(name) \(t.id) over the fold")
                XCTAssertGreaterThan(t.frame.width, 20, "\(name) \(t.id) too small")
                placed.append(t)
            }
            for (i, a) in placed.enumerated() {
                for b in placed[(i + 1)...] {
                    let overlap = a.frame.x < b.frame.maxX - 0.001 && b.frame.x < a.frame.maxX - 0.001
                        && a.frame.y < b.frame.maxY - 0.001 && b.frame.y < a.frame.maxY - 0.001
                    XCTAssertFalse(overlap, "\(name): \(a.id) \(a.frame) overlaps \(b.id) \(b.frame)")
                }
            }
        }
    }

    /// The outer display and every phone keep the corner layout: targets is unchanged.
    func testTargetsWithoutTheBandAreUnchanged() {
        let g = ControlLayout.gamepad(dpad: .on)
        let t = g.targets(width: 874, height: 402, insets: ControlInsets(left: 62, bottom: 21))
        XCTAssertEqual(t.first { $0.id == "a" }?.frame.maxY ?? 0, 381, accuracy: 0.001)
    }
}
