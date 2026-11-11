// CGPathFillRule and the CGPath, CGMutablePath and CGContext methods that take it or a transform
// (CGContext.draw(_:in:byTiling:) is in CoreGraphics.swift),
// after release/5.2 stdlib/public/Darwin/CoreGraphics/CoreGraphics.swift (Copyright (c) 2014 - 2017
// Apple Inc. and the Swift project authors, Apache License v2.0 with Runtime Library Exception).
// Apple's call refined C names (__clip, __moveTo, …) from the SDK's apinotes; Darling has none, so
// these call the C functions themselves.
import _DarlingCoreGraphicsShims

public enum CGPathFillRule: Int {
  /// Nonzero winding number fill rule.
  case winding
  /// Even-odd fill rule.
  case evenOdd
}

extension CGContext {
  public func clip(using rule: CGPathFillRule = .winding) {
    switch rule {
    case .winding: CGContextClip(self)
    case .evenOdd: CGContextEOClip(self)
    }
  }
}

extension CGMutablePath {
  public func addRoundedRect(in rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat,
                             transform: CGAffineTransform = .identity) {
    var transform = transform
    CGPathAddRoundedRect(self, &transform, rect, cornerWidth, cornerHeight)
  }

  public func move(to point: CGPoint, transform: CGAffineTransform = .identity) {
    var transform = transform
    CGPathMoveToPoint(self, &transform, point.x, point.y)
  }

  public func addLine(to point: CGPoint, transform: CGAffineTransform = .identity) {
    var transform = transform
    CGPathAddLineToPoint(self, &transform, point.x, point.y)
  }

  public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat,
                     clockwise: Bool, transform: CGAffineTransform = .identity) {
    var transform = transform
    CGPathAddArc(self, &transform, center.x, center.y, radius, startAngle, endAngle, clockwise)
  }

  public func addArc(tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat,
                     transform: CGAffineTransform = .identity) {
    var transform = transform
    CGPathAddArcToPoint(self, &transform, tangent1End.x, tangent1End.y, tangent2End.x, tangent2End.y, radius)
  }

  public func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
    var transform = transform
    CGPathAddRect(self, &transform, rect)
  }

  public func addPath(_ path: CGPath, transform: CGAffineTransform = .identity) {
    var transform = transform
    CGPathAddPath(self, &transform, path)
  }
}

extension CGPath {
  public func copy(dashingWithPhase phase: CGFloat, lengths: [CGFloat],
                   transform: CGAffineTransform = .identity) -> CGPath {
    var transform = transform
    let path: CGPath? = lengths.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<CGFloat>) -> CGPath? in
      // Darling's declaration has no CF_RETURNS_RETAINED, so Swift sees the +1 result as Unmanaged.
      CGPathCreateCopyByDashingPath(self, &transform, phase, buffer.baseAddress, buffer.count)?.takeRetainedValue()
    }
    return path!
  }
}
