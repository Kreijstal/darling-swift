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

@_exported import CoreAudio // Clang module

extension UnsafeBufferPointer {
  /// Initialize an `UnsafeBufferPointer<Element>` from an `AudioBuffer`.
  /// Binds the buffer's memory type to `Element`.
  public init(_ audioBuffer: AudioBuffer) {
    let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Element>.stride
    let elementPtr = audioBuffer.mData?.bindMemory(
      to: Element.self, capacity: count)
    self.init(start: elementPtr, count: count)
  }
}

extension UnsafeMutableBufferPointer {
  /// Initialize an `UnsafeMutableBufferPointer<Element>` from an
  /// `AudioBuffer`.
  public init(_ audioBuffer: AudioBuffer) {
    let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Element>.stride
    let elementPtr = audioBuffer.mData?.bindMemory(
      to: Element.self, capacity: count)
    self.init(start: elementPtr, count: count)
  }
}

extension AudioBuffer {
  /// Initialize an `AudioBuffer` from an
  /// `UnsafeMutableBufferPointer<Element>`.
  public init<Element>(
    _ typedBuffer: UnsafeMutableBufferPointer<Element>,
    numberOfChannels: Int
  ) {
    let byteSize = typedBuffer.count * MemoryLayout<Element>.stride
    self.init(mNumberChannels: UInt32(numberOfChannels),
              mDataByteSize: UInt32(byteSize),
              mData: UnsafeMutableRawPointer(typedBuffer.baseAddress))
  }
}

extension AudioBufferList {
  /// - Returns: the size in bytes of an `AudioBufferList` that can hold up to
  ///   `maximumBuffers` `AudioBuffer`s.
  public static func sizeInBytes(maximumBuffers: Int) -> Int {
    precondition(maximumBuffers >= 1,
      "AudioBufferList should contain at least one AudioBuffer")
    return MemoryLayout<AudioBufferList>.size +
      (maximumBuffers - 1) * MemoryLayout<AudioBuffer>.stride
  }

  /// Allocate an `AudioBufferList` with a capacity for the specified number of
  /// `AudioBuffer`s.
  ///
  /// The `count` property of the new `AudioBufferList` is initialized to
  /// `maximumBuffers`.
  ///
  /// The memory should be freed with `free()`.
  public static func allocate(maximumBuffers: Int)
    -> UnsafeMutableAudioBufferListPointer {
    let byteSize = sizeInBytes(maximumBuffers: maximumBuffers)
    let ablMemory = calloc(byteSize, 1)
    precondition(ablMemory != nil,
      "failed to allocate memory for an AudioBufferList")

    let listPtr = ablMemory!.bindMemory(to: AudioBufferList.self, capacity: 1)
    (ablMemory! + MemoryLayout<AudioBufferList>.stride).bindMemory(
      to: AudioBuffer.self, capacity: maximumBuffers)
    let abl = UnsafeMutableAudioBufferListPointer(listPtr)
    abl.count = maximumBuffers
    return abl
  }
}

/// A wrapper for a pointer to an `AudioBufferList`.
///
/// Like `UnsafeMutablePointer`, this type provides no automated memory
/// management and the user must therefore take care to allocate and free
/// memory appropriately.
public struct UnsafeMutableAudioBufferListPointer {
  /// Construct from an `AudioBufferList` pointer.
  public init(_ p: UnsafeMutablePointer<AudioBufferList>) {
    unsafeMutablePointer = p
  }

  /// Construct from an `AudioBufferList` pointer.
  public init?(_ p: UnsafeMutablePointer<AudioBufferList>?) {
    guard let unwrapped = p else { return nil }
    self.init(unwrapped)
  }

  /// The number of `AudioBuffer`s in the `AudioBufferList`
  /// (`mNumberBuffers`).
  public var count: Int {
    get {
      return Int(unsafeMutablePointer.pointee.mNumberBuffers)
    }
    nonmutating set(newValue) {
      unsafeMutablePointer.pointee.mNumberBuffers = UInt32(newValue)
    }
  }

  /// The pointer to the first `AudioBuffer` in this `AudioBufferList`.
  internal var _audioBuffersPointer: UnsafeMutablePointer<AudioBuffer> {
    // AudioBufferList has one AudioBuffer in a "flexible array member".
    // Position the pointer after that, and skip one AudioBuffer back.  This
    // brings us to the start of AudioBuffer array.
    let rawPtr = UnsafeMutableRawPointer(unsafeMutablePointer + 1)
    return rawPtr.assumingMemoryBound(to: AudioBuffer.self) - 1
  }

