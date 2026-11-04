// Exercises the CoreAudio Swift overlay through the iOS SDK's interface, so every call binds to
// the symbol names Apple's libswiftCoreAudio exports.
import CoreAudio
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
	print((ok ? "ok   " : "FAIL ") + what)
	if !ok { failures += 1 }
}

// AudioBufferList
let list = AudioBufferList.allocate(maximumBuffers: 2)
check(list.count == 2, "AudioBufferList.allocate count")
check(AudioBufferList.sizeInBytes(maximumBuffers: 2) == 40, "AudioBufferList.sizeInBytes(2) == 40")
var samples: [Float] = [1, 2, 3, 4]
samples.withUnsafeMutableBufferPointer { p in
	list[0] = AudioBuffer(p, numberOfChannels: 2)
	check(list[0].mDataByteSize == 16 && list[0].mNumberChannels == 2, "AudioBuffer(typedBuffer:numberOfChannels:)")
	let back = UnsafeBufferPointer<Float>(list[0])
	check(back.count == 4 && back[3] == 4, "UnsafeBufferPointer(AudioBuffer)")
	let mback = UnsafeMutableBufferPointer<Float>(list[0])
	mback[0] = 9
}
check(samples[0] == 9, "UnsafeMutableBufferPointer(AudioBuffer) writes through")
list[1].mNumberChannels = 7
check(list[1].mNumberChannels == 7 && list.map { $0.mNumberChannels } == [2, 7], "AudioBufferList subscript modify and iteration")
free(list.unsafeMutablePointer)

// AudioChannelLayout pointers
check(AudioChannelLayout.sizeInBytes(maximumDescriptions: 3) == 72, "AudioChannelLayout.sizeInBytes(3) == 72")
let layout = AudioChannelLayout.allocate(maximumDescriptions: 3)
check(layout.count == 3, "AudioChannelLayout.allocate count")
layout[1].mChannelLabel = kAudioChannelLabel_Right
layout[2].mCoordinates.1 = 0.5
let ro = AudioChannelLayout.UnsafePointer(layout.unsafePointer)
check(ro.count == 3 && ro[1].mChannelLabel == kAudioChannelLabel_Right && ro[2].mCoordinates.1 == 0.5, "AudioChannelLayout.UnsafePointer reads")
check(AudioChannelLayout.UnsafePointer(nil) == nil && AudioChannelLayout.UnsafeMutablePointer(nil) == nil, "failable inits take nil")
check(ro[0] == ro[0] && !(ro[0] == ro[1]), "AudioChannelDescription ==")

// ManagedAudioChannelLayout
let stereo = ManagedAudioChannelLayout(tag: kAudioChannelLayoutTag_Stereo)
check(stereo.tag == kAudioChannelLayoutTag_Stereo && stereo.numberOfChannels == 2, "init(tag:) and numberOfChannels")
var bits = ManagedAudioChannelLayout(tag: kAudioChannelLayoutTag_UseChannelBitmap)
bits.bitmap = [.bit_Left, .bit_Right, .bit_Center]
check(bits.numberOfChannels == 3, "bitmap layout numberOfChannels")
let left = AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Left, mChannelFlags: [], mCoordinates: (0, 0, 0))
let right = AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Right, mChannelFlags: [], mCoordinates: (0, 0, 0))
var a = ManagedAudioChannelLayout(channelDescriptions: [left, right])
check(a.numberOfChannels == 2 && a.channelDescriptions.count == 2 && a.channelDescriptions[1].mChannelLabel == kAudioChannelLabel_Right, "init(channelDescriptions:)")
check(a.sizeInBytes == 52, "sizeInBytes == 52")
var b = a
b.channelDescriptions[0].mChannelLabel = kAudioChannelLabel_Center
check(a.channelDescriptions[0].mChannelLabel == kAudioChannelLabel_Left && b.channelDescriptions[0].mChannelLabel == kAudioChannelLabel_Center, "copies are independent")
check(a != b && a == ManagedAudioChannelLayout(channelDescriptions: [left, right]), "Equatable")
b.setAllToUnknown()
check(b.channelDescriptions.allSatisfy { $0.mChannelLabel == kAudioChannelLabel_Unknown }, "setAllToUnknown")
let label = a.withUnsafePointer { $0.pointee.mNumberChannelDescriptions }
check(label == 2, "withUnsafePointer")
a.withUnsafeMutablePointer { $0.pointee.mChannelBitmap = .bit_LFEScreen }
check(a.bitmap == .bit_LFEScreen, "withUnsafeMutablePointer")
var freed = false
do {
	let adopted = ManagedAudioChannelLayout(audioChannelLayoutPointer: ro) { p in
		free(UnsafeMutableRawPointer(mutating: p.unsafePointer)); freed = true
	}
	var changed = adopted
	changed.tag = kAudioChannelLayoutTag_Mono
	check(adopted.channelDescriptions[1].mChannelLabel == kAudioChannelLabel_Right && adopted.tag == 0 && changed.tag == kAudioChannelLayoutTag_Mono,
	      "adopted layout copies on change")
}
check(freed, "adopted layout's deallocator runs")
let empty = ManagedAudioChannelLayout(maximumDescriptions: 4)
check(empty.channelDescriptions.count == 4, "init(maximumDescriptions:)")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
