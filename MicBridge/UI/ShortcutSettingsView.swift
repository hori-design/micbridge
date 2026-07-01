import KeyboardShortcuts
import SwiftUI

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section("グローバルショートカット") {
                LabeledContent("ミュート トグル") {
                    KeyboardShortcuts.Recorder(for: .toggleMute)
                }
                LabeledContent("モニター オン/オフ") {
                    KeyboardShortcuts.Recorder(for: .toggleMonitor)
                }
            }
            Text("ブリッジ有効時のみ動作します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
