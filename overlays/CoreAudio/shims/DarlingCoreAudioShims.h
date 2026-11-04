// Declarations the CoreAudio Swift overlay needs, written for Darling from CoreAudioTypes' public
// API documentation. As with CoreMedia, the overlay imports these rather than Darling's headers,
// which have no Clang module; the layouts are Darling's CoreAudioTypes.h ones, and the struct
// names give the `So11AudioBufferV` and `So15AudioBufferListV` that apps built against the iOS SDK use.
#ifndef DARLING_COREAUDIO_SHIMS_H
#define DARLING_COREAUDIO_SHIMS_H

struct AudioBuffer {
	__UINT32_TYPE__ mNumberChannels;
	__UINT32_TYPE__ mDataByteSize;
	void *_Nullable mData;
};
typedef struct AudioBuffer AudioBuffer;

struct AudioBufferList {
	__UINT32_TYPE__ mNumberBuffers;
	AudioBuffer mBuffers[1];
};
typedef struct AudioBufferList AudioBufferList;

// AudioChannelLayout and its parts, for the channel layout types. The option sets are declared the
// way CF_OPTIONS declares them, so Swift imports them as the OptionSet structs the SDK's
// interface names (So18AudioChannelBitmapV).
typedef __UINT32_TYPE__ AudioChannelLabel;
typedef __UINT32_TYPE__ AudioChannelLayoutTag;

typedef enum __attribute__((flag_enum, enum_extensibility(open))) AudioChannelBitmap : __UINT32_TYPE__ AudioChannelBitmap;
enum AudioChannelBitmap : __UINT32_TYPE__ {
	kAudioChannelBit_Left = 1U << 0,
	kAudioChannelBit_Right = 1U << 1,
	kAudioChannelBit_Center = 1U << 2,
	kAudioChannelBit_LFEScreen = 1U << 3,
};

typedef enum __attribute__((flag_enum, enum_extensibility(open))) AudioChannelFlags : __UINT32_TYPE__ AudioChannelFlags;
enum AudioChannelFlags : __UINT32_TYPE__ {
	kAudioChannelFlags_AllOff = 0,
	kAudioChannelFlags_RectangularCoordinates = 1U << 0,
	kAudioChannelFlags_SphericalCoordinates = 1U << 1,
	kAudioChannelFlags_Meters = 1U << 2,
};

struct AudioChannelDescription {
	AudioChannelLabel mChannelLabel;
	AudioChannelFlags mChannelFlags;
	float mCoordinates[3];
};
typedef struct AudioChannelDescription AudioChannelDescription;

struct AudioChannelLayout {
	AudioChannelLayoutTag mChannelLayoutTag;
	AudioChannelBitmap mChannelBitmap;
	__UINT32_TYPE__ mNumberChannelDescriptions;
	AudioChannelDescription mChannelDescriptions[1];
};
typedef struct AudioChannelLayout AudioChannelLayout;

#endif
