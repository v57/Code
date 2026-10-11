import Foundation

/// Where Run runs: this Mac, an iOS simulator or device, an Android device
/// or emulator (Xcode's run destinations).
public struct RunDestination: Identifiable, Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case mac
    case iOSSimulator
    case iOSDevice
    case androidDevice
    /// A running Android emulator (an adb device).
    case androidEmulator
    /// An Android virtual device that isn't running; Run starts it.
    case androidVirtualDevice
  }

  /// "mac", a simulator or device UDID, an adb serial, or "avd:<name>".
  public var id: String
  public var name: String
  public var kind: Kind
  /// The OS version or model, shown after the name.
  public var detail: String?
  /// False for a device that is paired but not reachable now.
  public var isAvailable: Bool

  public init(id: String, name: String, kind: Kind, detail: String? = nil, isAvailable: Bool = true) {
    self.id = id
    self.name = name
    self.kind = kind
    self.detail = detail
    self.isAvailable = isAvailable
  }

  public static let mac = RunDestination(id: "mac", name: "My Mac", kind: .mac)

  public var platform: Platform {
    switch kind {
    case .mac: return .mac
    case .iOSSimulator, .iOSDevice: return .iOS
    case .androidDevice, .androidEmulator, .androidVirtualDevice: return .android
    }
  }

  public var symbolName: String {
    switch kind {
    case .mac: return "laptopcomputer"
    case .iOSSimulator: return name.contains("iPad") ? "ipad" : "iphone"
    case .iOSDevice: return name.contains("iPad") ? "ipad" : "iphone.gen3"
    case .androidDevice: return "smartphone"
    case .androidEmulator, .androidVirtualDevice: return "candybarphone"
    }
  }

  /// The menu section this destination is listed under.
  public var section: String {
    switch kind {
    case .mac: return "My Mac"
    case .iOSDevice: return "iOS Devices"
    case .iOSSimulator: return "iOS Simulators"
    case .androidDevice: return "Android Devices"
    case .androidEmulator, .androidVirtualDevice: return "Android Emulators"
    }
  }
}

/// Lists run destinations: `simctl` simulators, `devicectl` devices, `adb`
/// devices and the Android SDK's virtual devices.
public enum DestinationProvider {
  /// The destinations for these platforms, in menu order.
  public static func load(platforms: Set<Platform>) async -> [RunDestination] {
    await Task.detached(priority: .userInitiated) {
      var destinations: [RunDestination] = []
      if platforms.contains(.mac) { destinations.append(.mac) }
      if platforms.contains(.iOS) {
        destinations += iOSDevices()
        destinations += simulators()
      }
      if platforms.contains(.android) {
        destinations += androidDevices()
      }
      return destinations
    }.value
  }

  // MARK: - Apple

  /// Available iOS simulators, newest runtime first.
  static func simulators() -> [RunDestination] {
    guard
      let json = SubprocessCapture.run(
        "/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], timeout: 20)
    else { return [] }
    return parseSimulators(json)
  }

  static func parseSimulators(_ json: String) -> [RunDestination] {
    struct List: Decodable {
      struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
      }
      let devices: [String: [Device]]
    }
    guard let data = json.data(using: .utf8), let list = try? JSONDecoder().decode(List.self, from: data)
    else { return [] }
    var result: [(version: [Int], destination: RunDestination)] = []
    for (runtime, devices) in list.devices {
      // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → iOS 27.0
      guard let name = runtime.split(separator: ".").last, name.hasPrefix("iOS-") else { continue }
      let version = name.dropFirst(4).split(separator: "-").compactMap { Int($0) }
      let detail = "iOS " + version.map(String.init).joined(separator: ".")
      for device in devices where device.isAvailable != false {
        let state = device.state == "Booted" ? " (Booted)" : ""
        result.append(
          (
            version,
            RunDestination(
              id: device.udid, name: device.name, kind: .iOSSimulator, detail: detail + state)
          ))
      }
    }
    return result.sorted {
      $0.version != $1.version
        ? $0.version.lexicographicallyPrecedes($1.version) == false
        : $0.destination.name < $1.destination.name
    }.map(\.destination)
  }

