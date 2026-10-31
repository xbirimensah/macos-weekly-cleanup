// Launcher for weekly-cleanup.sh.
//
// It exists so Full Disk Access can be granted to this one small binary
// instead of /bin/bash (granting it to bash would hand it to every bash script
// on the machine). macOS attributes the child's file access to this binary.
//
// The grant must not extend to code it wasn't built for, so:
// - the SHA-256 of weekly-cleanup.sh is compiled in (runner/build.sh fills in
//   the placeholder below) and the runner refuses any other script;
// - the script is read once, checked, and handed to bash as text, so it can't
//   be swapped between the check and the run;
// - bash gets a fixed environment (HOME from the user database, fixed PATH),
//   so variables like WEEKLY_CLEANUP_TMP_X or HOME can't redirect what it
//   deletes.
// Editing the script therefore means rebuilding the runner (install.sh does
// it), and a rebuilt binary needs Full Disk Access granted again.
import CryptoKit
import Foundation

let expectedSHA256 = "@SCRIPT_SHA256@"
let fixedPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("weekly-cleanup-runner: \(message)\n".data(using: .utf8)!)
    exit(1)
}

guard expectedSHA256.count == 64 else {
    fail("built without a script hash. Build it with install.sh or runner/build.sh")
}

let selfURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    .resolvingSymlinksInPath()
let scriptPath = selfURL.deletingLastPathComponent().appendingPathComponent("weekly-cleanup.sh").path

guard let body = FileManager.default.contents(atPath: scriptPath) else {
    fail("cannot read \(scriptPath)")
}
let actualSHA256 = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
guard actualSHA256 == expectedSHA256 else {
    fail("\(scriptPath) changed since this runner was built. Run install.sh again, then re-grant Full Disk Access.")
}
guard let scriptText = String(data: body, encoding: .utf8) else {
    fail("\(scriptPath) is not UTF-8 text")
}

guard let pw = getpwuid(getuid()) else { fail("cannot look up the current user") }
let home = String(cString: pw.pointee.pw_dir)
let user = String(cString: pw.pointee.pw_name)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
process.arguments = ["-c", scriptText, "weekly-cleanup.sh"] + CommandLine.arguments.dropFirst()
process.environment = ["HOME": home, "USER": user, "LOGNAME": user, "PATH": fixedPath, "LC_ALL": "C"]
do { try process.run() } catch { fail("spawn failed: \(error)") }
process.waitUntilExit()
exit(process.terminationStatus)
