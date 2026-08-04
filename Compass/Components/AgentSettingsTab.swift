import SwiftUI

struct AgentSettingsTab: View {
    @ObservedObject var ui: UIStateManager

    var body: some View {
        Form {
            Section {
                Slider(value: $ui.cliTimeoutSeconds, in: 5...120, step: 1) {
                    Text("CLI initial wait")
                } minimumValueLabel: {
                    Text("5s")
                } maximumValueLabel: {
                    Text("120s")
                }

                Toggle("Memory", isOn: $ui.agentMemoryEnabled)

                Toggle("QA review", isOn: $ui.agentQAReviewEnabled)
            } header: {
                Text("Agent")
            } footer: {
                Text("Controls for how the agent executes tools and commands.")
            }
        }
        .formStyle(.grouped)
    }
}
