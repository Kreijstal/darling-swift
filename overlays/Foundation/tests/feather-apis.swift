// Exercises the Foundation additions Feather binds through the iOS SDK's interface: the CocoaError
// file codes, URLComponents' ranges, URLResourceValues' sizes and dates, String(contentsOf:encoding:)
// and String.availableStringEncodings, and NSNumber's Bool bridging.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
	print((ok ? "ok   " : "FAIL ") + what)
	fflush(stdout)
	if !ok { failures += 1 }
}

// CocoaError
check(CocoaError.fileNoSuchFile.rawValue == 4 && CocoaError.Code.fileNoSuchFile.rawValue == 4, "fileNoSuchFile is 4")
check(CocoaError.fileReadNoSuchFile.rawValue == 260 && CocoaError.Code.fileWriteOutOfSpace.rawValue == 640, "file read/write codes")

// NSNumber bridging: +numberWithBool: answers a CFBoolean
let yes: Any = NSNumber(value: true), no: Any = NSNumber(value: false), one: Any = NSNumber(value: 1)
check(yes as? Bool == true && no as? Bool == false && one as? Bool == true && (NSNumber(value: 2) as Any) as? Bool == nil, "NSNumber as? Bool")

// URLComponents ranges
let c = URLComponents(string: "https://user:pw@example.com:8443/a/b%20c?x=1&y=2#frag")!
let s = c.string!
func text(_ r: Range<String.Index>?) -> String? { r.map { String(s[$0]) } }
check(text(c.rangeOfPath) == "/a/b%20c", "rangeOfPath")
check(text(c.rangeOfScheme) == "https" && text(c.rangeOfHost) == "example.com" && text(c.rangeOfPort) == "8443", "scheme/host/port ranges")
check(text(c.rangeOfUser) == "user" && text(c.rangeOfPassword) == "pw", "user/password ranges")
check(text(c.rangeOfQuery) == "x=1&y=2" && text(c.rangeOfFragment) == "frag", "query/fragment ranges")
let bare = URLComponents(string: "file.txt")!
check(bare.rangeOfPath.map { String(bare.string![$0]) } == "file.txt" && bare.rangeOfHost == nil && bare.rangeOfScheme == nil, "relative path ranges")
var made = URLComponents()
made.scheme = "http"; made.host = "h"; made.path = "/p"
check(made.rangeOfPath.map { String(made.string![$0]) } == "/p" && made.rangeOfQuery == nil, "ranges of built components")

// Files
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fndtest-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let file = dir.appendingPathComponent("hello.txt")
let body = String(repeating: "héllo wörld\n", count: 1000)
try! body.data(using: .utf8)!.write(to: file)

check((try? String(contentsOf: file, encoding: .utf8)) == body, "String(contentsOf:encoding:) utf8")
check((try? String(contentsOfFile: file.path, encoding: .utf8)) == body, "String(contentsOfFile:encoding:)")
do {
	_ = try String(contentsOf: dir.appendingPathComponent("missing"), encoding: .utf8)
	check(false, "missing file throws")
} catch {
	check((error as NSError).domain == NSCocoaErrorDomain, "missing file throws a Cocoa error (\((error as NSError).code))")
}
let bad = dir.appendingPathComponent("bad.txt")
try! Data([0xff, 0xfe, 0xc0, 0x80]).write(to: bad)
do {
	_ = try String(contentsOf: bad, encoding: .utf8)
	check(false, "invalid UTF-8 throws")
} catch let error as CocoaError {
	check(error.code == .fileReadInapplicableStringEncoding, "invalid UTF-8 throws fileReadInapplicableStringEncoding")
} catch {
	check(false, "invalid UTF-8 throws a CocoaError, not \(error)")
}

let encodings = String.availableStringEncodings
check(encodings.contains(.utf8) && encodings.contains(.isoLatin1) && encodings.contains(.utf16), "availableStringEncodings (\(encodings.count))")

let values = try! file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .totalFileSizeKey, .contentAccessDateKey, .contentModificationDateKey, .isUbiquitousItemKey, .fileSizeKey])
let size = body.utf8.count
check(values.fileSize == size && values.totalFileSize == size, "file sizes \(values.fileSize ?? -1)")
check((values.totalFileAllocatedSize ?? 0) >= size && values.fileAllocatedSize == values.totalFileAllocatedSize, "allocated size \(values.totalFileAllocatedSize ?? -1)")
check(values.contentAccessDate.map { abs($0.timeIntervalSinceNow) < 3600 } == true, "contentAccessDate")
check(values.contentModificationDate.map { abs($0.timeIntervalSinceNow) < 3600 } == true, "contentModificationDate")
check(values.isUbiquitousItem == false, "isUbiquitousItem")

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
