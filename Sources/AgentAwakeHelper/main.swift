import Darwin
import Dispatch
import Foundation

private let statePath = "/var/db/agent-awake/state.json"
private let stateDirectory = "/var/db/agent-awake"
private let ownershipMarkerPath = "/var/db/agent-awake/owns-sleep-override"
private let lockPath = "/var/run/agent-awake.lock"
private let batteryFloor = 20

private enum AwakeMode: String, Codable {
  case screen
  case agents
  case everything

  var keepsDisplayOn: Bool {
    self == .screen || self == .everything
  }

  var keepsMacAwake: Bool {
    self == .agents || self == .everything
  }
}

private enum SessionLimit: Codable {
  case indefinite
  case timed(durationSeconds: Int, deadline: Date)

  var isExpired: Bool {
    switch self {
    case .indefinite:
      false
    case .timed(_, let deadline):
      Date() >= deadline
    }
  }
}

private struct State: Codable {
  let mode: AwakeMode
  let limit: SessionLimit
}

private struct Status: Encodable {
  let active: Bool
  let mode: AwakeMode?
  let durationSeconds: Int?
  let remainingSeconds: Int?
}

private struct BatteryState {
  let level: Int
  let isOnBattery: Bool
}

private enum StateFile {
  case missing
  case valid(State)
  case unreadable
}

private enum SessionSnapshot {
  case inactive
  case active(State)
  case externalOverride
  case recovered(HelperError)
}

private enum HelperError: LocalizedError {
  case invalidArguments
  case notRoot
  case processFailed(String)
  case lockFailed
  case stateRecovered
  case stateDiscarded
  case unownedSleepOverride
  case lowBattery

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      "Invalid Awake helper arguments."
    case .notRoot:
      "Awake needs administrator approval. Run its install script first."
    case .processFailed(let message):
      message
    case .lockFailed:
      "Awake could not lock its state."
    case .stateRecovered:
      "Awake found invalid state and restored normal sleep."
    case .stateDiscarded:
      "Awake found invalid state and ended its session without changing another sleep override."
    case .unownedSleepOverride:
      "System sleep is disabled by another process. Awake will not change it."
    case .lowBattery:
      "Awake cannot start while the battery is at or below 20%."
    }
  }
}

private final class DisplayAssertion {
  private var process: Process?

  func setEnabled(_ enabled: Bool) throws {
    guard enabled else {
      stop()
      return
    }
    guard process?.isRunning != true else {
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    process.arguments = ["-d", "-i", "-w", String(getpid())]
    try process.run()
    self.process = process
  }

  func stop() {
    if process?.isRunning == true {
      process?.terminate()
    }
    process = nil
  }
}

private func withLock<T>(_ action: () throws -> T) throws -> T {
  let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
  guard descriptor >= 0 else {
    throw HelperError.lockFailed
  }
  defer { close(descriptor) }
  guard flock(descriptor, LOCK_EX) == 0 else {
    throw HelperError.lockFailed
  }
  defer { flock(descriptor, LOCK_UN) }
  return try action()
}

private func run(_ executable: String, _ arguments: [String]) throws -> String {
  let process = Process()
  let output = Pipe()
  let errors = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = output
  process.standardError = errors
  try process.run()
  process.waitUntilExit()

  let outputText = String(
    decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  guard process.terminationStatus == 0 else {
    let errorText = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    throw HelperError.processFailed(
      errorText.isEmpty ? "The macOS power setting could not be changed." : errorText)
  }
  return outputText
}

private func readStateFile() -> StateFile {
  guard FileManager.default.fileExists(atPath: statePath) else {
    return .missing
  }
  do {
    let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
    return .valid(try JSONDecoder().decode(State.self, from: data))
  } catch {
    return .unreadable
  }
}

private func writeState(_ state: State) throws {
  try FileManager.default.createDirectory(
    atPath: stateDirectory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o755]
  )
  let data = try JSONEncoder().encode(state)
  try data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: statePath)
}

