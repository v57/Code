import CodeActions
import ComponentKit
import SwiftUI

/// A run preset as a small card (the Code boards' `.ck-preset`): the action's glyph, its name with the usual part
/// ("Run Git") in the label colour and the rest ("on v57 iPhone") secondary, and the vault's glyph for one kept there.
/// Running, it takes the accent's tint and its glyph the live ring; one that can't run now is dimmed. The caller adds
/// the action, the tooltip and the menu.
///
/// ```swift
/// RunPresetCard(preset, inVault: true, status: isRunning ? .working(progress: 0.4) : .idle)
/// ```
public struct RunPresetCard: View {
  let preset: RunPreset
  let inVault: Bool
  let status: WorkStatus
  let isAvailable: Bool
  @State private var isHovered = false

  public init(_ preset: RunPreset, inVault: Bool = false, status: WorkStatus = .idle, isAvailable: Bool = true) {
    self.preset = preset
    self.inVault = inVault
    self.status = status
    self.isAvailable = isAvailable
  }

  /// The vault's glyph, as the Vault app draws it.
  public static let vaultSymbol = "lock.rectangle.stack"

  public var body: some View {
    let split = Self.split(preset)
    HStack(spacing: 6) {
      if status.isWorking {
        LiveIcon(systemImage: Self.symbol(preset.action), status: status, size: 16, shape: .circle)
          .padding(.leading, -3)
      } else {
        Image(systemName: Self.symbol(preset.action))
          .font(.system(size: 8, weight: .semibold))
          .frame(width: 10)
          .foregroundStyle(isAvailable ? .kitSecondary : .kitTertiary)
      }
      let lead = Text(split.lead).foregroundStyle(isAvailable ? .kitLabel : .kitTertiary)
      let rest = Text(split.rest.isEmpty ? "" : " " + split.rest).foregroundStyle(isAvailable ? .kitSecondary : .kitTertiary)
      Text("\(lead)\(rest)")
        .kitFont(.callout)
        .lineLimit(1)
        .fixedSize()
      if inVault {
        Image(systemName: Self.vaultSymbol)
          .font(.system(size: 9))
          .foregroundStyle(.kitTertiary)
          .padding(.trailing, -2)
          .accessibilityLabel("In the Vault")
      }
    }
    .padding(.leading, 8)
    .padding(.trailing, 10)
    .frame(height: 26)
    .background {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.clear).kitSurface(.card, cornerRadius: 9)
          .opacity(isHovered ? 1 : 0.85)
        if status.isWorking {
          RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Hue.accent.soft(0.16))
        }
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(preset.name + (inVault ? ", in the Vault" : ""))
  }

  /// The action's glyph: ▶ for Run, the test tube, the hammer.
  public static func symbol(_ kind: ActionKind) -> String {
    switch kind {
    case .run: return "play.fill"
    case .test: return "testtube.2"
    default: return kind.symbolName
    }
  }

  /// "Run Git" and "on v57 iPhone": the action and the scheme lead when the name starts with them; a name of the
  /// user's own is all lead.
  public static func split(_ preset: RunPreset) -> (lead: String, rest: String) {
    let lead = "\(preset.action.title) \(preset.scheme)"
    guard !preset.scheme.isEmpty, preset.name.hasPrefix(lead + " ") else { return (preset.name, "") }
    return (lead, String(preset.name.dropFirst(lead.count + 1)))
  }
}

/// The bar's last card when the presets don't fit: "N more" with a chevron; the caller opens the rest as a menu.
public struct RunPresetMoreCard: View {
  let count: Int
  @State private var isHovered = false

  public init(count: Int) { self.count = count }

  public var body: some View {
    HStack(spacing: 5) {
      Text("\(count) more").kitFont(.callout)
      Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
    }
    .foregroundStyle(.kitSecondary)
    .padding(.leading, 10)
    .padding(.trailing, 8)
    .frame(height: 26)
    .background {
      RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.clear).kitSurface(.card, cornerRadius: 9)
        .opacity(isHovered ? 1 : 0.85)
    }
    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .onHover { isHovered = $0 }
    .fixedSize()
  }
}
