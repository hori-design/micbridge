import KeyboardShortcuts
import SwiftUI

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section("グローバルショートカット") {
                LabeledContent("ミュート トグル") {
                    KeyboardShortcuts.Recorder(for: .toggleMute)
                }
            }
            Text("ブリッジ有効時のみ動作します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