private func writeOwnershipMarker() throws {
  try FileManager.default.createDirectory(
    atPath: stateDirectory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o755]
  )
  try Data().write(to: URL(fileURLWithPath: ownershipMarkerPath), options: .atomic)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600], ofItemAtPath: ownershipMarkerPath)
}

private func removeOwnershipMarker() throws {
  guard FileManager.default.fileExists(atPath: ownershipMarkerPath) else {
    return
  }
  try FileManager.default.removeItem(atPath: ownershipMarkerPath)
}

private func ownsSleepOverride() -> Bool {
  FileManager.default.fileExists(atPath: ownershipMarkerPath)
}

private func removeState() throws {
  guard FileManager.default.fileExists(atPath: statePath) else {
    return
  }
  try FileManager.default.removeItem(atPath: statePath)
}

private func sleepIsDisabled() throws -> Bool {
  let output = try run("/usr/bin/pmset", ["-g"])
  return output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
}

private func report(_ error: Error) {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
}

private func refreshMonitor() throws {
  _ = try run(
    "/bin/launchctl", ["kill", "SIGUSR1", "system/dev.herdr.AgentAwakeHelper"])
}

private func notifyMonitor() {
  do {
    try refreshMonitor()
  } catch {
    report(error)
  }
}

private func batteryState() throws -> BatteryState? {
  let output = try run("/usr/bin/pmset", ["-g", "batt"])
  guard
    let range = output.range(of: #"\d+%"#, options: .regularExpression),
    let level = Int(output[range].dropLast())
  else {
    return nil
  }
  return BatteryState(level: level, isOnBattery: output.contains("Battery Power"))
}

private func restoreSession() throws {
  if ownsSleepOverride() {
    _ = try run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
    try removeOwnershipMarker()
  }
  try removeState()
}

private func reconcileSession() throws -> SessionSnapshot {
  let stateFile = readStateFile()
  let ownsOverride = ownsSleepOverride()
  let disabled = try sleepIsDisabled()

  switch stateFile {
  case .valid(let state):
    if state.limit.isExpired {
      try restoreSession()
      return .inactive
    }
    if !state.mode.keepsMacAwake {
      if ownsOverride {
        try restoreSession()
        return .recovered(.stateRecovered)
      }
      return .active(state)
    }
    guard ownsOverride else {
      try removeState()
      return disabled ? .externalOverride : .recovered(.stateDiscarded)
    }
    if !disabled {
      _ = try run("/usr/bin/pmset", ["-a", "disablesleep", "1"])
    }
    return .active(state)
  case .missing:
    if ownsOverride {
      try restoreSession()
      return .recovered(.stateRecovered)
    }
    return disabled ? .externalOverride : .inactive
  case .unreadable:
    if ownsOverride {
      try restoreSession()
      return .recovered(.stateRecovered)
    }
    try removeState()
    return .recovered(.stateDiscarded)
  }
}

private func start(mode: AwakeMode, duration: Int) throws {
  guard duration == 0 || (60...43200).contains(duration) else {
    throw HelperError.invalidArguments
  }
  if let battery = try batteryState(), battery.isOnBattery && battery.level <= batteryFloor {
    throw HelperError.lowBattery
  }
  try refreshMonitor()

  try withLock {
    let snapshot = try reconcileSession()
    let sleepAlreadyDisabled = try sleepIsDisabled()
    if mode.keepsMacAwake && sleepAlreadyDisabled && !ownsSleepOverride() {
      throw HelperError.unownedSleepOverride
    }
    switch snapshot {
    case .inactive:
      break
    case .active(let state) where state.mode.keepsMacAwake == mode.keepsMacAwake:
      break
    case .active:
      try restoreSession()
    case .externalOverride where !mode.keepsMacAwake:
      break
    case .externalOverride:
      throw HelperError.unownedSleepOverride
    case .recovered(let error):
      throw error
    }

    let limit: SessionLimit =
      duration == 0
      ? .indefinite
      : .timed(
        durationSeconds: duration,
        deadline: Date().addingTimeInterval(TimeInterval(duration))
      )
    let state = State(mode: mode, limit: limit)
    do {
      if mode.keepsMacAwake && !sleepAlreadyDisabled {
        try writeOwnershipMarker()
      }
      try writeState(state)
      if mode.keepsMacAwake && !sleepAlreadyDisabled {
        _ = try run("/usr/bin/pmset", ["-a", "disablesleep", "1"])
      }
    } catch {
      try restoreSession()
      throw error
    }
  }
  notifyMonitor()
}

private func stop() throws {
  try withLock {
    do {
      if case .active = try reconcileSession() {
        try restoreSession()
      }
    } catch {
      try restoreSession()
      throw error
    }
  }
  notifyMonitor()
}

private func currentStatus() throws -> Status {
  try withLock {
    switch try reconcileSession() {
    case .inactive:
      return Status(
        active: false,
        mode: nil,
        durationSeconds: nil,
        remainingSeconds: nil
      )
    case .active(let state):
      let (durationSeconds, remainingSeconds): (Int?, Int?) =
        switch state.limit {
        case .indefinite:
          (nil, nil)
        case .timed(let durationSeconds, let deadline):
          (durationSeconds, max(0, Int(deadline.timeIntervalSinceNow.rounded(.down))))
        }
      return Status(
        active: true,
        mode: state.mode,
        durationSeconds: durationSeconds,
        remainingSeconds: remainingSeconds
      )
    case .externalOverride:
      throw HelperError.unownedSleepOverride
    case .recovered(let error):
      throw error
    }
  }
}

private func monitor() throws -> Never {
  let displayAssertion = DisplayAssertion()
  let wakeSemaphore = DispatchSemaphore(value: 0)
  signal(SIGUSR1, SIG_IGN)
  let wakeSource = DispatchSource.makeSignalSource(signal: SIGUSR1)
  wakeSource.setEventHandler {
    wakeSemaphore.signal()
  }
  wakeSource.resume()
  defer {
    wakeSource.cancel()
    displayAssertion.stop()
  }

  while true {
    do {
      try withLock {
        guard case .active(let state) = try reconcileSession() else {
          displayAssertion.stop()
          return
        }
        try displayAssertion.setEnabled(state.mode.keepsDisplayOn)
        let battery = try batteryState()
        let batteryReachedFloor =
          battery.map { $0.isOnBattery && $0.level <= batteryFloor } ?? false
        if state.limit.isExpired || batteryReachedFloor {
          try restoreSession()
          displayAssertion.stop()
        }
      }
    } catch {
      report(error)
    }
    _ = wakeSemaphore.wait(timeout: .now() + 10)
  }
}

private func execute() throws {
  guard geteuid() == 0 else {
    throw HelperError.notRoot
  }
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else {
    throw HelperError.invalidArguments
  }

  switch command {
  case "start":
    guard
      arguments.count == 3,
      let mode = AwakeMode(rawValue: arguments[1]),
      let duration = Int(arguments[2])
    else {
      throw HelperError.invalidArguments
    }
    try start(mode: mode, duration: duration)
  case "stop":
    guard arguments.count == 1 else {
      throw HelperError.invalidArguments
    }
    try stop()
  case "status":
    guard arguments.count == 1 else {
      throw HelperError.invalidArguments
    }
    let data = try JSONEncoder().encode(currentStatus())
    print(String(decoding: data, as: UTF8.self))
  case "monitor":
    guard arguments.count == 1 else {
      throw HelperError.invalidArguments
    }
    try monitor()
  default:
    throw HelperError.invalidArguments
  }
}

do {
  try execute()
} catch {
  report(error)
  exit(EXIT_FAILURE)
}