  // FIXME: the properties 'unsafePointer' and 'unsafeMutablePointer' should be
  // initializers on UnsafePointer and UnsafeMutablePointer, but we don't want
  // to allow any UnsafePointer<Element> to be initializable from an
  // UnsafeMutableAudioBufferListPointer, only UnsafePointer<AudioBufferList>.
  // We need constrained extensions for that.  rdar://17821143

  /// The pointer to the wrapped `AudioBufferList`.
  public var unsafePointer: UnsafePointer<AudioBufferList> {
    return UnsafePointer(unsafeMutablePointer)
  }

  /// The pointer to the wrapped `AudioBufferList`.
  public var unsafeMutablePointer: UnsafeMutablePointer<AudioBufferList>
}

extension UnsafeMutableAudioBufferListPointer
  : MutableCollection, RandomAccessCollection {

  public typealias Element = AudioBuffer
  public typealias Index = Int
  public typealias Indices = Range<Int>

  /// Always zero, which is the index of the first `AudioBuffer`.
  public var startIndex: Int {
    return 0
  }

  /// The "past the end" position; always identical to `count`.
  public var endIndex: Int {
    return count
  }

  /// Access an indexed `AudioBuffer` (`mBuffers[i]`).
  @_borrowed
  public subscript(index: Index) -> Element {
    _read {
      precondition(index >= 0 && index < self.count,
        "subscript index out of range")
      yield ((_audioBuffersPointer + index).pointee)
    }
    nonmutating _modify {
      precondition(index >= 0 && index < self.count,
        "subscript index out of range")
      yield (&(_audioBuffersPointer + index).pointee)
    }
  }
}


// CoreAudio Swift overlay for Darling, written from Apple's public documentation of these types and
// the declarations in the iOS SDK's CoreAudio.swiftinterface, so apps built against that SDK find the
// symbols they import: collection views of the variable-length AudioBufferList and AudioChannelLayout
// structs, ManagedAudioChannelLayout, and AudioBuffer's buffer pointer conversions.

import Darwin

extension AudioChannelLayout {
	/// The size of an AudioChannelLayout that holds `maximumDescriptions` channel descriptions.
	public static func sizeInBytes(maximumDescriptions: Int) -> Int {
		precondition(maximumDescriptions >= 0, "maximumDescriptions should not be negative")
		let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
		return max(MemoryLayout<AudioChannelLayout>.size,
		           offset + maximumDescriptions * MemoryLayout<AudioChannelDescription>.stride)
	}

	/// A zeroed AudioChannelLayout with room for `maximumDescriptions` descriptions; free it with `free`.
	public static func allocate(maximumDescriptions: Int) -> AudioChannelLayout.UnsafeMutablePointer {
		let raw = calloc(sizeInBytes(maximumDescriptions: maximumDescriptions), 1)!
		let layout = UnsafeMutablePointer(raw.assumingMemoryBound(to: AudioChannelLayout.self))
		layout.count = maximumDescriptions
		return layout
	}

	/// A collection view of an AudioChannelLayout's channel descriptions.
	public struct UnsafeMutablePointer {
		public var unsafeMutablePointer: Swift.UnsafeMutablePointer<AudioChannelLayout>

		public init(_ p: Swift.UnsafeMutablePointer<AudioChannelLayout>) {
			unsafeMutablePointer = p
		}

		public init?(_ p: Swift.UnsafeMutablePointer<AudioChannelLayout>?) {
			guard let p = p else { return nil }
			self.init(p)
		}

		public var unsafePointer: Swift.UnsafePointer<AudioChannelLayout> { Swift.UnsafePointer(unsafeMutablePointer) }

		/// The number of descriptions, mNumberChannelDescriptions.
		public var count: Int {
			get { Int(unsafeMutablePointer.pointee.mNumberChannelDescriptions) }
			nonmutating set { unsafeMutablePointer.pointee.mNumberChannelDescriptions = UInt32(newValue) }
		}
	}

	/// A read-only collection view of an AudioChannelLayout's channel descriptions.
	public struct UnsafePointer {
		public var unsafePointer: Swift.UnsafePointer<AudioChannelLayout>

