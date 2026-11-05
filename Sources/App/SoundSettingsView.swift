import SwiftUI
import VoiceAudio

struct SoundSettingsView: View {
    @ObservedObject private var manager: SoundManager = .shared
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable sounds", isOn: Binding(
                get: { manager.isEnabled },
                set: { manager.setEnabled($0) }
            ))

            Divider()

            VStack(spacing: 10) {
                ForEach(SoundEvent.allCases, id: \.self) { event in
                    eventRow(event)
                }
            }
            .disabled(!manager.isEnabled)

            HStack {
                Spacer()
                Button("Defaults") { manager.resetToDefaults() }
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func eventRow(_ event: SoundEvent) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { manager.eventEnabled[event] ?? true },
                set: { manager.setEventEnabled($0, for: event) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Text(event.displayName)
                .frame(width: 180, alignment: .leading)

            Picker(
                selection: Binding<SystemSound?>(
                    get: { manager.assignments[event] ?? nil },
                    set: { manager.setSound($0, for: event) }
                ),
                label: EmptyView()
            ) {
                ForEach(manager.library) { sound in
                    Text(sound.displayName).tag(SystemSound?.some(sound))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(manager.eventEnabled[event] != true)

            Button {
                if let sound = manager.assignments[event] ?? nil {
                    manager.preview(sound)
                }
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(manager.eventEnabled[event] != true || (manager.assignments[event] ?? nil) == nil)
        }
    }
}
