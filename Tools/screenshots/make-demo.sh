#!/bin/zsh
# Makes the projects Code's screenshots (.dev/screenshots.json) open, so the pictures never show anyone's real work:
# Atlas (a Swift package under git, with an uncommitted change), plus Weather and Field Notes for the recent list.
# The folder's path shows in the app, hence a short one outside the repo.
# Usage: Tools/screenshots/make-demo.sh [folder]   (default /tmp/CodeDemo, as .dev/screenshots.json expects)
set -euo pipefail
demo=${1:-/tmp/CodeDemo}
rm -rf "$demo"
mkdir -p "$demo/Atlas/Sources/Atlas" "$demo/Atlas/Tests/AtlasTests" "$demo/Weather/Sources" "$demo/Field Notes"

cd "$demo/Atlas"
cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Atlas",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "Atlas", targets: ["Atlas"])],
  targets: [
    .target(name: "Atlas"),
    .testTarget(name: "AtlasTests", dependencies: ["Atlas"]),
  ]
)
SWIFT
cat > Sources/Atlas/Trip.swift <<'SWIFT'
import Foundation

/// A trip: where, when, and the stops along the way.
public struct Trip: Identifiable, Codable, Hashable, Sendable {
  public var id = UUID()
  public var name: String
  public var start: Date
  public var days: Int
  public var stops: [Stop] = []

  public init(name: String, start: Date, days: Int) {
    self.name = name
    self.start = start
    self.days = days
  }

  /// The stops of one day, in the order they were planned.
  public func stops(on day: Int) -> [Stop] {
    stops.filter { $0.day == day }
  }
}
SWIFT
cat > Sources/Atlas/Stop.swift <<'SWIFT'
import Foundation

public struct Stop: Identifiable, Codable, Hashable, Sendable {
  public var id = UUID()
  public var name: String
  public var day: Int
  public var notes: String?

  public init(name: String, day: Int, notes: String? = nil) {
    self.name = name
    self.day = day
    self.notes = notes
  }
}
SWIFT
cat > Sources/Atlas/TripStore.swift <<'SWIFT'
import Foundation
import Observation

/// Every trip, saved as JSON in a folder of the app's choosing.
@Observable
public final class TripStore {
  public private(set) var trips: [Trip] = []
  private let file: URL

  public init(folder: URL) {
    file = folder.appendingPathComponent("trips.json")
    trips = (try? JSONDecoder().decode([Trip].self, from: Data(contentsOf: file))) ?? []
  }

  /// Adds a trip and saves.
  @discardableResult
  public func create(named name: String, from start: Date, days: Int) throws -> Trip {
    let trip = Trip(name: name, start: start, days: days)
    trips.append(trip)
    try save()
    return trip
  }

  public func remove(_ trip: Trip) throws {
    trips.removeAll { $0.id == trip.id }
    try save()
  }

  private func save() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(trips).write(to: file, options: .atomic)
  }
}
SWIFT
cat > Tests/AtlasTests/TripStoreTests.swift <<'SWIFT'
import Foundation
import Testing
@testable import Atlas

@Test func createdTripsAreSaved() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let store = TripStore(folder: folder)
  try store.create(named: "Lisbon", from: .now, days: 4)
  #expect(TripStore(folder: folder).trips.map(\.name) == ["Lisbon"])
}
SWIFT
printf '# Atlas\n\nPlans trips: stops, bookings and the days between them.\n' > README.md
printf '.build/\n.swiftpm/\n' > .gitignore
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Maya Okafor" GIT_AUTHOR_EMAIL=maya@example.com
export GIT_COMMITTER_NAME="Maya Okafor" GIT_COMMITTER_EMAIL=maya@example.com
git init -q -b main && git add -A && git commit -q -m "Started Atlas"
# An uncommitted change, so the navigator shows one.
perl -0pi -e 's/  private func save/  public var isEmpty: Bool { trips.isEmpty }\n\n  private func save/' Sources/Atlas/TripStore.swift

printf 'print("Weather")\n' > "$demo/Weather/Sources/main.swift"
printf '# Field Notes\n' > "$demo/Field Notes/README.md"
echo "$demo"
