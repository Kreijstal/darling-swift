# Explicit pinned source inputs; no prebuilt CryptoKit image or configure-time fetch.
set(DARLING_CRYPTOKIT_BASE_SOURCE "" CACHE PATH "Checkout of the pinned custom Swift Crypto source")
set(DARLING_CRYPTOKIT_AEAD_SOURCE "" CACHE PATH "Checkout of the pinned Swift Crypto 3.12.3 source")
if(NOT DARLING_CRYPTOKIT_BASE_SOURCE AND NOT DARLING_CRYPTOKIT_AEAD_SOURCE)
    return()
endif()
find_package(Git REQUIRED)
function(darling_verify_crypto_source root revision)
    if(NOT IS_DIRECTORY "${root}/.git")
        message(FATAL_ERROR "CryptoKit requires an independent ordinary Git checkout")
    endif()
    execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${root}" rev-parse HEAD
        OUTPUT_VARIABLE head OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET RESULT_VARIABLE result)
    if(NOT result EQUAL 0 OR NOT head STREQUAL revision)
        message(FATAL_ERROR "CryptoKit source revision mismatch")
    endif()
    execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${root}" remote get-url origin
        OUTPUT_VARIABLE origin OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET RESULT_VARIABLE result)
    if(NOT result EQUAL 0 OR NOT origin STREQUAL "https://github.com/apple/swift-crypto.git")
        message(FATAL_ERROR "CryptoKit source origin mismatch")
    endif()
    foreach(source IN LISTS ARGN)
        if(NOT EXISTS "${root}/${source}")
            message(FATAL_ERROR "CryptoKit selected source is absent")
        endif()
    endforeach()
    execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${root}" diff --quiet HEAD -- ${ARGN}
        ERROR_QUIET RESULT_VARIABLE result)
    if(NOT result EQUAL 0)
        message(FATAL_ERROR "CryptoKit selected source differs from the pinned commit")
    endif()
endfunction()
set(CRYPTOKIT_BASE_FILES
    "Sources/Crypto/Digests/Digest.swift"
    "Sources/Crypto/Digests/Digests.swift"
    "Sources/Crypto/Digests/HashFunctions.swift"
    "Sources/Crypto/Digests/HashFunctions_SHA2.swift"
    "Sources/Crypto/Digests/Darling/Digest_darling.swift"
    "Sources/Crypto/Keys/Symmetric/SymmetricKeys.swift"
    "Sources/Crypto/Insecure/Insecure.swift"
    "Sources/Crypto/Insecure/Insecure_HashFunctions.swift"
    "Sources/Crypto/Util/ArraySpanHelpers.swift"
    "Sources/Crypto/Util/Data+ArraySpan.swift"
    "Sources/Crypto/Util/PrettyBytes.swift"
    "Sources/Crypto/Util/SafeCompare.swift"
    "Sources/Crypto/Util/SecureBytes.swift"
    "Sources/Crypto/Util/Zeroization.swift"
    "Sources/Crypto/Util/BoringSSL/SafeCompare_boring.swift"
    "Sources/Crypto/Util/BoringSSL/RNG_boring.swift"
    "Sources/Crypto/Util/BoringSSL/InlineArray+withBytes_boring.swift"
    "Sources/Crypto/Util/BoringSSL/Optional+withUnsafeBytes_boring.swift"
    "Sources/Crypto/Message Authentication Codes/HMAC/HMAC.swift"
    "Sources/Crypto/Message Authentication Codes/MessageAuthenticationCode.swift"
    "Sources/Crypto/Message Authentication Codes/MACFunctions.swift"
    "Sources/Crypto/CryptoKitErrors.swift"
)
darling_verify_crypto_source("${DARLING_CRYPTOKIT_BASE_SOURCE}" "c4105ade5fbe6866375ec65146cac733d53a1146"
    ${CRYPTOKIT_BASE_FILES} LICENSE.txt NOTICE.txt)
set(CRYPTOKIT_AEAD_FILES
    "Sources/Crypto/PRF/AES.swift"
    "Sources/Crypto/AEADs/Cipher.swift"
    "Sources/Crypto/AEADs/Nonces.swift"
    "Sources/Crypto/AEADs/AES/GCM/AES-GCM.swift"
    "Sources/Crypto/AEADs/ChachaPoly/ChaChaPoly.swift"
)
darling_verify_crypto_source("${DARLING_CRYPTOKIT_AEAD_SOURCE}" "e8d6eba1fef23ae5b359c46b03f7d94be2f41fed"
    ${CRYPTOKIT_AEAD_FILES} LICENSE.txt NOTICE.txt)
set(CRYPTOKIT_SOURCES)
foreach(source IN LISTS CRYPTOKIT_BASE_FILES)
    list(APPEND CRYPTOKIT_SOURCES "${DARLING_CRYPTOKIT_BASE_SOURCE}/${source}")
endforeach()
foreach(source IN LISTS CRYPTOKIT_AEAD_FILES)
    list(APPEND CRYPTOKIT_SOURCES "${DARLING_CRYPTOKIT_AEAD_SOURCE}/${source}")
endforeach()
list(APPEND CRYPTOKIT_SOURCES
    "${OVERLAYS}/CryptoKit/AEAD.swift"
    "${OVERLAYS}/CryptoKit/P256.swift"
    "${OVERLAYS}/CryptoKit/HashFunctions_LibreSSL.swift"
)
foreach(source IN ITEMS AEAD.swift P256.swift HashFunctions_LibreSSL.swift
        aead.c aead.h p256.c p256.h digests.c digests.h module.modulemap)
    if(NOT EXISTS "${OVERLAYS}/CryptoKit/${source}")
        message(FATAL_ERROR "CryptoKit owned source input is absent")
    endif()
endforeach()
remove_sdk_framework(CryptoKit)
add_darling_swift_library(CryptoKit FRAMEWORK
    SOURCES ${CRYPTOKIT_SOURCES}
    NATIVE_SOURCES
        "${OVERLAYS}/CryptoKit/aead.c"
        "${OVERLAYS}/CryptoKit/p256.c"
        "${OVERLAYS}/CryptoKit/digests.c"
    MODULES Foundation Darwin ObjectiveC
    FLAGS ${overlay_shims} -I ${OVERLAYS}/CryptoKit
        -D DARLING_CRYPTOKIT_MODULE -D CRYPTO_IN_SWIFTPM_FORCE_BUILD_API
        -enable-experimental-feature Lifetimes
    NATIVE_FLAGS -I${OVERLAYS}/CryptoKit -I${CMAKE_SOURCE_DIR}/src/external/libressl-2.8.3/include
    LIBRARIES crypto)
foreach(part BASE AEAD)
    install(FILES "${DARLING_CRYPTOKIT_${part}_SOURCE}/LICENSE.txt" "${DARLING_CRYPTOKIT_${part}_SOURCE}/NOTICE.txt"
        DESTINATION "share/darling/licenses/CryptoKit/${part}")
endforeach()
