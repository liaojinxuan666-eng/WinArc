import SwiftUI

extension Notification.Name {
    static let winArcLaunchDX11Cube =
        Notification.Name("WinArcLaunchDX11Cube")

    static let winArcLaunchARM64DX11 =
        Notification.Name("WinArcLaunchARM64DX11")
}

private enum WinArcRuntimeLaunchTarget {
    case desktop
    case dx11Cube
    case arm64DX11

    var notification: Notification.Name {
        switch self {
        case .desktop:
            return .winArcLaunchDesktop
        case .dx11Cube:
            return .winArcLaunchDX11Cube
        case .arm64DX11:
            return .winArcLaunchARM64DX11
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
            runtime.applyEnvironment()
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
                        runtime.applyEnvironment()

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
                jitMetric(
                    "Dual Map",
                    jit.dualMappingAvailable ? "OK" : "—"
                )
                jitMetric(
                    "Execute",
                    jit.executionValidated ? "OK" : "未测"
                )
                jitMetric(
                    "Pool",
                    "\(jit.effectivePoolMB)MB"
                )
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

            if jit.recoveredFromFailedLaunch {
                Label(
                    "检测到上一轮 JIT 启动中断，已自动应用回退策略。",
                    systemImage: "arrow.uturn.backward.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
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
                Text("Wine Runtime")
                    .font(.headline)

                Text(
                    "\(runtime.wineProfile.title) · " +
                    "DXMT 已接入 · D3DMetal Probe 已准备"
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
                Text("DX11 / DXMT 验证")
                    .font(.system(size: 17, weight: .semibold))

                Text("ARM64 A/B：Wine → DXMT → Metal；x64：FEX → Wine → DXMT → Metal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WinArcTheme.secondary)

                Text(
                    "先跑 Madeira 原生 ARM64 triangle，" +
                    "把 FEX/ARM64EC 与 DXMT/Metal 分开验证。"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Button(
                    jit.isPreparingRuntime
                    ? "JIT 预检中…"
                    : "ARM64 隔离测试"
                ) {
                    runtime.applyEnvironment()
                    launchTarget = .arm64DX11

                    LogStore.shared.log(
                        "[WinArc DX11 ARM64] request Madeira triangle test"
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

                Button("x64 / FEX 再测") {
                    runtime.applyEnvironment()
                    launchTarget = .dx11Cube

                    LogStore.shared.log(
                        "[WinArc DX11 x64] request cube-x64.exe / DXMT"
                    )

                    jit.validateForRuntimeLaunch { passed in
                        if passed {
                            showMadeiraRuntime = true
                        } else {
                            showLaunchError = true
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            .disabled(
                jit.isPreparingRuntime ||
                jit.isRunningFullTest ||
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
                Text("Windows 桌面测试")
                    .font(.system(size: 17, weight: .semibold))

                Text("WinArc JIT → Madeira Runtime → Wine Desktop")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WinArcTheme.secondary)

                Text(
                    "当前 Wine Profile：" +
                    runtime.wineProfile.title
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Button(
                jit.isPreparingRuntime
                ? "JIT 预检中…"
                : "启动桌面"
            ) {
                runtime.applyEnvironment()
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
                jit.isRunningFullTest ||
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
