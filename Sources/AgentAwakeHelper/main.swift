import Darwin
import Foundation

private let statePath = "/var/db/agent-awake/state.json"
private let stateDirectory = "/var/db/agent-awake"
private let ownershipMarkerPath = "/var/db/agent-awake/owns-sleep-override"
private let lockPath = "/var/run/agent-awake.lock"

private struct State: Codable {
  let durationSeconds: Int?
  let deadline: Date?
  let batteryFloor: Int
  let keepDisplayOn: Bool
}

private struct Status: Encodable {
  let active: Bool
  let batteryLevel: Int?
  let durationSeconds: Int?
  let remainingSeconds: Int?
  let keepDisplayOn: Bool
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
  case batteryUnavailable
  case inactiveSession

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
    case .batteryUnavailable:
      "Awake could not read the current battery level."
    case .inactiveSession:
      "Start Awake before changing its display setting."
    }
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

private func batteryState() throws -> BatteryState {
  let output = try run("/usr/bin/pmset", ["-g", "batt"])
  guard let range = output.range(of: #"\d+%"#, options: .regularExpression) else {
    throw HelperError.batteryUnavailable
  }
  guard let level = Int(output[range].dropLast()) else {
    throw HelperError.batteryUnavailable
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

  switch (stateFile, ownsOverride, disabled) {
  case (.valid(let state), _, true):
    return .active(state)
  case (.valid, true, false):
    try restoreSession()
    return .recovered(.stateRecovered)
  case (.valid, false, false):
    try removeState()
    return .inactive
  case (.missing, true, _), (.unreadable, true, _):
    try restoreSession()
    return .recovered(.stateRecovered)
  case (.unreadable, false, _):
    try removeState()
    return .recovered(.stateDiscarded)
  case (.missing, false, true):
    return .externalOverride
  case (.missing, false, false):
    return .inactive
  }
}

private func start(duration: Int, batteryFloor: Int, keepDisplayOn: Bool) throws {
  guard geteuid() == 0 else {
    throw HelperError.notRoot
  }
  guard duration == 0 || (60...43200).contains(duration), (5...50).contains(batteryFloor) else {
    throw HelperError.invalidArguments
  }

  try withLock {
    let snapshot = try reconcileSession()
    if case .recovered(let error) = snapshot {
      throw error
    }
    let alreadyDisabled =
      switch snapshot {
      case .active, .externalOverride:
        true
      case .inactive, .recovered:
        false
      }
    let durationSeconds = duration == 0 ? nil : duration
    let deadline = durationSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }
    let state = State(
      durationSeconds: durationSeconds,
      deadline: deadline,
      batteryFloor: batteryFloor,
      keepDisplayOn: keepDisplayOn
    )
    do {
      if !alreadyDisabled && !ownsSleepOverride() {
        try writeOwnershipMarker()
      }
      try writeState(state)
      if !alreadyDisabled {
        _ = try run("/usr/bin/pmset", ["-a", "disablesleep", "1"])
      }
    } catch {
      try restoreSession()
      throw error
    }
  }
}

private func setKeepDisplayOn(_ keepDisplayOn: Bool) throws {
  guard geteuid() == 0 else {
    throw HelperError.notRoot
  }
  try withLock {
    guard case .active(let state) = try reconcileSession() else {
      throw HelperError.inactiveSession
    }
    try writeState(
      State(
        durationSeconds: state.durationSeconds,
        deadline: state.deadline,
        batteryFloor: state.batteryFloor,
        keepDisplayOn: keepDisplayOn
      ))
  }
}

private func stop() throws {
  guard geteuid() == 0 else {
    throw HelperError.notRoot
  }
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
}

private func currentStatus() throws -> Status {
  try withLock {
    switch try reconcileSession() {
    case .inactive:
      return Status(
        active: false,
        batteryLevel: try batteryState().level,
        durationSeconds: nil,
        remainingSeconds: nil,
        keepDisplayOn: false
      )
    case .active(let state):
      let remaining = state.deadline.map {
        max(0, Int($0.timeIntervalSinceNow.rounded(.down)))
      }
      return Status(
        active: true,
        batteryLevel: try batteryState().level,
        durationSeconds: state.durationSeconds,
        remainingSeconds: remaining,
        keepDisplayOn: state.keepDisplayOn
      )
    case .externalOverride:
      throw HelperError.unownedSleepOverride
    case .recovered(let error):
      throw error
    }
  }
}

private func monitor() throws -> Never {
  guard geteuid() == 0 else {
    throw HelperError.notRoot
  }
  var displayAssertion: Process?
  while true {
    try withLock {
      do {
        guard case .active(let state) = try reconcileSession() else {
          if displayAssertion?.isRunning == true {
            displayAssertion?.terminate()
          }
          displayAssertion = nil
          return
        }
        if state.keepDisplayOn {
          if displayAssertion?.isRunning != true {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-d", "-w", String(getpid())]
            try process.run()
            displayAssertion = process
          }
        } else {
          if displayAssertion?.isRunning == true {
            displayAssertion?.terminate()
          }
          displayAssertion = nil
        }
        let battery = try batteryState()
        let batteryReachedFloor = battery.isOnBattery && battery.level <= state.batteryFloor
        let deadlineReached = state.deadline.map { Date() >= $0 } ?? false
        let shouldStop = deadlineReached || batteryReachedFloor
        if shouldStop {
          try restoreSession()
          if displayAssertion?.isRunning == true {
            displayAssertion?.terminate()
          }
          displayAssertion = nil
        }
      } catch {
        try restoreSession()
        if displayAssertion?.isRunning == true {
          displayAssertion?.terminate()
        }
        displayAssertion = nil
        throw error
      }
    }
    sleep(10)
  }
}

private func execute() throws {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else {
    throw HelperError.invalidArguments
  }

  switch command {
  case "start":
    guard
      arguments.count == 4,
      let duration = Int(arguments[1]),
      let batteryFloor = Int(arguments[2]),
      let keepDisplayOn = Int(arguments[3]),
      keepDisplayOn == 0 || keepDisplayOn == 1
    else {
      throw HelperError.invalidArguments
    }
    try start(
      duration: duration,
      batteryFloor: batteryFloor,
      keepDisplayOn: keepDisplayOn == 1
    )
  case "display":
    guard
      arguments.count == 2,
      let keepDisplayOn = Int(arguments[1]),
      keepDisplayOn == 0 || keepDisplayOn == 1
    else {
      throw HelperError.invalidArguments
    }
    try setKeepDisplayOn(keepDisplayOn == 1)
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
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(EXIT_FAILURE)
}
