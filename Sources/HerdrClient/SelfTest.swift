import Darwin
import Foundation

public enum SelfTest {
    public static func run(host: String, session: String?) {
        HerdrProcess.setUp()
        do {
            let target = ConnectTarget(host: host, session: session)
            fputs("Herdglass self-test: connecting to \(target.displayName)\n", stderr)
            let conn = try RemoteConnection(target: target)
            try conn.open()
            fputs("socket \(conn.localSocketPath)\n", stderr)
            let rpc = HerdrRPC(socketPath: conn.localSocketPath)
            let snap = try rpc.snapshot()
            fputs(
                "snapshot version=\(snap.version) workspaces=\(snap.workspaces.count) panes=\(snap.panes.count)\n",
                stderr
            )
            for workspace in snap.workspaces {
                fputs("  workspace \(workspace.workspaceId) \(workspace.label) \(workspace.agentStatus.rawValue)\n", stderr)
            }
            guard let paneId = snap.focusedPaneId ?? snap.panes.first?.paneId else {
                fputs("FAIL: no panes\n", stderr)
                conn.close()
                exit(1)
            }
            fputs("control \(paneId)\n", stderr)
            try probeControl(paneId: paneId, socketPath: conn.localSocketPath, herdrBinary: conn.herdrBinary)
            conn.close()
            fputs("OK\n", stderr)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func probeControl(paneId: String, socketPath: String, herdrBinary: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: herdrBinary)
        proc.arguments = ["terminal", "session", "control", paneId, "--takeover", "--cols", "80", "--rows", "24"]
        var env = HerdrPaths.loginPathEnv()
        env["HERDR_SOCKET_PATH"] = socketPath
        proc.environment = env
        let out = Pipe()
        let err = Pipe()
        let inp = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = inp
        try proc.run()
        let deadline = Date().addingTimeInterval(2.5)
        var buf = Data()
        var sawFrame = false
        while Date() < deadline, proc.isRunning {
            let chunk = out.fileHandleForReading.availableData
            if !chunk.isEmpty {
                buf.append(chunk)
                if let text = String(data: buf, encoding: .utf8), text.contains("terminal.frame") {
                    sawFrame = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        writeIgnoringBrokenPipe(
            inp.fileHandleForWriting.fileDescriptor,
            Data("{\"type\":\"terminal.release\"}\n".utf8)
        )
        try? inp.fileHandleForWriting.close()
        if proc.isRunning {
            proc.terminate()
        }
        proc.waitUntilExit()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !sawFrame {
            throw HerdrRPCError(
                code: "no_frame",
                message: "did not receive terminal.frame. stderr=\(errText) bytes=\(buf.count)"
            )
        }
        fputs("received terminal.frame (\(buf.count) bytes)\n", Darwin.stderr)
    }
}
