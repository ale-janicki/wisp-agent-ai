import XCTest
@testable import WispCore

final class FileOpenPolicyTests: XCTestCase {
    private func action(_ ext: String, executable: Bool = false, directory: Bool = false) -> FileOpenPolicy.Action {
        FileOpenPolicy.action(pathExtension: ext, isExecutable: executable, isDirectory: directory)
    }

    func testDocumentsOpen() {
        for ext in ["txt", "md", "csv", "json", "png", "JPG", "heic", "mp4", "mov", "mp3", "m4a", "pdf", "html", "rtf",
                    "docx", "xlsx", "pptx", "pages", "numbers", "key", "odt"] {
            XCTAssertEqual(action(ext), .open, ext)
        }
    }

    func testProgramsScriptsAndBundlesAreRevealed() {
        for ext in ["app", "terminal", "command", "workflow", "pkg", "dmg", "jar", "webloc", "inetloc", "sh", "py", "scpt",
                    "zip", "tar", "gz", "docm", "exe", "unknownext123", ""] {
            XCTAssertEqual(action(ext), .reveal, ext)
        }
    }

    func testExecutableBitAndDirectoriesAlwaysReveal() {
        XCTAssertEqual(action("txt", executable: true), .reveal)
        XCTAssertEqual(action("pdf", directory: true), .reveal)
        XCTAssertEqual(action("png", executable: true, directory: true), .reveal)
    }
}
