import SwiftUI
import Foundation
import Darwin

struct SettingsView: View {
    @StateObject private var jit = WinArcJITManager.shared
    @StateObject private var runtime = WinArcRuntimeTuning.shared

    @State private var showMadeiraRuntime = false
    @State private var showJITSettings = false
    @State private var showLogs = false

    @State private var dxmtStatus = "检测中…"
    @State private var d3dMetalStatus = "检测中…"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置")
                    .font(.system(size: 32, weight: .bold))

                VStack(alignment: .leading, spacing: 16) {
                    Label(
                        "横屏优先",
                        systemImage: "rectangle.landscape"
                    )
                    Divider()
                    Label(
                        "容器默认设置由“容器”页管理",
                        systemImage: "shippingbox"
                    )
                    Divider()
                    Label(
                        "游戏独立设置：在“库”长按游戏",
                        systemImage: "gamecontroller"
                    )
                }
                .padding(22)
                .winArcGlass()

                graphicsCard
                wineCard
                jitCard
                runtimeCard

                Text("WinArc 0.0.1 · Madeira base integration")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .onAppear {
            jit.runQuickCheckIfNeeded()
            runtime.applyEnvironment()
            refreshGraphics()
        }
        .sheet(isPresented: $showJITSettings) {
            JITSettingsView()
        }
        .sheet(isPresented: $showLogs) {
            MadeiraLogView()
        }
        .fullScreenCover(isPresented: $showMadeiraRuntime) {
            MadeiraLegacyContentView()
        }
    }

    private var graphicsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    "图形后端",
                    systemImage: "gpu"
                )
                .font(.headline)

                Spacer()

                Button("重新检测") {
                    refreshGraphics()
                }
                .buttonStyle(.bordered)
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DXMT")
                        .fontWeight(.semibold)
                    Text(dxmtStatus)
                        .font(.footnote)
                        .foregroundStyle(
                            dxmtStatus.contains("已就绪")
                            ? .green
                            : WinArcTheme.secondary
                        )
                }

                Spacer()

                Text("当前默认")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("D3DMetal")
                        .fontWeight(.semibold)

                    Spacer()

                    Text(
                        d3dMetalStatus.contains("可加载")
                        ? "Probe PASS"
                        : "实验"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        d3dMetalStatus.contains("可加载")
                        ? .green
                        : .orange
                    )
                }

                Text(d3dMetalStatus)
                    .font(.footnote)
                    .foregroundStyle(WinArcTheme.secondary)

                Text(
                    "WinArc 这里只探测已随 App 签名打包的 D3DMetal 组件；" +
                    "不会伪装成“已支持”。真正切换到 D3DMetal 要等运行链接通。"
                )
                .font(.caption)
                .foregroundStyle(.white.opacity(0.38))
            }
        }
        .padding(22)
        .winArcGlass()
    }

    private var wineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    "Wine 轻量化",
                    systemImage: "gauge.with.dots.needle.50percent"
                )
                .font(.headline)

                Spacer()

                Text(runtime.wineProfile.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Picker(
                "Wine Profile",
                selection: $runtime.wineProfile
            ) {
                ForEach(WinArcWineProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: runtime.wineProfile) { _, _ in
                runtime.applyEnvironment()
            }

            Text(runtime.wineProfile.detail)
                .font(.footnote)
                .foregroundStyle(WinArcTheme.secondary)

            VStack(alignment: .leading, spacing: 6) {
                runtimeRow("WINEDEBUG", runtime.environmentValue("WINEDEBUG"))
                runtimeRow(
                    "WINEDLLOVERRIDES",
                    runtime.environmentValue("WINEDLLOVERRIDES")
                )
            }

            Text(
                "默认使用“平衡”：先减少日志和 winemenubuilder 后台开销，" +
                "不碰 Wine 核心 DLL。真正删组件的 build-lite 等 DX11 回归测试稳定后再开。"
            )
            .font(.caption)
            .foregroundStyle(.white.opacity(0.38))
        }
        .padding(22)
        .winArcGlass()
    }

    private var jitCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    "JIT",
                    systemImage: "bolt.fill"
                )
                .font(.headline)

                Spacer()

                Text(jit.statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            Text(
                "\(jit.effectiveStrategy.title) · " +
                "\(jit.effectivePoolMB)MB · " +
                "\(jit.physicalFootprintMB)MB footprint"
            )
            .font(.footnote)
            .foregroundStyle(WinArcTheme.secondary)

            HStack(spacing: 10) {
                Button("JIT 设置") {
                    showJITSettings = true
                }
                .buttonStyle(.borderedProminent)

                Button("运行日志") {
                    showLogs = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(22)
        .winArcGlass()
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    "Madeira Runtime",
                    systemImage: "wrench.and.screwdriver.fill"
                )
                .font(.headline)

                Spacer()

                Text("调试入口")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WinArcTheme.secondary)
            }

            Text(
                "Madeira 原运行控制台暂时保留作为底层诊断入口；" +
                "普通启动逐步迁移到 WinArc 自己的 Runtime/JIT 管理。"
            )
            .font(.footnote)
            .foregroundStyle(WinArcTheme.secondary)

            Button("打开运行控制") {
                showMadeiraRuntime = true
            }
            .buttonStyle(.bordered)
        }
        .padding(22)
        .winArcGlass()
    }

    private func runtimeRow(
        _ name: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .top) {
            Text(name)
                .foregroundStyle(WinArcTheme.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    private func refreshGraphics() {
        dxmtStatus = WinArcGraphicsProbe.dxmtStatus()
        d3dMetalStatus = WinArcGraphicsProbe.d3dMetalStatus()
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

enum WinArcWineProfile: String, CaseIterable, Identifiable {
    case compatibility
    case balanced
    case lite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compatibility:
            return "兼容优先"
        case .balanced:
            return "平衡（推荐）"
        case .lite:
            return "轻量"
        }
    }

    var detail: String {
        switch self {
        case .compatibility:
            return "保持 Madeira/Wine 原始环境，适合排查兼容性。"
        case .balanced:
            return "关闭 Wine 调试噪声，并禁用 winemenubuilder。"
        case .lite:
            return "再禁用 Gecko/Mono 自动入口；资源更省，但少数启动器可能需要切回。"
        }
    }
}

@MainActor
final class WinArcRuntimeTuning: ObservableObject {
    static let shared = WinArcRuntimeTuning()

    @Published var wineProfile: WinArcWineProfile {
        didSet {
            UserDefaults.standard.set(
                wineProfile.rawValue,
                forKey: "WinArcRuntime.wineProfile"
            )
        }
    }

    private init() {
        wineProfile = WinArcWineProfile(
            rawValue: UserDefaults.standard.string(
                forKey: "WinArcRuntime.wineProfile"
            ) ?? ""
        ) ?? .balanced
    }

    func applyEnvironment() {
        unsetenv("WINEDEBUG")
        unsetenv("WINEDLLOVERRIDES")
        unsetenv("WINARC_WINE_LITE")

        switch wineProfile {
        case .compatibility:
            break

        case .balanced:
            setenv("WINEDEBUG", "-all", 1)
            setenv(
                "WINEDLLOVERRIDES",
                "winemenubuilder.exe=d",
                1
            )
            setenv("WINARC_WINE_LITE", "balanced", 1)

        case .lite:
            setenv("WINEDEBUG", "-all", 1)
            setenv(
                "WINEDLLOVERRIDES",
                "winemenubuilder.exe=d;mscoree,mshtml=",
                1
            )
            setenv("WINARC_WINE_LITE", "lite", 1)
        }

        LogStore.shared.log(
            "[WinArc Wine] profile=\(wineProfile.rawValue) " +
            "WINEDEBUG=\(environmentValue("WINEDEBUG")) " +
            "WINEDLLOVERRIDES=\(environmentValue("WINEDLLOVERRIDES"))"
        )
    }

    func environmentValue(_ name: String) -> String {
        guard let value = getenv(name) else {
            return "<unset>"
        }
        return String(cString: value)
    }
}

enum WinArcGraphicsProbe {
    static func dxmtStatus() -> String {
        let bundle = Bundle.main

        let d3d11 = bundle.url(
            forResource: "d3d11",
            withExtension: "dll",
            subdirectory: "arm64ec-windows"
        )

        let dxgi = bundle.url(
            forResource: "dxgi",
            withExtension: "dll",
            subdirectory: "arm64ec-windows"
        )

        if d3d11 != nil {
            if dxgi != nil {
                return "已就绪 · d3d11.dll + dxgi.dll"
            }
            return "已就绪 · d3d11.dll"
        }

        return "未找到 Madeira DXMT d3d11.dll"
    }

    static func d3dMetalStatus() -> String {
        let fm = FileManager.default

        for url in d3dMetalCandidates() {
            guard fm.fileExists(atPath: url.path) else {
                continue
            }

            guard let handle = dlopen(
                url.path,
                RTLD_NOW | RTLD_LOCAL
            ) else {
                let error = dlerror().map {
                    String(cString: $0)
                } ?? "unknown dlopen error"

                return "发现组件，但 iOS 加载失败：\(error)"
            }

            dlclose(handle)
            return "可加载 · \(url.lastPathComponent)"
        }

        return "未检测到已签名的 D3DMetal 组件"
    }

    private static func d3dMetalCandidates() -> [URL] {
        let root = Bundle.main.bundleURL
        var urls: [URL] = []

        if let privateFrameworks = Bundle.main.privateFrameworksURL {
            urls.append(
                privateFrameworks
                    .appendingPathComponent("D3DMetal.framework")
                    .appendingPathComponent("D3DMetal")
            )

            urls.append(
                privateFrameworks
                    .appendingPathComponent("D3DMetal.framework")
                    .appendingPathComponent("Versions/A/D3DMetal")
            )
        }

        urls.append(
            root
                .appendingPathComponent("D3DMetal.framework")
                .appendingPathComponent("D3DMetal")
        )

        urls.append(
            root
                .appendingPathComponent("D3DMetal.framework")
                .appendingPathComponent("Versions/A/D3DMetal")
        )

        urls.append(
            root.appendingPathComponent("D3DMetal.dylib")
        )

        urls.append(
            root.appendingPathComponent("libD3DMetal.dylib")
        )

        return urls
    }
}
