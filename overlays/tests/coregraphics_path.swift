import CoreGraphics

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print(condition ? "ok:" : "FAIL:", label)
    if !condition { failures += 1 }
}

func close(_ a: CGFloat, _ b: CGFloat) -> Bool { return abs(a - b) < 1e-6 }
func close(_ a: CGPoint, _ b: CGPoint) -> Bool { return close(a.x, b.x) && close(a.y, b.y) }
func close(_ a: CGRect, _ b: CGRect) -> Bool {
    return close(a.origin, b.origin) && close(a.size.width, b.size.width) && close(a.size.height, b.size.height)
}

// The element types and the first point CGPathApply reports, collected through the info pointer.
final class Elements {
    var types: [UInt32] = []
    var firstPoint: CGPoint?
}

func elements(of path: CGPath) -> Elements {
    let recorder = Elements()
    withExtendedLifetime(recorder) {
        CGPathApply(path, Unmanaged.passUnretained(recorder).toOpaque()) { info, element in
            let recorder = Unmanaged<Elements>.fromOpaque(info!).takeUnretainedValue()
            let element = element!.pointee
            recorder.types.append(element.type.rawValue)
            if recorder.firstPoint == nil, element.type != kCGPathElementCloseSubpath {
                recorder.firstPoint = element.points[0]
            }
        }
    }
    return recorder
}

let move = kCGPathElementMoveToPoint.rawValue
let line = kCGPathElementAddLineToPoint.rawValue
let curve = kCGPathElementAddCurveToPoint.rawValue
let quadCurve = kCGPathElementAddQuadCurveToPoint.rawValue
let closeSubpath = kCGPathElementCloseSubpath.rawValue

let translation = CGAffineTransform(translationX: 5, y: 7)
let rect = CGRect(x: 1, y: 2, width: 30, height: 40)

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "dashing" {
    // Darling's CGPathCreateCopyByDashingPath returns NULL, so this must trap with a message naming it.
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 10, y: 0))
    let dashed = path.copy(dashingWithPhase: 0, lengths: [2, 3])
    print("FAIL: copy(dashingWithPhase:lengths:) returned, bounding box \(CGPathGetPathBoundingBox(dashed))")
    exit(1)
}

// move(to:transform:): the current point is the point, after the transform.
do {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 3, y: 4))
    check(close(CGPathGetCurrentPoint(path), CGPoint(x: 3, y: 4)), "move(to:) sets the current point")
    path.move(to: CGPoint(x: 3, y: 4), transform: translation)
    check(close(CGPathGetCurrentPoint(path), CGPoint(x: 8, y: 11)), "move(to:transform:) translates the point")
}

// addLine(to:transform:): the current point is the end of the line, after the transform.
do {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 1, y: 1))
    path.addLine(to: CGPoint(x: 6, y: 9))
    check(close(CGPathGetCurrentPoint(path), CGPoint(x: 6, y: 9)), "addLine(to:) moves the current point to the end")
    let e = elements(of: path)
    check(e.types == [move, line], "addLine(to:) after move(to:) gives one move and one line (\(e.types))")

    let scaled = CGMutablePath()
    scaled.move(to: CGPoint(x: 0, y: 0))
    scaled.addLine(to: CGPoint(x: 6, y: 9), transform: CGAffineTransform(scaleX: 2, y: 3))
    check(close(CGPathGetCurrentPoint(scaled), CGPoint(x: 12, y: 27)), "addLine(to:transform:) scales the end point")
}

// addRect(_:transform:): a closed subpath starting at the bottom-left corner.
do {
    let path = CGMutablePath()
    path.addRect(rect)
    check(close(CGPathGetPathBoundingBox(path), rect), "addRect(_:) bounds the rectangle")
    let e = elements(of: path)
    check(e.types.first == move && e.types.last == closeSubpath, "addRect(_:) starts with a move and ends closed (\(e.types))")
    check(e.firstPoint.map { close($0, CGPoint(x: rect.minX, y: rect.minY)) } ?? false,
          "addRect(_:) starts at minX/minY (\(String(describing: e.firstPoint)))")

    let moved = CGMutablePath()
    moved.addRect(rect, transform: translation)
    check(close(CGPathGetPathBoundingBox(moved), rect.offsetBy(dx: 5, dy: 7)), "addRect(_:transform:) translates the rectangle")
}