		public init(_ p: Swift.UnsafePointer<AudioChannelLayout>) {
			unsafePointer = p
		}

		public init?(_ p: Swift.UnsafePointer<AudioChannelLayout>?) {
			guard let p = p else { return nil }
			self.init(p)
		}

		public var count: Int { Int(unsafePointer.pointee.mNumberChannelDescriptions) }
	}
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AudioChannelLayout.UnsafeMutablePointer: MutableCollection, RandomAccessCollection {
	public typealias Element = AudioChannelDescription
	public typealias Index = Int

	public var startIndex: Int { 0 }
	public var endIndex: Int { count }

	public subscript(index: Int) -> AudioChannelDescription {
		_read {
			precondition(index >= 0 && index < count, "subscript index out of range")
			yield descriptions(of: UnsafeMutableRawPointer(unsafeMutablePointer))[index]
		}
		nonmutating _modify {
			precondition(index >= 0 && index < count, "subscript index out of range")
			yield &descriptions(of: UnsafeMutableRawPointer(unsafeMutablePointer))[index]
		}
	}
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AudioChannelLayout.UnsafePointer: RandomAccessCollection {
	public typealias Element = AudioChannelDescription
	public typealias Index = Int

	public var startIndex: Int { 0 }
	public var endIndex: Int { count }

	public subscript(index: Int) -> AudioChannelDescription {
		_read {
			precondition(index >= 0 && index < count, "subscript index out of range")
			yield descriptions(of: UnsafeMutableRawPointer(mutating: unsafePointer))[index]
		}
	}
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AudioChannelDescription {
	public static func == (lhs: AudioChannelDescription, rhs: AudioChannelDescription) -> Bool {
		lhs.mChannelLabel == rhs.mChannelLabel && lhs.mChannelFlags == rhs.mChannelFlags
			&& lhs.mCoordinates.0 == rhs.mCoordinates.0 && lhs.mCoordinates.1 == rhs.mCoordinates.1
			&& lhs.mCoordinates.2 == rhs.mCoordinates.2
	}
}

/// An AudioChannelLayout with value semantics: copies share one allocation until one of them changes.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct ManagedAudioChannelLayout {
	fileprivate final class Storage {
		let layout: Swift.UnsafeMutablePointer<AudioChannelLayout>
		/// Frees `layout`: the caller's deallocator for an adopted layout, free for one made here.
		let deallocator: (Swift.UnsafeMutablePointer<AudioChannelLayout>) -> Void
		/// An adopted layout is read-only: the first change copies it.
		let isAdopted: Bool

		init(_ layout: Swift.UnsafeMutablePointer<AudioChannelLayout>, isAdopted: Bool,
		     deallocator: @escaping (Swift.UnsafeMutablePointer<AudioChannelLayout>) -> Void) {
			self.layout = layout
			self.isAdopted = isAdopted
			self.deallocator = deallocator
		}

		convenience init(maximumDescriptions: Int) {
			let layout = AudioChannelLayout.allocate(maximumDescriptions: maximumDescriptions).unsafeMutablePointer
			self.init(layout, isAdopted: false) { free($0) }
		}

		var count: Int { Int(layout.pointee.mNumberChannelDescriptions) }
		var descriptions: Swift.UnsafeMutablePointer<AudioChannelDescription> {
			CoreAudio.descriptions(of: UnsafeMutableRawPointer(layout))
		}

		func copy() -> Storage {
			let storage = Storage(maximumDescriptions: count)
			memcpy(storage.layout, layout, AudioChannelLayout.sizeInBytes(maximumDescriptions: count))
			return storage
		}

		deinit { deallocator(layout) }
	}

	fileprivate var storage: Storage

	public init(audioChannelLayoutPointer: AudioChannelLayout.UnsafePointer,
	            deallocator: @escaping (AudioChannelLayout.UnsafePointer) -> Void) {
		storage = Storage(Swift.UnsafeMutablePointer(mutating: audioChannelLayoutPointer.unsafePointer), isAdopted: true) {
			deallocator(AudioChannelLayout.UnsafePointer(Swift.UnsafePointer($0)))
		}
	}

	public init(tag: AudioChannelLayoutTag) {
		storage = Storage(maximumDescriptions: 0)
		storage.layout.pointee.mChannelLayoutTag = tag
	}

	public init(maximumDescriptions: Int) {
		storage = Storage(maximumDescriptions: maximumDescriptions)
	}

	public init(channelDescriptions: [AudioChannelDescription]) {
		storage = Storage(maximumDescriptions: channelDescriptions.count)
		storage.descriptions.update(from: channelDescriptions, count: channelDescriptions.count)
	}

	private mutating func makeUnique() {
		if storage.isAdopted || !isKnownUniquelyReferenced(&storage) {
			storage = storage.copy()
		}
	}

	public var tag: AudioChannelLayoutTag {
		get { storage.layout.pointee.mChannelLayoutTag }
		set {
			makeUnique()
			storage.layout.pointee.mChannelLayoutTag = newValue
		}
	}

	public var bitmap: AudioChannelBitmap {
		get { storage.layout.pointee.mChannelBitmap }
		set {
			makeUnique()
			storage.layout.pointee.mChannelBitmap = newValue
		}
	}

	/// Describes the layout by its channel descriptions, every channel's label unknown.
	public mutating func setAllToUnknown() {
		makeUnique()
		storage.layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
		storage.layout.pointee.mChannelBitmap = []
		for i in 0..<storage.count {
			storage.descriptions[i] = AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Unknown,
			                                                  mChannelFlags: [], mCoordinates: (0, 0, 0))
		}
	}

	public var channelDescriptions: ChannelDescriptions {
		_read { yield ChannelDescriptions(storage: storage) }
		_modify {
			makeUnique()
			// Lend the storage out, so that the descriptions hold its only reference while they change.
			var descriptions = ChannelDescriptions(storage: storage)
			storage = ManagedAudioChannelLayout.lent
			defer { storage = descriptions.storage }
			yield &descriptions
		}
	}

	private static let lent = Storage(maximumDescriptions: 0)

	public var sizeInBytes: Int { AudioChannelLayout.sizeInBytes(maximumDescriptions: storage.count) }

	/// The channels the tag stands for: its descriptions, the bitmap's channels, or the count
	/// in the tag's low 16 bits.
	public var numberOfChannels: Int {
		switch tag {
		case kAudioChannelLayoutTag_UseChannelDescriptions: return storage.count
		case kAudioChannelLayoutTag_UseChannelBitmap: return bitmap.rawValue.nonzeroBitCount
		default: return Int(tag & 0xFFFF)
		}
	}

	public func withUnsafePointer<Result>(_ body: (Swift.UnsafePointer<AudioChannelLayout>) throws -> Result) rethrows -> Result {
		try withExtendedLifetime(storage) { try body(Swift.UnsafePointer(storage.layout)) }
	}

	public mutating func withUnsafeMutablePointer<Result>(_ body: (Swift.UnsafeMutablePointer<AudioChannelLayout>) throws -> Result) rethrows -> Result {
		makeUnique()
		return try withExtendedLifetime(storage) { try body(storage.layout) }
	}

	public struct ChannelDescriptions: MutableCollection, RandomAccessCollection {
		public typealias Element = AudioChannelDescription
		public typealias Index = Int

		fileprivate var storage: Storage

		public var startIndex: Int { 0 }
		public var endIndex: Int { storage.count }
		public var count: Int { storage.count }

		public subscript(index: Int) -> AudioChannelDescription {
			_read {
				precondition(index >= 0 && index < count, "subscript index out of range")
				yield storage.descriptions[index]
			}
			_modify {
				precondition(index >= 0 && index < count, "subscript index out of range")
				if storage.isAdopted || !isKnownUniquelyReferenced(&storage) {
					storage = storage.copy()
				}
				yield &storage.descriptions[index]
			}
		}
	}
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension ManagedAudioChannelLayout.ChannelDescriptions: Equatable {
	public static func == (lhs: ManagedAudioChannelLayout.ChannelDescriptions,
	                       rhs: ManagedAudioChannelLayout.ChannelDescriptions) -> Bool {
		lhs.elementsEqual(rhs, by: ==)
	}
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension ManagedAudioChannelLayout: Equatable {
	public static func == (lhs: ManagedAudioChannelLayout, rhs: ManagedAudioChannelLayout) -> Bool {
		lhs.tag == rhs.tag && lhs.bitmap == rhs.bitmap && lhs.channelDescriptions == rhs.channelDescriptions
	}
}
