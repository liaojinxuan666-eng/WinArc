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

                Text("WinArc 0.0.1 · Madeira stock runtime baseline")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .onAppear {
            jit.runQuickCheckIfNeeded()
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

                Text("当前阶段")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("D3DMetal")
                        .fontWeight(.semibold)

                    Spacer()

                    Text("下一阶段")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Text(d3dMetalStatus)
                    .font(.footnote)
                    .foregroundStyle(WinArcTheme.secondary)

                Text(
                    "D3DMetal 计划保留。先让 Madeira 原生 DXMT/DX11 基线稳定，再接入运行链，不提前替换当前图形地基。"
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

                Text("计划保留")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
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

            Text(runtime.wineProfile.detail)
                .font(.footnote)
                .foregroundStyle(WinArcTheme.secondary)

            Text(
                "当前 DX11 基线阶段固定使用兼容环境，不向 Wine 注入轻量化变量。等 DXMT 回归稳定后，再按“平衡 → 轻量”的顺序启用。"
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
                "Madeira 原生 Runtime · " +
                "\(jit.physicalFootprintMB)MB footprint"
            )
            .font(.footnote)
            .foregroundStyle(WinArcTheme.secondary)

            HStack(spacing: 10) {
                Button("JIT 状态") {
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

                Text("地基")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }

            Text(
                "Madeira 继续负责 JIT、FEX、Wine、DXMT 和实际启动链；WinArc 只做产品 UI、容器、游戏库、配置与后续增强。"
            )
            .font(.footnote)
            .foregroundStyle(WinArcTheme.secondary)

            Button("打开 Madeira 运行控制") {
                showMadeiraRuntime = true
            }
            .buttonStyle(.bordered)
        }
        .padding(22)
        .winArcGlass()
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
            return "平衡"
        case .lite:
            return "轻量"
        }
    }

    var detail: String {
        switch self {
        case .compatibility:
            return "保持 Madeira/Wine 原始环境，当前 DX11 基线固定使用。"
        case .balanced:
            return "计划：减少日志和 winemenubuilder 后台开销。"
        case .lite:
            return "计划：进一步减少 Gecko/Mono 自动入口与非必要后台开销。"
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
        ) ?? .compatibility
    }

    func applyCompatibilityBaseline() {
        unsetenv("WINEDEBUG")
        unsetenv("WINEDLLOVERRIDES")
        unsetenv("WINARC_WINE_LITE")

        LogStore.shared.log(
            "[WinArc Wine] compatibility baseline active; no lightweight override"
        )
    }

    // Compatibility alias for older WinArc call sites. During the current
    // DX11 baseline stage this always means "restore stock Wine environment".
    func applyEnvironment() {
        applyCompatibilityBaseline()
    }

    func environmentValue(_ name: String) -> String {
        guard let value = getenv(name) else {
            return "<unset>"
        }
        return String(cString: value)
    }

    // Reserved for the later Wine-lightweighting stage.
    // Do not call this from the current DX11 baseline launch path.
    func applyPlannedProfile() {
        applyCompatibilityBaseline()

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
            "[WinArc Wine] planned profile applied manually: \(wineProfile.rawValue)"
        )
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
