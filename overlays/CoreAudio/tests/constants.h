// The CoreAudioTypes constants main.swift uses, with the values in Darling's
// src/CoreAudio/include/CoreAudio/CoreAudioTypes.h. The overlay's shims declare the
// types; these come in with -import-objc-header, as Darling's header has no Clang module.
#include "../shims/DarlingCoreAudioShims.h"

static const AudioChannelLabel kAudioChannelLabel_Unknown = 0xFFFFFFFF;
static const AudioChannelLabel kAudioChannelLabel_Left = 1;
static const AudioChannelLabel kAudioChannelLabel_Right = 2;
static const AudioChannelLabel kAudioChannelLabel_Center = 3;
static const AudioChannelLayoutTag kAudioChannelLayoutTag_UseChannelBitmap = (1U << 16) | 0;
static const AudioChannelLayoutTag kAudioChannelLayoutTag_Mono = (100U << 16) | 1;
static const AudioChannelLayoutTag kAudioChannelLayoutTag_Stereo = (101U << 16) | 2;
