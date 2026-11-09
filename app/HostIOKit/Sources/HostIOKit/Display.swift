// SPDX-License-Identifier: GPL-3.0-or-later
/// The title's screen: the display mode the guest is offered, and where its
/// swap chain lands on the phone. A title runs landscape; the guest gets one
/// mode with the panel's aspect (MADEIRA_SCREEN_W/H, which the runtime's
/// virtual monitor, metrics and mode list follow), and whatever size the game
/// then renders is aspect-fitted, so no aspect ratio is stretched.
public enum Display {
    /// The guest's screen for a panel of `long` × `short` native pixels, from
    /// a screen spec: nil, "" or "native" gives the panel itself, "<rows>" (for
    /// example "720") the panel's aspect at that many rows, "4:3" the runtime's
    /// old 1024×768, "WxH" exactly that, and "A:B@level" a level ("native" or
    /// rows) in the A:B shape: native is the largest A:B rectangle inside the
    /// panel, rows that many rows at A:B (at most native's). Width and height
    /// are even. nil for a spec it cannot read.
    public static func guestSize(panelLong long: Int, panelShort short: Int, spec: String?) -> (Int, Int)? {
        guard long > 0, short > 0 else { return nil }
        let (w, h) = (max(long, short), min(long, short))
        switch spec?.lowercased() ?? "" {
        case "", "native":
            return (even(Double(w)), even(Double(h)))
        case let s where Int(s) != nil:
            guard let rows = Int(s), (200...h).contains(rows) else { return nil }
            return (even(Double(rows) * Double(w) / Double(h)), even(Double(rows)))
        case "4:3":
            return (1024, 768)
        case let s where s.contains("@"):
            let parts = s.split(separator: "@", omittingEmptySubsequences: false)
            let ratio = parts[0].split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, ratio.count == 2, let a = Int(ratio[0]), let b = Int(ratio[1]),
                  (1...100).contains(a), (1...100).contains(b) else { return nil }
            // The largest a:b rectangle inside the panel.
            let (fw, fh) = w * b > h * a ? (Double(h) * Double(a) / Double(b), Double(h))
                                         : (Double(w), Double(w) * Double(b) / Double(a))
            // Even numbers down, so it stays inside the panel.
            if parts[1] == "native" { return (Int(fw / 2) * 2, Int(fh / 2) * 2) }
            guard let rows = Int(parts[1]), rows >= 200, Double(rows) <= fh else { return nil }
            return (even(Double(rows) * Double(a) / Double(b)), even(Double(rows)))
        case let s:
            let parts = s.split(separator: "x")
            guard parts.count == 2, let sw = Int(parts[0]), let sh = Int(parts[1]),
                  (320...8192).contains(sw), (200...8192).contains(sh) else { return nil }
            return (sw, sh)
        }
    }

    /// The picture's rectangle in a view: the whole view. The swap chain's
    /// aspect does not inset it, so nothing has to be pressed before the
    /// scene is covered.
    public static func viewport(width: Double, height: Double) -> (Double, Double, Double, Double) {
        (0, 0, width, height)
    }

    /// The metal viewport in pixels: the window scene's bounds times the
    /// screen scale. A fold or resize passes the new bounds; nothing here is
    /// a fixed phone size.
    public static func surfacePixels(sceneWidth: Double, sceneHeight: Double, scale: Double) -> (Double, Double) {
        guard sceneWidth > 0, sceneHeight > 0, scale > 0 else { return (0, 0) }
        return (sceneWidth * scale, sceneHeight * scale)
    }

    /// The rectangle a picture of content size fills inside a view of
    /// width × height when fitted without stretching and centred
    /// (CAMetalLayer contentsGravity resizeAspect): x, y, width, height.
    public static func aspectFit(contentWidth cw: Double, contentHeight ch: Double,
                                 width: Double, height: Double) -> (Double, Double, Double, Double) {
        guard cw > 0, ch > 0, width > 0, height > 0 else { return (0, 0, width, height) }
        let s = min(width / cw, height / ch)
        let (fw, fh) = (cw * s, ch * s)
        return ((width - fw) / 2, (height - fh) / 2, fw, fh)
    }

