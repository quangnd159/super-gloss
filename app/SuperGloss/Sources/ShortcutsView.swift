import SwiftUI

/// Help → Keyboard Shortcuts (⌘/): every key Super Gloss responds to, grouped by task.
struct ShortcutsView: View {
    @AppStorage("hotKey") private var hotKeyRaw = HotKeyPreset.optionSpace.rawValue

    var body: some View {
        Form {
            Section("Look up") {
                ShortcutRow("Look up the word", keys: ["Return"])
                ShortcutRow("Accept the suggested ending", keys: ["Tab"])
                ShortcutRow("Previous or next related word", keys: ["⌥", "↑"], or: ["⌥", "↓"])
                ShortcutRow("Go to the search line", keys: ["⌘", "L"])
                ShortcutRow("Clear the search, or hide when empty", keys: ["Esc"])
                ShortcutRow("Look up a word in an entry", gesture: "Double-click")
            }
            Section("Find in the entries") {
                ShortcutRow("Find", keys: ["⌘", "F"])
                ShortcutRow("Next match", keys: ["Return"], or: ["⌘", "G"])
                ShortcutRow("Previous match", keys: ["⇧", "Return"], or: ["⇧", "⌘", "G"])
                ShortcutRow("Done", keys: ["Esc"])
            }
            Section("Read") {
                ShortcutRow("Next dictionary", keys: ["↓"], or: ["⌥", "⌘", "↓"])
                ShortcutRow("Previous dictionary", keys: ["↑"], or: ["⌥", "⌘", "↑"])
                ShortcutRow("Go to a dictionary", keys: ["⌘", "J"])
                ShortcutRow("Scroll a page", keys: ["Page Down"], or: ["Page Up"])
                ShortcutRow("Pronounce", keys: ["⌘", "P"])
                ShortcutRow("Save the word, or remove it", keys: ["⌘", "D"])
                ShortcutRow("Hide or show a dictionary's entry", gesture: "Click its name")
            }
            Section("Go") {
                ShortcutRow("Back", keys: ["⌘", "["])
                ShortcutRow("Forward", keys: ["⌘", "]"])
                ShortcutRow("Surprise me", keys: ["⌘", "R"])
                ShortcutRow("Step through saved and recent words on the home page", keys: ["↓"], or: ["↑"])
            }
            Section("Text size") {
                ShortcutRow("Bigger", keys: ["⌘", "+"])
                ShortcutRow("Smaller", keys: ["⌘", "−"])
                ShortcutRow("Actual size", keys: ["⌘", "0"])
            }
            Section {
                if let preset = HotKeyPreset(rawValue: hotKeyRaw), preset != .none {
                    ShortcutRow("Show or hide Super Gloss", keys: preset.keys)
                } else {
                    ShortcutRow("Show or hide Super Gloss", gesture: "Off — choose one in Settings")
                }
                ShortcutRow("Look up selected text", gesture: "Services → Look Up in Super Gloss")
            } header: {
                Text("From any app")
            }
            Section("Super Gloss") {
                ShortcutRow("Add dictionaries", keys: ["⌘", "O"])
                ShortcutRow("Settings", keys: ["⌘", ","])
                ShortcutRow("Keyboard shortcuts", keys: ["⌘", "/"])
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 420, maxHeight: .infinity)
    }
}

private struct ShortcutRow: View {
    let title: String
    var keys: [String] = []
    var alternative: [String] = []
    var gesture: String?

    init(_ title: String, keys: [String], or alternative: [String] = []) {
        self.title = title
        self.keys = keys
        self.alternative = alternative
    }

    init(_ title: String, gesture: String) {
        self.title = title
        self.gesture = gesture
    }

    var body: some View {
        LabeledContent(title) {
            if let gesture {
                Text(gesture).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    KeyCombo(keys: keys)
                    if !alternative.isEmpty {
                        Text("or").font(.caption).foregroundStyle(.tertiary)
                        KeyCombo(keys: alternative)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct KeyCombo: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                KeyCap(label: k)
            }
        }
    }
}

private struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: label.count > 1 ? 11 : 12.5, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, label.count > 1 ? 7 : 0)
            .frame(minWidth: 23, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }
}

extension HotKeyPreset {
    /// Individual keys for display, e.g. ⌃⌥⌘ D → ["⌃", "⌥", "⌘", "D"].
    var keys: [String] {
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [label] }
        return parts[0].map(String.init) + [parts[1]]
    }
}
