import AppKit
import Darwin
import Foundation
import ScreenReplayKit

private func writeJSONLine(_ obj: [String: Any]) {
  if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
     var line = String(data: data, encoding: .utf8)
  {
    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
  }
}

let args = CommandLine.arguments
let subcommand = args.count > 1 ? args[1] : ""

switch subcommand {
case "status":
  writeJSONLine(Status.now())
  exit(0)

case "probe-refresh":
  RefreshProbe.runCLI(arguments: Array(args.dropFirst(2)))

default:
  let env = ProcessInfo.processInfo.environment
  let paths = RecorderPaths.fromEnvironment(env)
  let socketPath = env["SR_HELPER_SOCKET"] ?? paths.socketPath
  let headless = env["SR_HELPER_HEADLESS_TEST"] == "1"
  let autoResume = env["SR_AUTO_RESUME_RECORD"] == "1"

  let token: String
  if let envToken = env["SR_HELPER_TOKEN"], !envToken.isEmpty {
    token = envToken
  } else if let fileToken = try? String(contentsOfFile: paths.tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            !fileToken.isEmpty
  {
    token = fileToken
  } else {
    FileHandle.standardError.write(Data("ScreenReplayHelper: missing SR_HELPER_TOKEN and \(paths.tokenPath)\n".utf8))
    exit(2)
  }

  let daemon = HelperDaemon(socketPath: socketPath, token: token, paths: paths, headlessTest: headless)
  do {
    try daemon.start(autoResumeRecording: autoResume)
  } catch {
    FileHandle.standardError.write(Data("ScreenReplayHelper: failed to start daemon: \(error)\n".utf8))
    exit(1)
  }

  signal(SIGINT, SIG_IGN)
  signal(SIGTERM, SIG_IGN)
  let sigQueue = DispatchQueue(label: "dev.pengx17.screenreplay.helper.sig")
  let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: sigQueue)
  let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: sigQueue)
  let cleanExit: () -> Void = {
    daemon.shutdown()
    exit(0)
  }
  sigInt.setEventHandler(handler: cleanExit)
  sigTerm.setEventHandler(handler: cleanExit)
  sigInt.resume()
  sigTerm.resume()

  if headless {
    RunLoop.main.run()
  } else {
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.accessory)
    app.run()
  }
}