// addRoundedRect(in:cornerWidth:cornerHeight:transform:): bounded by the rectangle, with curved corners.
do {
    let rounded = CGRect(x: 0, y: 0, width: 100, height: 50)
    let path = CGMutablePath()
    path.addRoundedRect(in: rounded, cornerWidth: 10, cornerHeight: 5)
    check(close(CGPathGetPathBoundingBox(path), rounded), "addRoundedRect(in:...) bounds the rectangle (\(CGPathGetPathBoundingBox(path)))")
    let e = elements(of: path)
    check(e.types.contains(curve) || e.types.contains(quadCurve), "addRoundedRect(in:...) has curved corners (\(e.types))")
    check(e.types.last == closeSubpath, "addRoundedRect(in:...) ends closed")

    let moved = CGMutablePath()
    moved.addRoundedRect(in: rounded, cornerWidth: 10, cornerHeight: 5, transform: translation)
    check(close(CGPathGetPathBoundingBox(moved), rounded.offsetBy(dx: 5, dy: 7)), "addRoundedRect(in:...transform:) translates the rectangle")
}

// addPath(_:transform:): appends the transformed elements and leaves the source alone.
do {
    let source = CGMutablePath()
    source.addRect(rect)
    let path = CGMutablePath()
    path.addPath(source, transform: CGAffineTransform(translationX: 10, y: 20))
    check(close(CGPathGetPathBoundingBox(path), rect.offsetBy(dx: 10, dy: 20)), "addPath(_:transform:) appends the translated path")
    check(close(CGPathGetPathBoundingBox(source), rect), "addPath(_:transform:) leaves the source unchanged")
    let expected = CGPathGetCurrentPoint(source)
    check(close(CGPathGetCurrentPoint(path), CGPoint(x: expected.x + 10, y: expected.y + 20)),
          "addPath(_:transform:) takes the source's current point, translated")
}

// The default transform is the identity.
do {
    func same(_ label: String, _ build: (CGMutablePath, CGAffineTransform?) -> Void) {
        let byDefault = CGMutablePath()
        build(byDefault, nil)
        let byIdentity = CGMutablePath()
        build(byIdentity, .identity)
        check(close(CGPathGetBoundingBox(byDefault), CGPathGetBoundingBox(byIdentity))
              && close(CGPathGetCurrentPoint(byDefault), CGPathGetCurrentPoint(byIdentity)),
              "\(label) defaults to the identity transform")
    }
    let source = CGMutablePath()
    source.addRect(rect)
    same("move(to:)") { p, t in
        if let t { p.move(to: CGPoint(x: 3, y: 4), transform: t) } else { p.move(to: CGPoint(x: 3, y: 4)) }
    }
    same("addLine(to:)") { p, t in
        p.move(to: .zero)
        if let t { p.addLine(to: CGPoint(x: 3, y: 4), transform: t) } else { p.addLine(to: CGPoint(x: 3, y: 4)) }
    }
    same("addRect(_:)") { p, t in
        if let t { p.addRect(rect, transform: t) } else { p.addRect(rect) }
    }
    same("addRoundedRect(in:...)") { p, t in
        if let t { p.addRoundedRect(in: rect, cornerWidth: 4, cornerHeight: 3, transform: t) }
        else { p.addRoundedRect(in: rect, cornerWidth: 4, cornerHeight: 3) }
    }
    same("addPath(_:)") { p, t in
        if let t { p.addPath(source, transform: t) } else { p.addPath(source) }
    }
}

if failures == 0 {
    print("ALL PASSED")
} else {
    exit(1)
}
