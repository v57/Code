import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// Shown in a window without a project, laid out like Xcode's welcome
/// window: a close button instead of the title bar, the app's icon, name and
/// version, the actions as capsule buttons, and the recent projects in a
/// rounded list (click selects, double-click or Return opens). A folder can
/// also be dropped on the window. The list shows the recent folders, or the
/// projects the v57 apps share (added in Git and the others, through the
/// vault), live as they change.
struct WelcomeView: View {
  static let size = CGSize(width: 480, height: 660)

  enum Source: String, CaseIterable {
    case recent = "Recent"
    case projects = "Projects"
  }

  let open: (URL) -> Void
  @State private var isDropTargeted = false
  @State private var selection: URL?
  @AppStorage("WelcomeListSource") private var source = Source.recent
  @FocusState private var isListFocused: Bool
  private var recents: RecentProjects { AppState.shared.recents }
  private var vault: Vault { Vault.shared }

  /// The folders the list shows.
  private var folders: [URL] {
    switch source {
    case .recent:
      return recents.existing
    case .projects:
      return vault.localProjects.compactMap(\.localURL)
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.top, 76)
      actions
        .padding(.top, 22)
      Picker("Show", selection: $source) {
        ForEach(Source.allCases, id: \.self) { Text($0.rawValue) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .padding(.top, 18)
      recentList
        .padding(.top, 12)
        .padding(.horizontal, 60)
        .padding(.bottom, 40)
    }
    // The window is `size`; the list takes the height the title bar's
    // safe area leaves.
    .frame(width: Self.size.width)
    .frame(minHeight: 520, maxHeight: .infinity)
    .overlay(alignment: .topLeading) { closeButton.padding(20) }
    .background(Color(nsColor: .windowBackgroundColor))
    .ignoresSafeArea()
    .navigationTitle("Welcome to Code")
    .modifier(HiddenTitleBar())
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.accentColor, lineWidth: 3)
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first(where: \.isFileURL) else { return false }
      open(url)
      return true
    } isTargeted: { isDropTargeted = $0 }
    .onAppear {
      selection = folders.first
      isListFocused = true
    }
    .onChange(of: source) { selection = folders.first }
  }

  // MARK: - Parts

  private var closeButton: some View {
    Button {
      NSApp.keyWindow?.performClose(nil)
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.primary)
        .frame(width: 37, height: 37)
        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help("Close")
  }

  private var header: some View {
    VStack(spacing: 0) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 112, height: 112)
      Text("Code")
        .font(.system(size: 17, weight: .bold))
        .padding(.top, 14)
      Text("Version \(Self.version)")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.top, 3)
    }
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Button("Open…") { AppState.shared.chooseFolder() }
        .buttonStyle(CapsuleButtonStyle())
    }
  }

  private var recentList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        let folders = folders
        ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
          RecentRow(
            folder: folder, isSelected: selection == folder,
            showsSeparator: index < folders.count - 1 && selection != folder
              && selection != folders[index + 1]
          )
          .onTapGesture(count: 2) { open(folder) }
          .simultaneousGesture(TapGesture().onEnded { selection = folder })
          .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            if source == .recent {
              Button("Remove from Recents") { recents.remove(folder) }
            }
          }
        }
      }
      .padding(8)
    }
    .scrollIndicators(.never)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.035)))
    .overlay {
      if folders.isEmpty {
        Text(source == .recent ? "No Recent Projects" : "No Projects on This Mac")
          .foregroundStyle(.secondary)
      }
    }
    .focusable()
    .focused($isListFocused)
    .focusEffectDisabled()
    .onKeyPress(.upArrow) { moveSelection(by: -1) }
    .onKeyPress(.downArrow) { moveSelection(by: 1) }
    .onKeyPress(.return) {
      guard let selection else { return .ignored }
      open(selection)
      return .handled
    }
  }

  private func moveSelection(by offset: Int) -> KeyPress.Result {
    let folders = folders
    guard !folders.isEmpty else { return .ignored }
    let current = selection.flatMap { folders.firstIndex(of: $0) } ?? -offset
    selection = folders[min(max(current + offset, 0), folders.count - 1)]
    return .handled
  }

  private static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }
}

/// One recent project: its icon, name and path.
private struct RecentRow: View {
  let folder: URL
  let isSelected: Bool
  let showsSeparator: Bool

  var body: some View {
    HStack(spacing: 14) {
      Image(nsImage: Self.icon(for: folder))
        .resizable()
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 3) {
        Text(folder.lastPathComponent)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(isSelected ? .white : .primary)
        Text(folder.abbreviatedPath)
          .font(.system(size: 11))
          .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
      }
      .lineLimit(1)
      .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .frame(height: 46)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .selectedContentBackgroundColor))
      }
    }
    .overlay(alignment: .bottom) {
      if showsSeparator {
        Rectangle()
          .fill(Color.primary.opacity(0.1))
          .frame(height: 1)
          .padding(.leading, 62)
          .padding(.trailing, 12)
      }
    }
    .contentShape(Rectangle())
  }

  /// The project's Xcode project or workspace icon when it has one, a box
  /// for a Swift package, else its folder's.
  @MainActor private static var icons: [URL: NSImage] = [:]

  @MainActor static func icon(for folder: URL) -> NSImage {
    if let icon = icons[folder] { return icon }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let project =
      names.first { $0.hasSuffix(".xcworkspace") } ?? names.first { $0.hasSuffix(".xcodeproj") }
    let icon: NSImage
    if let project {
      icon = NSWorkspace.shared.icon(forFile: folder.appendingPathComponent(project).path)
    } else if names.contains("Package.swift") {
      // A box, like Xcode's package icon.
      icon = NSWorkspace.shared.icon(for: UTType("com.apple.installer-package-archive") ?? .package)
    } else {
      icon = NSWorkspace.shared.icon(forFile: folder.path)
    }
    icons[folder] = icon
    return icon
  }
}

/// Xcode's welcome buttons: a light gray capsule.
private struct CapsuleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13))
      .frame(minWidth: 82)
      .padding(.horizontal, 24)
      .frame(height: 36)
      .background(
        Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
      .contentShape(Capsule())
  }
}

/// No title or title bar background: the content runs to the window's top
/// edge (the window hides its buttons, see `WindowReader`).
private struct HiddenTitleBar: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    } else {
      content
    }
  }
}
