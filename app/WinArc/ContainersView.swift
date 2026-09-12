import SwiftUI

struct ContainersView: View {
    @EnvironmentObject private var store: WinArcStore
    let onCreateContainer: () -> Void
    let onImportGame: (ContainerProfile) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("容器")
                            .font(.system(size: 32, weight: .bold))
                        Text("每个容器拥有独立的 Windows 环境和默认图形设置。")
                            .foregroundStyle(WinArcTheme.secondary)
                    }
                    Spacer()
                    Button(action: onCreateContainer) {
                        Label("新建容器", systemImage: "plus")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 10)
                            .background(.white)
                            .foregroundStyle(.black)
                            .clipShape(Capsule())
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18)], spacing: 18) {
                    ForEach(store.containers) { container in
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Image(systemName: "shippingbox.fill")
                                    .font(.system(size: 26))
                                Spacer()
                                if store.selectedContainerID == container.id {
                                    Text("当前")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(Color.white.opacity(0.11), in: Capsule())
                                }
                            }

                            Text(container.name)
                                .font(.system(size: 21, weight: .bold))
                            Text("\(container.windowsVersion) · \(container.defaultBackend.rawValue)")
                                .foregroundStyle(WinArcTheme.secondary)

                            HStack {
                                Button("选择") { store.selectedContainerID = container.id }
                                    .buttonStyle(.bordered)
                                Button("导入游戏") { onImportGame(container) }
                                    .buttonStyle(.borderedProminent)
                                Spacer()
                                Button(role: .destructive) {
                                    store.deleteContainer(container)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                        .padding(20)
                        .winArcGlass()
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }
}
