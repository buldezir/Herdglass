import Testing
@testable import Herdglass

private func ranked(_ query: String, _ paths: [String]) -> [String] {
    FuzzyIndex(paths: paths).search(query, limit: paths.count).matches.map(\.path)
}

struct FuzzyMatcherTests {

    @Test func aQueryMatchesItsCharactersInOrderWithGaps() {
        #expect(FuzzyIndex.match("fbv", in: "Sources/Files/FileBrowserView.swift") != nil)
        #expect(FuzzyIndex.match("vbf", in: "Sources/Files/FileBrowserView.swift") == nil)
        #expect(FuzzyIndex.match("toolong", in: "tool") == nil)
        #expect(FuzzyIndex(paths: ["a"]).search("   ", limit: 10).matches.isEmpty)
    }

    @Test func lowercaseIgnoresCaseAndACapitalMakesItExact() {
        #expect(FuzzyIndex.match("readme", in: "README.md") != nil)
        #expect(FuzzyIndex.match("ReadMe", in: "README.md") == nil)
        #expect(FuzzyIndex.match("README", in: "README.md") != nil)
    }

    @Test func spacesInTheQueryAreDropped() {
        #expect(FuzzyIndex.match("file view", in: "FileBrowserView.swift") != nil)
    }

    /// The positions are UTF-16 offsets, so they index an `NSString` directly
    /// even past a character outside the BMP.
    @Test func positionsAreWhereTheBestAlignmentPutEachCharacter() {
        #expect(FuzzyIndex.match("fbv", in: "Files/FileBrowserView.swift")?.positions == [6, 10, 17])
        #expect(FuzzyIndex.match("ab", in: "😀/ab")?.positions == [3, 4])
    }

    @Test func theFilesOwnNameBeatsTheFoldersAboveIt() {
        let paths = ["Sources/Herdglass/Files/SyntaxTheme.swift", "Sources/Herdglass/Files/FileBrowser.swift"]
        #expect(ranked("files", paths).first == "Sources/Herdglass/Files/FileBrowser.swift")
        #expect(ranked("theme", paths) == ["Sources/Herdglass/Files/SyntaxTheme.swift"])
    }

    @Test func wordStartsAndRunsBeatScatteredLetters() {
        let paths = ["src/fabulous_overview.txt", "src/FileBrowserView.swift"]
        #expect(ranked("fbv", paths).first == "src/FileBrowserView.swift")
        #expect(ranked("browser", ["b/r/o/w/s/e/r.txt", "lib/browser.js"]).first == "lib/browser.js")
        // Two letters in a row in a folder do not outweigh three humps in the
        // file's own name.
        let humps = ["onnx/flatbuffers_py/fbs/ValueInfo.py", "app/units/FileBrowserView.swift"]
        #expect(ranked("fbv", humps).first == "app/units/FileBrowserView.swift")
    }

    @Test func aTieGoesToTheShorterPath() {
        #expect(ranked("readme", ["docs/guide/README.md", "README.md"]) == ["README.md", "docs/guide/README.md"])
    }

    @Test func theLimitKeepsTheBestAndTheTotalCountsTheRest() {
        let paths = (0..<50).map { "dir/file\($0).txt" } + ["other.md"]
        let result = FuzzyIndex(paths: paths).search("file", limit: 10)
        #expect(result.matches.count == 10)
        #expect(result.total == 50)
    }
}
