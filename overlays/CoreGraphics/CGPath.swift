//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// The CGPath and CGMutablePath members below are from swiftlang/swift tag swift-5.4.3-RELEASE,
// stdlib/public/Darwin/CoreGraphics/CoreGraphics.swift, lines 598-605 and 624-699: only the ones
// apps import. Upstream calls them through the `__`-prefixed names the SDK's CoreGraphics.apinotes
// gives the C functions (`__moveTo(transform:x:y:)` for CGPathMoveToPoint and so on, mapped in
// Private.swift). Darling's SDK ships no apinotes file, so the C functions are called under their
// own names with `self` first, the way the CGContext methods in CoreGraphics.swift are.
//
// The transform is always passed as a pointer to a copy of it, never as NULL for the identity,
// as upstream does.

@_implementationOnly import _DarlingCoreGraphicsShims

extension CGPath {
  public func copy(dashingWithPhase phase: CGFloat, lengths: [CGFloat],
    transform: CGAffineTransform = .identity) -> CGPath {
    // Upstream force-unwraps, since the C function returns NULL only for bad input. Darling's
    // CGPathCreateCopyByDashingPath is a stub that always returns NULL, so name it rather than
    // crash on an anonymous nil.
    guard let path = CGPathCreateCopyByDashingPath(self, [transform], phase, lengths, lengths.count) else {
      fatalError("CGPath.copy(dashingWithPhase:lengths:transform:): CGPathCreateCopyByDashingPath is not implemented by Darling's CoreGraphics yet")
    }
    return path
  }
}

extension CGMutablePath {
  public func addRoundedRect(in rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat,
    transform: CGAffineTransform = .identity) {
    CGPathAddRoundedRect(self, [transform], rect, cornerWidth, cornerHeight)
  }

  public func move(to point: CGPoint, transform: CGAffineTransform = .identity) {
    CGPathMoveToPoint(self, [transform], point.x, point.y)
  }

  public func addLine(to point: CGPoint, transform: CGAffineTransform = .identity) {
    CGPathAddLineToPoint(self, [transform], point.x, point.y)
  }

  public func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
    CGPathAddRect(self, [transform], rect)
  }

  public func addPath(_ path: CGPath, transform: CGAffineTransform = .identity) {
    CGPathAddPath(self, [transform], path)
  }
}
