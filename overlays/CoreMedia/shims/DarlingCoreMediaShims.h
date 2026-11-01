// Declarations the CoreMedia Swift overlay needs, written for Darling from CoreMedia's public API
// documentation (CMTime.h, CMTimeRange.h). Darling's CoreMedia headers declare none of these and the
// framework has no Clang module, so the overlay imports these instead of <CoreMedia/CoreMedia.h>.
#ifndef DARLING_COREMEDIA_SHIMS_H
#define DARLING_COREMEDIA_SHIMS_H

typedef __INT64_TYPE__ CMTimeValue;
typedef __INT32_TYPE__ CMTimeScale;
typedef __INT64_TYPE__ CMTimeEpoch;

// What CF_OPTIONS and CF_ENUM expand to, without CoreFoundation's headers: named open enums, which
// import as `So11CMTimeFlagsV` (an OptionSet) and `So20CMTimeRoundingMethodV`, the names apps built
// against the iOS SDK use.
typedef enum __attribute__((flag_enum, enum_extensibility(open))) CMTimeFlags : __UINT32_TYPE__ {
	kCMTimeFlags_Valid = 1UL << 0,
	kCMTimeFlags_HasBeenRounded = 1UL << 1,
	kCMTimeFlags_PositiveInfinity = 1UL << 2,
	kCMTimeFlags_NegativeInfinity = 1UL << 3,
	kCMTimeFlags_Indefinite = 1UL << 4,
	kCMTimeFlags_ImpliedValueFlagsMask = kCMTimeFlags_PositiveInfinity | kCMTimeFlags_NegativeInfinity | kCMTimeFlags_Indefinite
} CMTimeFlags;

typedef enum __attribute__((enum_extensibility(open))) CMTimeRoundingMethod : __UINT32_TYPE__ {
	kCMTimeRoundingMethod_RoundHalfAwayFromZero = 1,
	kCMTimeRoundingMethod_RoundTowardZero = 2,
	kCMTimeRoundingMethod_RoundAwayFromZero = 3,
	kCMTimeRoundingMethod_QuickTime = 4,
	kCMTimeRoundingMethod_RoundTowardPositiveInfinity = 5,
	kCMTimeRoundingMethod_RoundTowardNegativeInfinity = 6,
	kCMTimeRoundingMethod_Default = kCMTimeRoundingMethod_RoundHalfAwayFromZero
} CMTimeRoundingMethod;

// Typedefs of anonymous structs, as in Apple's headers: that makes them mangle as typealiases,
// `So6CMTimea` and `So11CMTimeRangea`. The layouts are ABI, passed and returned by value.
typedef struct {
	CMTimeValue value;
	CMTimeScale timescale;
	CMTimeFlags flags;
	CMTimeEpoch epoch;
} CMTime;

typedef struct {
	CMTime start;
	CMTime duration;
} CMTimeRange;

#endif
