import SwiftUI

struct GameSettingsSheet: View {
    @EnvironmentObject private var store: WinArcStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GameEntry
    @State private var graphicsStatus = "检测中…"

    init(game: GameEntry) {
        _draft = State(initialValue: game)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("游戏") {
                    LabeledContent("名称", value: draft.name)
                    LabeledContent("程序", value: draft.executableName)
                    LabeledContent("容器", value: store.containerName(for: draft.containerID))
                }

                Section("图形") {
                    Picker("图形后端", selection: $draft.settings.backend) {
                        ForEach(GraphicsBackend.allCases) { backend in
                            Text(backend.rawValue).tag(backend)
                        }
                    }

                    LabeledContent("后端状态") {
                        Text(graphicsStatus)
                            .foregroundStyle(
                                graphicsStatus.contains("已就绪") ||
                                graphicsStatus.contains("可加载")
                                    ? .green
                                    : .secondary
                            )
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("分辨率比例", selection: $draft.settings.resolutionScale) {
                        ForEach(ResolutionScale.allCases) { scale in
                            Text(scale.rawValue).tag(scale)
                        }
                    }

                    Picker("帧率上限", selection: $draft.settings.fpsLimit) {
                        Text("30 FPS").tag(30)
                        Text("45 FPS").tag(45)
                        Text("60 FPS").tag(60)
                        Text("120 FPS").tag(120)
                    }

                    Toggle("Metal HUD", isOn: $draft.settings.useMetalHud)
                }

                Section("高级") {
                    TextField(
                        "环境变量，例如 KEY=VALUE",
                        text: $draft.settings.environmentVariables,
                        axis: .vertical
                    )
                }

                Section {
                    Text("这些设置只作用于当前游戏，不会修改同一容器里的其他游戏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("此游戏设置")
            .onAppear(perform: refreshGraphicsStatus)
            .onChange(of: draft.settings.backend) { _, _ in
                refreshGraphicsStatus()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateGame(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func refreshGraphicsStatus() {
        let backend = draft.settings.backend.rawValue
        let bundlePath = Bundle.main.bundlePath

        graphicsStatus = backend.withCString { backendCString in
            bundlePath.withCString { bundleCString in
                guard let result = winarc_graphics_backend_status_text(
                    backendCString,
                    bundleCString
                ) else {
                    return "状态未知"
                }
                return String(cString: result)
            }
        }
    }
}