    /// A view point mapped into the aspect-fitted picture, origin at the
    /// picture's top left, in the picture's own points. A point in a bar is
    /// kept on the nearest edge of the picture, which is where the pointer
    /// lands. The picture's width and height come back with the point so a
    /// resize uses the picture it is looking at, not an earlier view size.
    public static func picturePoint(viewX: Double, viewY: Double, contentWidth: Double, contentHeight: Double,
                                    viewWidth: Double, viewHeight: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let (px, py, pw, ph) = aspectFit(contentWidth: contentWidth, contentHeight: contentHeight,
                                         width: viewWidth, height: viewHeight)
        guard pw > 0, ph > 0 else { return (0, 0, pw, ph) }
        let x = min(max(viewX, px), px + pw - 0.001) - px
        let y = min(max(viewY, py), py + ph - 0.001) - py
        return (x, y, pw, ph)
    }

    /// The safe area, in points, inside which the built-in on-screen layouts
    /// keep the point sizes they were written at. It is the largest phone safe
    /// area those layouts are checked against (the 6.9-inch landscape in
    /// ControlLayoutTests: 956 × 440 with 62 pt side insets and a 21 pt home
    /// indicator), not a panel this build names. A window no bigger than this
    /// — every current iPhone, and a foldable's compact outside screen — is
    /// unchanged. A larger safe area grows the same controls.
    public static let phoneLayoutSafeWidth = 832.0
    public static let phoneLayoutSafeHeight = 419.0

    /// How much to grow a layout placed in a safe area of this size. 1 when
    /// the area fits the phone layout. Above 1, the lesser of the two axes
    /// against that phone area, so the same anchors and gaps grow with the
    /// window and still fit it. A short window that is only wider stays at 1:
    /// the controls are already as tall as that window wants. No size class
    /// and no device id is read here; the window's safe area is the measurement.
    public static func controlScale(safeWidth: Double, safeHeight: Double) -> Double {
        guard safeWidth > 0, safeHeight > 0 else { return 1 }
        if safeWidth <= phoneLayoutSafeWidth, safeHeight <= phoneLayoutSafeHeight { return 1 }
        let s = min(safeWidth / phoneLayoutSafeWidth, safeHeight / phoneLayoutSafeHeight)
        return s > 1 ? s : 1
    }

    /// The panel's pixels for the guest mode. The window's, when it is a
    /// different panel from the screen (a foldable's inside window while
    /// `UIScreen.main` is still the outside one, or the reverse). The screen's
    /// own native pixels when the window is that screen, including a couple of
    /// percent of rounding, so a phone's guest size stays the native bounds it
    /// has always been. A window with no size yet uses the screen.
    public static func panelPixels(windowWidth: Int, windowHeight: Int, screenWidth: Int, screenHeight: Int) -> (Int, Int) {
        guard windowWidth > 1, windowHeight > 1 else { return (screenWidth, screenHeight) }
        guard screenWidth > 0, screenHeight > 0 else { return (windowWidth, windowHeight) }
        let wl = max(windowWidth, windowHeight), ws = min(windowWidth, windowHeight)
        let sl = max(screenWidth, screenHeight), ss = min(screenWidth, screenHeight)
        if abs(wl - sl) * 50 <= sl, abs(ws - ss) * 50 <= ss { return (screenWidth, screenHeight) }
        return (windowWidth, windowHeight)
    }

    /// Unity's own screen switches, to append to a Unity title's arguments so
    /// it opens full screen at the guest's screen size instead of the window
    /// size it saved last time; none when the launch already sets any of them.
    public static func unityScreenArgs(existing: [String], width: Int, height: Int) -> [String] {
        let own = ["-screen-", "-window-mode", "-popupwindow"]
        if existing.contains(where: { a in own.contains { a.lowercased().hasPrefix($0) } }) { return [] }
        return ["-screen-fullscreen", "1", "-screen-width", String(width), "-screen-height", String(height)]
    }

    private static func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
}
