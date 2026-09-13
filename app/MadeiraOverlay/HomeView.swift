import SwiftUI

extension Notification.Name {
    static let winArcLaunchDX11Cube =
        Notification.Name("WinArcLaunchDX11Cube")
}

private enum WinArcRuntimeLaunchTarget {
    case desktop
    case dx11Cube

    var notification: Notification.Name {
        switch self {
        case .desktop:
            return .winArcLaunchDesktop
        case .dx11Cube:
            return .winArcLaunchDX11Cube
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: WinArcStore
    let onCreateContainer: () -> Void
    let onImportGame: () -> Void

    @StateObject private var jit = WinArcJITManager.shared
    @StateObject private var runtime = WinArcRuntimeTuning.shared

    @State private var showMadeiraRuntime = false
    @State private var showJITSettings = false
    @State private var showLaunchError = false
    @State private var launchTarget: WinArcRuntimeLaunchTarget = .desktop

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                jitCard
                runtimeCard
                dx11Card
                desktopCard
                libraryContent
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
        .onAppear {
            jit.runQuickCheckIfNeeded()
        }
        .sheet(isPresented: $showJITSettings) {
            JITSettingsView()
        }
        .alert(
            "JIT 未通过检测",
            isPresented: $showLaunchError
        ) {
            Button("确定", role: .cancel) {}
            Button("JIT 设置") {
                showJITSettings = true
            }
        } message: {
            Text(jit.lastMessage)
        }
        .fullScreenCover(isPresented: $showMadeiraRuntime) {
            ZStack(alignment: .topLeading) {
                MadeiraLegacyContentView()
                    .onAppear {
                        runtime.applyCompatibilityBaseline()
                        jit.prepareMadeiraStockRuntime()

                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 0.35
                        ) {
                            NotificationCenter.default.post(
                                name: launchTarget.notification,
                                object: nil
                            )
                        }
                    }

                Button {
                    showMadeiraRuntime = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                .padding(.top, 8)
                .zIndex(100)
            }
            .background(Color.black)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.18, blue: 0.36),
                    Color(red: 0.08, green: 0.08, blue: 0.13)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 13) {
                Text("Windows games.\nYour way.")
                    .font(
                        .system(
                            size: 40,
                            weight: .bold,
                            design: .rounded
                        )
                    )

                Text(
                    store.containers.isEmpty
                    ? "先创建一个容器，然后把 Windows 游戏导入 WinArc。"
                    : "从容器导入游戏，然后在游戏库中单独管理每款游戏。"
                )
                .foregroundStyle(.white.opacity(0.66))

                Button(
                    action:
                        store.containers.isEmpty
                        ? onCreateContainer
                        : onImportGame
                ) {
                    Label(
                        store.containers.isEmpty
                        ? "创建容器"
                        : "导入游戏",
                        systemImage:
                            store.containers.isEmpty
                            ? "plus"
                            : "square.and.arrow.down"
                    )
                    .fontWeight(.semibold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.white)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                }
                .padding(.top, 3)
            }
            .padding(28)
        }
        .frame(height: 285)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 28,
                style: .continuous
            )
        )
    }

    private var jitCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(statusColor)
                    Text("JIT")
                        .font(.system(size: 18, weight: .semibold))
                }

                Spacer()

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(jit.statusTitle)
                        .font(.caption.weight(.semibold))
                }
            }

            Text(jit.lastMessage)
                .font(.footnote)
                .foregroundStyle(WinArcTheme.secondary)

            HStack(spacing: 18) {
                jitMetric(
                    "Debugger",
                    jit.debuggerAttached ? "OK" : "—"
                )
                jitMetric("Runtime", "Madeira Stock")
                jitMetric(
                    "Memory",
                    "\(jit.physicalFootprintMB)MB"
                )

                Spacer()

                Button("重新检测") {
                    jit.runQuickCheck()
                }
                .buttonStyle(.bordered)

                Button("详细信息") {
                    showJITSettings = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .winArcGlass()
    }

    private var runtimeCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 4) {
                Text("Runtime 路线")
                    .font(.headline)

                Text(
                    "当前：Madeira 原生 DXMT · 下一阶段：D3DMetal · 随后：Wine 轻量化"
                )
                .font(.footnote)
                .foregroundStyle(WinArcTheme.secondary)
            }

            Spacer()
        }
        .padding(18)
        .winArcGlass()
    }

    private var dx11Card: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
                .fill(Color.green.opacity(0.16))

                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text("Madeira 原生 DX11 验证")
                    .font(.system(size: 17, weight: .semibold))

                Text("FEX → Wine → DXMT → Metal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WinArcTheme.secondary)

                Text(
                    "不改 JIT、不改 Wine、不改 FEX；直接调用 Madeira 已有 cube-x64.exe 路径。"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Button(
                jit.isPreparingRuntime
                ? "启动检查中…"
                : "运行原生 DX11"
            ) {
                launchTarget = .dx11Cube

                LogStore.shared.log(
                    "[WinArc DX11] request Madeira stock cube-x64.exe path"
                )

                jit.validateForRuntimeLaunch { passed in
                    if passed {
                        showMadeiraRuntime = true
                    } else {
                        showLaunchError = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                jit.isPreparingRuntime ||
                jit.isRunningQuickCheck
            )
        }
        .padding(18)
        .winArcGlass()
    }

    private var desktopCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
                .fill(Color.blue.opacity(0.16))

                Image(systemName: "desktopcomputer")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text("Windows 桌面基线")
                    .font(.system(size: 17, weight: .semibold))

                Text("Madeira 原生 JIT → FEX → Wine Desktop")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WinArcTheme.secondary)

                Text("用于确认 Runtime 基线没有被 WinArc 改写。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Button(
                jit.isPreparingRuntime
                ? "启动检查中…"
                : "启动桌面"
            ) {
                launchTarget = .desktop

                jit.validateForRuntimeLaunch { passed in
                    if passed {
                        showMadeiraRuntime = true
                    } else {
                        showLaunchError = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                jit.isPreparingRuntime ||
                jit.isRunningQuickCheck
            )
        }
        .padding(18)
        .winArcGlass()
    }

    @ViewBuilder
    private var libraryContent: some View {
        if store.games.isEmpty {
            HStack(spacing: 16) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 28))

                VStack(alignment: .leading, spacing: 4) {
                    Text("游戏库还没有内容")
                        .font(.headline)
                    Text("导入第一个游戏后，“库”会自动出现在顶部。")
                        .foregroundStyle(WinArcTheme.secondary)
                }

                Spacer()
            }
            .padding(20)
            .winArcGlass()
        } else {
            Text("最近")
                .font(.system(size: 22, weight: .bold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(store.games.prefix(6)) { game in
                        GameCard(game: game)
                            .frame(width: 245)
                    }
                }
            }
        }
    }

    private func jitMetric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(WinArcTheme.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
        }
    }

    private var statusColor: Color {
        switch jit.status {
        case .checking: return .gray
        case .ready: return .green
        case .needsValidation: return .yellow
        case .unavailable: return .red
        }
    }
}
