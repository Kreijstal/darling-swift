// Declarations the CoreGraphics Swift overlay needs, written for Darling from the CoreGraphics API documentation.
// The functions are exported by Darling's CoreGraphics.framework.
//
// CGContextRef is NOT redeclared here. It comes from <CoreGraphics/CGContext.h>, which the overlay now imports as a
// Clang module. Redeclaring it collided at the C level ("typedef redefinition with different types, 'struct CGContext *'
// vs 'struct O2Context *'") because Darling's header uses an O2 struct tag.
//
// That tag is invisible to Swift: the Clang importer names an imported typedef by the typedef's own name, not by its
// underlying struct tag, so both spellings mangle byte-identically as `So12CGContextRefa`. Measured, not assumed.
#ifndef DARLING_COREGRAPHICS_SHIMS_H
#define DARLING_COREGRAPHICS_SHIMS_H

#include <CoreGraphics/CGContext.h>
#include <CoreGraphics/CGGeometry.h>
#include <CoreGraphics/CGPath.h>

void CGContextAddLineToPoint(CGContextRef context, CGFloat x, CGFloat y);
void CGContextAddArc(CGContextRef context, CGFloat x, CGFloat y, CGFloat radius, CGFloat startAngle, CGFloat endAngle,
                     bool clockwise);

// Darling's CGPath.h does not declare this one. Prototype from Apple's documentation of
// CGPathCreateCopyByDashingPath: transform and lengths may be NULL, and the result follows the Create
// rule. Inside an implicit-bridging region, as in CGPath.h, so Swift gets a managed CGPath. Like the
// declarations above it carries no nullability specifiers: one specifier anywhere in this file makes
// Clang warn about every unannotated pointer in it. Swift sees implicitly unwrapped optionals.
CF_IMPLICIT_BRIDGING_ENABLED
CGPathRef CGPathCreateCopyByDashingPath(CGPathRef path, const CGAffineTransform *transform, CGFloat phase,
                                        const CGFloat *lengths, size_t count);
CF_IMPLICIT_BRIDGING_DISABLED

#endif
