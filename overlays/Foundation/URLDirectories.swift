// Standard user document-directory lookup, following the public Foundation API.
import Foundation // Underlying Clang module, as in the canonical Foundation sources.

extension URL {
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
    public static var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
