# Copyright (C) 2026 Lubos Dolezel
#
# Swift overlays for SDK frameworks (IOKit, CoreAudio, AppKit, ...), built from the sources of the Swift 5.2.2 release
# (apple/swift tag swift-5.2.2-RELEASE, stdlib/public/Darwin/<Framework>). Included from the parent CMakeLists.txt
# when the Swift toolchain was found, so ${OVERLAYS} and ${overlay_shims} are set.

add_darling_swift_library(IOKit
	SOURCES "${OVERLAYS}/IOKit/IOReturn.swift"
	MODULES Dispatch CoreFoundation ObjectiveC Darwin
	FLAGS ${overlay_shims}
	LIBRARIES IOKit)

# CoreAudio: Darling's CoreAudio headers have no Clang module, so the overlay imports the declarations in
# overlays/CoreAudio/shims instead (it also has the AudioChannelLayout and ManagedAudioChannelLayout types).
add_darling_swift_library(CoreAudio
	SOURCES "${OVERLAYS}/CoreAudio/CoreAudio.swift"
	MODULES Dispatch CoreFoundation ObjectiveC Darwin
	FLAGS ${overlay_shims}
		-Xcc -fmodule-map-file=${OVERLAYS}/CoreAudio/shims/module.modulemap
	LIBRARIES CoreAudio)

# AppKit: the 5.2.2 overlay sources (AppKit.swift, AppKit_FoundationExtensions.swift, NSError.swift, NSEvent.swift,
# NSGraphics.swift, NSOpenGL.swift), unmodified. They compile against the declarations, API notes and module map of
# Darling's AppKit headers (nested type names, typed enums, the `__`-prefixed refined functions).
file(GLOB APPKIT_OVERLAY_SOURCES "${OVERLAYS}/AppKit/*.swift")
add_darling_swift_library(AppKit
	SOURCES ${APPKIT_OVERLAY_SOURCES}
	MODULES Foundation CoreGraphics Dispatch CoreFoundation ObjectiveC Darwin
	FLAGS ${overlay_shims}
	LIBRARIES AppKit Foundation)

add_darling_swift_library(Compression
	SOURCES "${OVERLAYS}/Compression/Compression.swift"
	MODULES Foundation Dispatch CoreFoundation ObjectiveC Darwin
	FLAGS ${overlay_shims}
	LIBRARIES compression)

# CoreText: AttributedString.AdaptiveImageGlyph and the CTAdaptiveImageGlyph conversions, written for Darling from the
# documented API. The CoreText Clang module comes from the SDK; the private CTAdaptiveImageGlyph class is declared by
# overlays/CoreText/shims. The conversion has package access (exported under its macOS mangled name), hence
# -package-name.
add_darling_swift_library(CoreText
	SOURCES "${OVERLAYS}/CoreText/CoreText.swift"
	MODULES Foundation CoreGraphics Dispatch CoreFoundation ObjectiveC Darwin
	WEAK_MODULES Combine
	FLAGS ${overlay_shims} -package-name swift-coretext
		-Xcc -fmodule-map-file=${OVERLAYS}/CoreText/shims/module.modulemap
	LIBRARIES CoreText Foundation)

# UniformTypeIdentifiers: UTType and UTTagClass over the framework's Objective-C UTType
# (imported as UTTypeReference through the framework's Clang module and API notes in the SDK). Written for Darling.
add_darling_swift_library(UniformTypeIdentifiers
	SOURCES "${OVERLAYS}/UniformTypeIdentifiers/UniformTypeIdentifiers.swift"
	MODULES Foundation Dispatch CoreFoundation ObjectiveC Darwin
	WEAK_MODULES Combine
	FLAGS ${overlay_shims}
	LIBRARIES UniformTypeIdentifiers Foundation)

# Network. Two overlays share the module name; DARLING_SWIFT_NETWORK_OVERLAY picks one:
#   sockets    (default) overlays/Network/Sockets: written for Darling over BSD sockets and Dispatch, with TLS from
#              libnetwork's libtls session. Darling's libnetwork only stubs the nw_* C API (nw_connection_start does
#              nothing), so this is the one whose connections, listeners and TLS work. Also what overlays/build.sh builds.
#   libnetwork overlays/Network/NW*.swift: NWConnection, NWListener, NWPath and the other Swift types over the nw_*
#              C API of libnetwork. It imports the shim module _SwiftNetworkOverlayShims
#              (overlays/shims/NetworkOverlayShims.h, part of ${overlay_shims}) and needs the SDK's Network Clang
#              module. Use it when libnetwork implements the API.
set(DARLING_SWIFT_NETWORK_OVERLAY "sockets" CACHE STRING "Network overlay to build: sockets or libnetwork")
set_property(CACHE DARLING_SWIFT_NETWORK_OVERLAY PROPERTY STRINGS sockets libnetwork)
if (DARLING_SWIFT_NETWORK_OVERLAY STREQUAL "libnetwork")
	file(GLOB NETWORK_SOURCES "${OVERLAYS}/Network/*.swift")
	set(NETWORK_FLAGS ${overlay_shims})
elseif (DARLING_SWIFT_NETWORK_OVERLAY STREQUAL "sockets")
	file(GLOB NETWORK_SOURCES "${OVERLAYS}/Network/Sockets/*.swift")
	set(NETWORK_FLAGS ${overlay_shims}
		-Xcc -fmodule-map-file=${OVERLAYS}/Network/Sockets/shims/module.modulemap)
else()
	message(FATAL_ERROR "DARLING_SWIFT_NETWORK_OVERLAY must be sockets or libnetwork")
endif()
add_darling_swift_library(Network
	SOURCES ${NETWORK_SOURCES}
	MODULES Foundation Dispatch CoreFoundation ObjectiveC Darwin
	FLAGS ${NETWORK_FLAGS}
	LIBRARIES Network Security)
