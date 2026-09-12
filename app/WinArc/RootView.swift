import SwiftUI
import UniformTypeIdentifiers

enum WinArcSection: String, CaseIterable, Identifiable {
    case home = "首页"
    case containers = "容器"
    case library = "库"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .containers: return "shippingbox.fill"
        case .library: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: WinArcStore
    @State private var section: WinArcSection = .home
    @State private var showCreateContainer = false
    @State private var showImporter = false
    @State private var importerContainerID: UUID?

    private var visibleSections: [WinArcSection] {
        var items: [WinArcSection] = [.home, .containers]
        if !store.games.isEmpty { items.append(.library) }
        items.append(.settings)
        return items
    }

    var body: some View {
        ZStack {
            WinArcTheme.background.ignoresSafeArea()

            LinearGradient(
                colors: [Color.blue.opacity(0.18), .clear, Color.purple.opacity(0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TopNavigationBar(sections: visibleSections, selection: $section)

                Group {
                    switch section {
                    case .home:
                        HomeView(
                            onCreateContainer: { showCreateContainer = true },
                            onImportGame: beginImport
                        )
                    case .containers:
                        ContainersView(
                            onCreateContainer: { showCreateContainer = true },
                            onImportGame: { container in
                                importerContainerID = container.id
                                showImporter = true
                            }
                        )
                    case .library:
                        LibraryView()
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showCreateContainer) {
            CreateContainerSheet()
                .presentationDetents([.medium])
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard
                case let .success(urls) = result,
                let url = urls.first,
                let id = importerContainerID ?? store.selectedContainerID
            else { return }

            store.addGame(url: url, to: id)
            section = .library
        }
        .onChange(of: store.games.count) { newCount in
            if newCount == 0 && section == .library { section = .home }
        }
    }

    private func beginImport() {
        guard !store.containers.isEmpty else {
            showCreateContainer = true
            return
        }
        importerContainerID = store.selectedContainerID ?? store.containers.first?.id
        showImporter = true
    }
}

private struct TopNavigationBar: View {
    let sections: [WinArcSection]
    @Binding var selection: WinArcSection

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill")
                Text("WinArc")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }

            Spacer(minLength: 26)

            ForEach(sections) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = item }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.icon)
                        Text(item.rawValue)
                    }
                    .font(.system(size: 15, weight: selection == item ? .semibold : .medium))
                    .foregroundStyle(selection == item ? .white : WinArcTheme.secondary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(selection == item ? Color.white.opacity(0.11) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 28)
        .frame(height: 68)
    }
}
