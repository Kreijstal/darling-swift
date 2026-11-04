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

// From release/5.4 stdlib/public/Darwin/Foundation/NSError.swift: CocoaError and its Code, with the file codes and
// the few others apps import (the rest of the code table is left out).

@_exported import Foundation // Clang module

public typealias NSCocoaError = CocoaError

/// Describes errors within the Cocoa error domain.
public struct CocoaError : _BridgedStoredNSError {
  public let _nsError: NSError

  public init(_nsError error: NSError) {
    precondition(error.domain() == NSCocoaErrorDomain)
    self._nsError = error
  }

  public static var errorDomain: String { return NSCocoaErrorDomain }

  public var hashValue: Int {
    return _nsError.hashValue
  }

  /// The error code itself.
  public struct Code : RawRepresentable, Hashable, _ErrorCodeProtocol {
    public typealias _ErrorType = CocoaError

    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }
  }
}

extension CocoaError.Code {
  public static var fileNoSuchFile: CocoaError.Code {
    return CocoaError.Code(rawValue: 4)
  }
  public static var fileLocking: CocoaError.Code {
    return CocoaError.Code(rawValue: 255)
  }
  public static var fileReadUnknown: CocoaError.Code {
    return CocoaError.Code(rawValue: 256)
  }
  public static var fileReadNoPermission: CocoaError.Code {
    return CocoaError.Code(rawValue: 257)
  }
  public static var fileReadInvalidFileName: CocoaError.Code {
    return CocoaError.Code(rawValue: 258)
  }
  public static var fileReadCorruptFile: CocoaError.Code {
    return CocoaError.Code(rawValue: 259)
  }
  public static var fileReadNoSuchFile: CocoaError.Code {
    return CocoaError.Code(rawValue: 260)
  }
  public static var fileReadInapplicableStringEncoding: CocoaError.Code {
    return CocoaError.Code(rawValue: 261)
  }
  public static var fileReadUnsupportedScheme: CocoaError.Code {
    return CocoaError.Code(rawValue: 262)
  }
  public static var fileReadTooLarge: CocoaError.Code {
    return CocoaError.Code(rawValue: 263)
  }
  public static var fileReadUnknownStringEncoding: CocoaError.Code {
    return CocoaError.Code(rawValue: 264)
  }
  public static var fileWriteUnknown: CocoaError.Code {
    return CocoaError.Code(rawValue: 512)
  }
  public static var fileWriteNoPermission: CocoaError.Code {
    return CocoaError.Code(rawValue: 513)
  }
  public static var fileWriteInvalidFileName: CocoaError.Code {
    return CocoaError.Code(rawValue: 514)
  }
  public static var fileWriteInapplicableStringEncoding: CocoaError.Code {
    return CocoaError.Code(rawValue: 517)
  }
  public static var fileWriteUnsupportedScheme: CocoaError.Code {
    return CocoaError.Code(rawValue: 518)
  }
  public static var fileWriteOutOfSpace: CocoaError.Code {
    return CocoaError.Code(rawValue: 640)
  }
  public static var fileWriteVolumeReadOnly: CocoaError.Code {
    return CocoaError.Code(rawValue: 642)
  }
  /// `NSFormattingError` (2048), which the format styles' parse strategies throw.
  public static var formatting: CocoaError.Code {
    return CocoaError.Code(rawValue: 2048)
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 5.0)
  public static var fileWriteFileExists: CocoaError.Code {
    return CocoaError.Code(rawValue: 516)
  }
  @available(macOS, introduced: 10.13) @available(iOS, introduced: 11.0)
  public static var coderInvalidValue: CocoaError.Code {
    return CocoaError.Code(rawValue: 4866)
  }
}

extension CocoaError {
  public static var fileNoSuchFile: CocoaError.Code {
    return CocoaError.Code(rawValue: 4)
  }
  public static var fileLocking: CocoaError.Code {
    return CocoaError.Code(rawValue: 255)
  }
  public static var fileReadUnknown: CocoaError.Code {
    return CocoaError.Code(rawValue: 256)
  }
  public static var fileReadNoPermission: CocoaError.Code {
    return CocoaError.Code(rawValue: 257)
  }
  public static var fileReadInvalidFileName: CocoaError.Code {
    return CocoaError.Code(rawValue: 258)
  }
  public static var fileReadCorruptFile: CocoaError.Code {
    return CocoaError.Code(rawValue: 259)
  }
  public static var fileReadNoSuchFile: CocoaError.Code {
    return CocoaError.Code(rawValue: 260)
  }
  public static var fileReadInapplicableStringEncoding: CocoaError.Code {
    return CocoaError.Code(rawValue: 261)
  }
  public static var fileReadUnsupportedScheme: CocoaError.Code {
    return CocoaError.Code(rawValue: 262)
  }
  public static var fileReadTooLarge: CocoaError.Code {
    return CocoaError.Code(rawValue: 263)
  }
  public static var fileReadUnknownStringEncoding: CocoaError.Code {
    return CocoaError.Code(rawValue: 264)
  }
  public static var fileWriteUnknown: CocoaError.Code {
    return CocoaError.Code(rawValue: 512)
  }
  public static var fileWriteNoPermission: CocoaError.Code {
    return CocoaError.Code(rawValue: 513)
  }
  public static var fileWriteInvalidFileName: CocoaError.Code {
    return CocoaError.Code(rawValue: 514)
  }
  public static var fileWriteInapplicableStringEncoding: CocoaError.Code {
    return CocoaError.Code(rawValue: 517)
  }
  public static var fileWriteUnsupportedScheme: CocoaError.Code {
    return CocoaError.Code(rawValue: 518)
  }
  public static var fileWriteOutOfSpace: CocoaError.Code {
    return CocoaError.Code(rawValue: 640)
  }
  public static var fileWriteVolumeReadOnly: CocoaError.Code {
    return CocoaError.Code(rawValue: 642)
  }
  /// `NSFormattingError`, declared on both types as in the SDK.
  public static var formatting: CocoaError.Code {
    return CocoaError.Code(rawValue: 2048)
  }

  @available(macOS, introduced: 10.7) @available(iOS, introduced: 5.0)
  public static var fileWriteFileExists: CocoaError.Code {
    return CocoaError.Code(rawValue: 516)
  }
  @available(macOS, introduced: 10.13) @available(iOS, introduced: 11.0)
  public static var coderInvalidValue: CocoaError.Code {
    return CocoaError.Code(rawValue: 4866)
  }
}
