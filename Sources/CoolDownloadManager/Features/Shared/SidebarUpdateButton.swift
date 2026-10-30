import SwiftUI

struct SidebarUpdateButton: View {
    @ObservedObject var controller: AppUpdateController
    @State private var showsDetails = false

    var body: some View {
        if let title = controller.state.title {
            HStack {
                Spacer(minLength: 0)
                Button {
                    if controller.state.isWorking { showsDetails = true }
                    else { controller.performAction() }
                } label: {
                    HStack(spacing: 7) {
                        if controller.state.isWorking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: controller.state.systemImage)
                        }
                        Text(title).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(controller.helpText)
                .accessibilityLabel(title)
                .accessibilityIdentifier("app-update-action")
                .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(controller.state.title ?? "应用更新").font(.headline)
                        Text(controller.helpText).font(.callout).foregroundStyle(.secondary)
                        if let progress = controller.progress {
                            ProgressView(value: progress)
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                        }
                        if controller.canCancel {
                            Button("取消下载") { controller.cancel(); showsDetails = false }
                        }
                    }
                    .padding(18)
                    .frame(width: 250)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject var controller: AppUpdateController
    let showMain: () -> Void

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(controller.menuTitle) {
                showMain()
                controller.performAction()
            }
            .disabled(controller.state.isWorking)
        }
    }
}
