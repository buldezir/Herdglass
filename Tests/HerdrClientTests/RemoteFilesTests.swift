import Foundation
import Testing
@testable import HerdrClient

/// A fresh folder, by its real path: `$TMPDIR` is under `/var`, which is a
/// link to `/private/var`, and `git` and `pwd -P` answer with the latter.
/// (`resolvingSymlinksInPath` is no help — it strips `/private` back off.)
private func filesFixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdglass-files-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    guard let real = realpath(folder.path, nil) else { return folder }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real))
}

/// The scripts the way a remote host receives them: `ssh host bash -s`, whose
/// argv the login shell re-splits, and the script itself on stdin.
private let throughZsh = RemoteFiles { script, timeout in
    ProcessRunner.run(executable: "/bin/zsh", arguments: ["-c", "bash -s"], extraEnv: [:], stdin: script, timeout: timeout)
}

private func inode(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue ?? -1
}

@Suite(.serialized)
struct RemoteFilesTests {

    @Test func listingSurvivesHostileNamesAndPutsFoldersFirst() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let names = ["plain.txt", "with space.md", "quote ' $(touch injected);.sh", "new\nline", "-leading", ".hidden", "b10", "b2"]
        for name in names { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        try fm.createDirectory(at: root.appendingPathComponent("zdir"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("adir-link").path, withDestinationPath: "zdir")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("file-link").path, withDestinationPath: "plain.txt")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")

        let listing = try throughZsh.list(root.path)
        #expect(!listing.truncated)
        #expect(Array(listing.entries.prefix(2)) == [
            RemoteFileEntry(name: "adir-link", kind: .directory, isSymlink: true),
            RemoteFileEntry(name: "zdir", kind: .directory),
        ])
        #expect(Set(listing.entries.map(\.name)) == Set(names + ["zdir", "adir-link", "file-link", "dangling"]))
        #expect(listing.entries.first { $0.name == "file-link" } == RemoteFileEntry(name: "file-link", kind: .file, isSymlink: true))
        #expect(listing.entries.first { $0.name == "dangling" }?.kind == .other)
        let b2 = listing.entries.firstIndex { $0.name == "b2" }!
        let b10 = listing.entries.firstIndex { $0.name == "b10" }!
        #expect(b2 < b10)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("injected").path))
    }

    @Test func listingStopsAtItsLimitAndSaysSo() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<12 { try Data().write(to: root.appendingPathComponent("f\(index)")) }
        let listing = try throughZsh.list(root.path, limit: 5)
        #expect(listing.entries.count == 5)
        #expect(listing.truncated)
    }

    @Test func readReturnsTheBytesAndWhetherTheFileIsWritable() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data ' $(x).bin")
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try bytes.write(to: file)
        let contents = try throughZsh.read(file.path)
        #expect(contents.data == bytes)
        #expect(contents.size == bytes.count)
        #expect(contents.writable)
        #expect(!contents.token.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        #expect(try !throughZsh.read(file.path).writable)

        let empty = root.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try throughZsh.read(empty.path).data == Data())
    }

    @Test func aFileOverTheLimitIsDescribedButNotSent() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("big.log")
        try Data(repeating: 65, count: 5_000).write(to: file)
        let contents = try throughZsh.read(file.path, limit: 1_000)
        #expect(contents.data == nil)
        #expect(contents.size == 5_000)
    }

    @Test func readRefusesAFolderAndAMissingFile() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: HerdrRPCError.self) { try throughZsh.read(root.path) }
        #expect(throws: HerdrRPCError.self) { try throughZsh.read(root.appendingPathComponent("missing").path) }
        #expect(throws: HerdrRPCError.self) { try throughZsh.read("relative/path") }
    }

    @Test func saveWritesIntoTheFileAndKeepsItsModeAndInode() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("script ' $(touch injected).sh")
        try Data("#!/bin/sh\necho old\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let link = root.appendingPathComponent("hard-link")
        try FileManager.default.linkItem(at: file, to: link)
        let before = try inode(file)

        let opened = try throughZsh.read(file.path)
        let edited = Data("#!/bin/sh\necho new — ünïcode\n".utf8) + Data([0, 255, 10])
        let token = try throughZsh.save(edited, to: file.path, expecting: opened.token)

        #expect(try Data(contentsOf: file) == edited)
        #expect(try Data(contentsOf: link) == edited)
        #expect(try inode(file) == before)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
        #expect(token == (try throughZsh.read(file.path).token))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    }

    @Test func saveRefusesAFileThatMovedSinceItWasOpenedUnlessForced() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        try Data("one\n".utf8).write(to: file)
        let opened = try throughZsh.read(file.path)
        try Data("one\nsomebody else\n".utf8).write(to: file)

        do {
            try throughZsh.save(Data("mine\n".utf8), to: file.path, expecting: opened.token)
            Issue.record("A moved file was overwritten.")
        } catch {
            #expect(RemoteFiles.isChangedOnHost(error))
        }
        #expect(try Data(contentsOf: file) == Data("one\nsomebody else\n".utf8))

        try throughZsh.save(Data("mine\n".utf8), to: file.path, expecting: nil)
        #expect(try Data(contentsOf: file) == Data("mine\n".utf8))
    }

    @Test func saveCanEmptyAFile() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("to-empty")
        try Data("content".utf8).write(to: file)
        let opened = try throughZsh.read(file.path)
        try throughZsh.save(Data(), to: file.path, expecting: opened.token)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func rootIsTheRepositoryAroundTheDirectoryOrTheDirectoryItself() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo ' x")
        let nested = repo.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let initialised = ProcessRunner.run(executable: "/usr/bin/git", arguments: ["init", "-q", repo.path], extraEnv: [:], timeout: 10)
        try #require(initialised.terminationStatus == 0)

        #expect(try throughZsh.resolveRoot(from: nested.path).path == repo.path)
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
        #expect(try throughZsh.resolveRoot(from: plain.path).path == plain.path)

        let home = try throughZsh.resolveRoot(from: nil)
        #expect(home.home.hasPrefix("/"))
        #expect(try throughZsh.resolveRoot(from: root.appendingPathComponent("gone").path).home == home.home)
    }

    @Test func rootDisplaysUnderHomeAsATilde() {
        #expect(RemoteRoot(path: "/home/me/app", home: "/home/me").displayPath == "~/app")
        #expect(RemoteRoot(path: "/home/me", home: "/home/me").displayPath == "~")
        #expect(RemoteRoot(path: "/home/meadow", home: "/home/me").displayPath == "/home/meadow")
        #expect(RemoteRoot(path: "/srv", home: "/").displayPath == "/srv")
    }

    @Test func aLocalConnectionRunsTheSameScriptsAndAClosedOneRefuses() throws {
        let root = try filesFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        let connection = try RemoteConnection(target: ConnectTarget(host: "local"))
        #expect(try connection.files.list(root.path).entries.map(\.name) == ["a.txt"])
        connection.close()
        #expect(throws: HerdrRPCError.self) { try connection.files.list(root.path) }
    }
}
