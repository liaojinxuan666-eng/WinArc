import SwiftUI

struct CreateContainerSheet: View {
    @EnvironmentObject private var store: WinArcStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var backend: GraphicsBackend = .dxmt
    @State private var windowsVersion = "Windows 10"

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("容器名称", text: $name)

                    Picker("Windows", selection: $windowsVersion) {
                        Text("Windows 10").tag("Windows 10")
                        Text("Windows 11").tag("Windows 11")
                    }

                    Picker("默认图形后端", selection: $backend) {
                        ForEach(GraphicsBackend.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                }

                Section {
                    Text("默认设置会应用到新导入的游戏。之后可在“库”里长按游戏单独覆盖。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建容器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        store.createContainer(name: name, windowsVersion: windowsVersion, backend: backend)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
