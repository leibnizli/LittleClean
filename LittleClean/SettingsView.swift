import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject private var helper = PrivilegedHelperManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Use Touch ID for protected files",
                    isOn: Binding(
                        get: { helper.isOn },
                        set: { newValue in
                            Task { await helper.setOn(newValue) }
                        }
                    )
                )
                .disabled(helper.isBusy)

                if helper.requiresApproval {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(
                                "Allow LittleClean in System Settings → General → Login Items & Extensions."
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.callout)
                        .foregroundStyle(.orange)

                        Button("Open Login Items Settings") {
                            helper.openLoginItemsSettings()
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text(helper.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorMessage = helper.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text(
                    "Registers a background helper so LittleClean can use Touch ID instead of an administrator password. macOS may ask you to allow LittleClean in Login Items & Extensions."
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 280)
        .onAppear {
            helper.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            helper.refresh()
        }
    }
}