  /// Paired iPhones and iPads from `devicectl`.
  static func iOSDevices() -> [RunDestination] {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("code-devicectl-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: output) }
    guard
      SubprocessCapture.run(
        "/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", output.path],
        timeout: 20) != nil,
      let data = try? Data(contentsOf: output)
    else { return [] }
    return parseDevices(data)
  }

  static func parseDevices(_ data: Data) -> [RunDestination] {
    struct Payload: Decodable {
      struct Result: Decodable { let devices: [Device] }
      struct Device: Decodable {
        struct Hardware: Decodable {
          let udid: String?
          let platform: String?
          let marketingName: String?
          let reality: String?
        }
        struct Properties: Decodable {
          let name: String?
          let osVersionNumber: String?
        }
        struct Connection: Decodable {
          let pairingState: String?
          let tunnelState: String?
        }
        let identifier: String
        let hardwareProperties: Hardware?
        let deviceProperties: Properties?
        let connectionProperties: Connection?
      }
      let result: Result
    }
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
    return payload.result.devices.compactMap { device in
      let hardware = device.hardwareProperties
      guard hardware?.reality != "virtual", hardware?.platform == "iOS",
        device.connectionProperties?.pairingState == "paired"
      else { return nil }
      let available = device.connectionProperties?.tunnelState != "unavailable"
      let version = device.deviceProperties?.osVersionNumber.map { "iOS " + $0 }
      return RunDestination(
        id: hardware?.udid ?? device.identifier,
        name: device.deviceProperties?.name ?? hardware?.marketingName ?? "iPhone",
        kind: .iOSDevice, detail: available ? version : "Unavailable", isAvailable: available)
    }
  }

  // MARK: - Android

  /// Devices and emulators adb sees, then virtual devices that aren't running.
  static func androidDevices() -> [RunDestination] {
    let environment = ShellEnvironment.shared
    var destinations: [RunDestination] = []
    var runningAVDs = Set<String>()
    if let adb = environment.adb,
      let output = SubprocessCapture.run(
        adb, ["devices", "-l"], environment: environment.variables, timeout: 15)
    {
      for device in parseADBDevices(output) {
        var device = device
        if device.kind == .androidEmulator,
          let name = SubprocessCapture.run(
            adb, ["-s", device.id, "emu", "avd", "name"], environment: environment.variables,
            timeout: 5)?.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        {
          runningAVDs.insert(name)
          device.name = name.replacingOccurrences(of: "_", with: " ")
        }
        destinations.append(device)
      }
    }
    if let emulator = environment.androidEmulator,
      let output = SubprocessCapture.run(
        emulator, ["-list-avds"], environment: environment.variables, timeout: 15)
    {
      for name in output.split(separator: "\n").map(String.init)
      where !name.isEmpty && !name.hasPrefix("INFO") && !runningAVDs.contains(name) {
        destinations.append(
          RunDestination(
            id: "avd:" + name, name: name.replacingOccurrences(of: "_", with: " "),
            kind: .androidVirtualDevice, detail: "Not running"))
      }
    }
    return destinations
  }

  /// `adb devices -l`: "serial  device product:x model:Pixel_7 device:y …".
  static func parseADBDevices(_ output: String) -> [RunDestination] {
    output.split(separator: "\n").dropFirst().compactMap { line in
      let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard fields.count >= 2 else { return nil }
      let serial = fields[0]
      let state = fields[1]
      let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
      let isEmulator = serial.hasPrefix("emulator-")
      let name = (model ?? serial).replacingOccurrences(of: "_", with: " ")
      return RunDestination(
        id: serial, name: name, kind: isEmulator ? .androidEmulator : .androidDevice,
        detail: state == "device" ? (serial.contains(":") ? "Wi-Fi" : nil) : state,
        isAvailable: state == "device")
    }
  }
}
