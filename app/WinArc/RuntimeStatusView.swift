import Foundation
import SwiftUI

struct RuntimeStatusView: View {
    @State private var linked = false
    @State private var abi: UInt32 = 0

    @State private var serverState: Int32 = Int32(WINARC_WINESERVER_NOT_STARTED)
    @State private var serverExitCode: Int32 = -9999

    @State private var clientState: Int32 = Int32(WINARC_WINECLIENT_NOT_STARTED)
    @State private var clientExitCode: Int32 = -9999

    @State private var lastError = ""
    @State private var startResult: Int32 = 0

    private let refreshTimer = Timer.publish(
        every: 0.5,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(statusColor.opacity(0.16))

                Image(systemName: statusIcon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle)
                    .font(.system(size: 17, weight: .semibold))

                Text(statusSubtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WinArcTheme.secondary)

                Text(statusDetail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(2)
            }

            Spacer()

            actionView
        }
        .padding(18)
        .winArcGlass()
        .onAppear(perform: probe)
        .onReceive(refreshTimer) { _ in
            probe()
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if linked && serverState == Int32(WINARC_WINESERVER_NOT_STARTED) {
            Button("启动 wineserver") {
                startWineServer()
            }
            .buttonStyle(.borderedProminent)

        } else if serverState == Int32(WINARC_WINESERVER_RUNNING) &&
                    clientState == Int32(WINARC_WINECLIENT_NOT_STARTED) {
            Button("启动 Wine 桌面") {
                startWineDesktop()
            }
            .buttonStyle(.borderedProminent)

        } else if clientState == Int32(WINARC_WINECLIENT_STARTING) ||
                    clientState == Int32(WINARC_WINECLIENT_RUNNING) {
            Label("桌面运行中", systemImage: "display")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)

        } else if serverState == Int32(WINARC_WINESERVER_RUNNING) {
            Label("wineserver 运行中", systemImage: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)

        } else {
            Button("重新检测") {
                probe()
            }
            .buttonStyle(.bordered)
        }
    }

    private var statusColor: Color {
        if !linked { return .orange }

        if clientState == Int32(WINARC_WINECLIENT_FAILED) {
            return .red
        }

        if clientState == Int32(WINARC_WINECLIENT_STARTING) {
            return .blue
        }

        if clientState == Int32(WINARC_WINECLIENT_RUNNING) {
            return .green
        }

        switch serverState {
        case Int32(WINARC_WINESERVER_STARTING):
            return .blue
        case Int32(WINARC_WINESERVER_RUNNING):
            return .green
        case Int32(WINARC_WINESERVER_RETURNED):
            return .orange
        default:
            return .green
        }
    }

    private var statusIcon: String {
        if !linked { return "exclamationmark.triangle.fill" }

        if clientState == Int32(WINARC_WINECLIENT_FAILED) {
            return "xmark.circle.fill"
        }

        if clientState == Int32(WINARC_WINECLIENT_STARTING) {
            return "hourglass.circle.fill"
        }

        if clientState == Int32(WINARC_WINECLIENT_RUNNING) {
            return "display"
        }

        switch serverState {
        case Int32(WINARC_WINESERVER_STARTING):
            return "hourglass.circle.fill"
        case Int32(WINARC_WINESERVER_RUNNING):
            return "checkmark.circle.fill"
        case Int32(WINARC_WINESERVER_RETURNED):
            return "xmark.circle.fill"
        default:
            return "checkmark.circle.fill"
        }
    }

    private var statusTitle: String {
        if !linked { return "Wine 运行时未链接" }

        if clientState == Int32(WINARC_WINECLIENT_STARTING) {
            return "Wine 桌面正在启动"
        }

        if clientState == Int32(WINARC_WINECLIENT_RUNNING) {
            return "Wine 桌面正在运行"
        }

        if clientState == Int32(WINARC_WINECLIENT_FAILED) {
            return "Wine 桌面启动失败"
        }

        if clientState == Int32(WINARC_WINECLIENT_EXITED) {
            return "Wine 桌面已退出"
        }

        switch serverState {
        case Int32(WINARC_WINESERVER_STARTING):
            return "wineserver 正在启动"
        case Int32(WINARC_WINESERVER_RUNNING):
            return "wineserver 线程运行中"
        case Int32(WINARC_WINESERVER_RETURNED):
            return "wineserver 已退出"
        default:
            return "Wine 运行时已链接"
        }
    }

    private var statusSubtitle: String {
        if !linked {
            return "WinArc.app 没有找到 Wine runtime boundary"
        }

        if clientState == Int32(WINARC_WINECLIENT_STARTING) {
            return "socketpair → WINESERVERSOCKET → __wine_main"
        }

        if clientState == Int32(WINARC_WINECLIENT_RUNNING) {
            return "ABI \(abi) · explorer.exe /desktop=WinArc,1280x720"
        }

        if clientState == Int32(WINARC_WINECLIENT_FAILED) {
            return lastError.isEmpty
                ? "Wine Client exit \(clientExitCode)"
                : lastError
        }

        if clientState == Int32(WINARC_WINECLIENT_EXITED) {
            return "Wine Client exit \(clientExitCode)"
        }

        switch serverState {
        case Int32(WINARC_WINESERVER_STARTING):
            return "正在 WinArc 进程内创建 Wine server pthread"
        case Int32(WINARC_WINESERVER_RUNNING):
            return "ABI \(abi) · wineserver 已就绪"
        case Int32(WINARC_WINESERVER_RETURNED):
            return lastError.isEmpty
                ? "wineserver_main 已返回 · exit \(serverExitCode)"
                : lastError
        default:
            return "ABI \(abi) · wineserver / __wine_main entry ready"
        }
    }

    private var statusDetail: String {
        if !linked {
            return "先修复最终 Mach-O 链接。"
        }

        if clientState == Int32(WINARC_WINECLIENT_RUNNING) {
            return "Winios 正把 Wine 的 GDI 窗口合成到下面的桌面区域。"
        }

        if clientState == Int32(WINARC_WINECLIENT_FAILED) {
            return "错误已限定在 Wine Client / prefix / Winios 桌面链。"
        }

        if serverState == Int32(WINARC_WINESERVER_RUNNING) {
            return "下一步只启动 ARM64 explorer 桌面；DXMT/D3DMetal 此时不初始化。"
        }

        return "Prefix 模板会在 wineserver 启动前准备，避免空注册表状态。"
    }

    private func probe() {
        linked = winarc_wine_runtime_is_linked() != 0
        abi = winarc_wine_runtime_abi()

        let serverEntry = UInt(winarc_wine_runtime_server_entry())
        let clientEntry = UInt(winarc_wine_runtime_client_entry())

        if serverEntry == 0 || clientEntry == 0 {
            linked = false
        }

        serverState = Int32(winarc_wine_runtime_server_state())
        serverExitCode = Int32(winarc_wine_runtime_server_exit_code())

        clientState = Int32(winarc_wine_runtime_client_state())
        clientExitCode = Int32(winarc_wine_runtime_client_exit_code())

        if let errorPointer = winarc_wine_runtime_last_error() {
            lastError = String(cString: errorPointer)
        } else {
            lastError = ""
        }
    }

    private func runtimePaths() -> (prefix: URL, nls: URL, bundle: URL)? {
        let fileManager = FileManager.default

        guard let resourceURL = Bundle.main.resourceURL else {
            lastError = "找不到 WinArc.app Resources"
            startResult = -3
            return nil
        }

        let template = resourceURL.appendingPathComponent(
            "WinArcPrefixTemplate",
            isDirectory: true
        )

        let nls = resourceURL.appendingPathComponent(
            "nls",
            isDirectory: true
        )

        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        let runtimeRoot = support
            .appendingPathComponent("WinArc", isDirectory: true)

        let prefix = runtimeRoot
            .appendingPathComponent("WinePrefix", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: runtimeRoot,
                withIntermediateDirectories: true
            )

            try preparePrefixIfNeeded(
                fileManager: fileManager,
                template: template,
                prefix: prefix
            )

            try repairTemplateShellFolders(
                fileManager: fileManager,
                prefix: prefix
            )
        } catch {
            lastError = "准备 WinePrefix 失败：\(error.localizedDescription)"
            startResult = -6
            return nil
        }

        return (
            prefix,
            nls,
            URL(fileURLWithPath: Bundle.main.bundlePath)
        )
    }

    private func preparePrefixIfNeeded(
        fileManager: FileManager,
        template: URL,
        prefix: URL
    ) throws {
        let systemReg = prefix.appendingPathComponent("system.reg")

        if fileManager.fileExists(atPath: systemReg.path) {
            return
        }

        guard fileManager.fileExists(atPath: template.path) else {
            throw NSError(
                domain: "WinArcWine",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "WinArcPrefixTemplate 不在 App Bundle 中"
                ]
            )
        }

        /*
         * v0.0.1 development prefixes created before the template stage are
         * disposable. Replacing an incomplete prefix here is safer than
         * letting wineserver snapshot an empty registry.
         */
        if fileManager.fileExists(atPath: prefix.path) {
            try fileManager.removeItem(at: prefix)
        }

        try fileManager.copyItem(at: template, to: prefix)
    }

    private func repairTemplateShellFolders(
        fileManager: FileManager,
        prefix: URL
    ) throws {
        let users = prefix
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("users", isDirectory: true)

        guard fileManager.fileExists(atPath: users.path) else {
            return
        }

        let userDirectories = try fileManager.contentsOfDirectory(
            at: users,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let shellFolders = [
            "Desktop",
            "Documents",
            "Downloads",
            "Music",
            "Pictures",
            "Videos"
        ]

        for user in userDirectories {
            if user.lastPathComponent.lowercased() == "public" {
                continue
            }

            let values = try? user.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                continue
            }

            for folder in shellFolders {
                let destination = user.appendingPathComponent(
                    folder,
                    isDirectory: true
                )

                /*
                 * The reference template contains absolute build-machine
                 * symlinks for some shell folders. Remove any old entry and
                 * create a sandbox-local directory instead.
                 */
                if fileManager.fileExists(atPath: destination.path) ||
                   (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey])
                        .isSymbolicLink) == true {
                    try? fileManager.removeItem(at: destination)
                }

                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            }
        }
    }

    private func startWineServer() {
        guard linked, let paths = runtimePaths() else { return }

        startResult = paths.prefix.path.withCString { prefixCString in
            paths.nls.path.withCString { nlsCString in
                Int32(
                    winarc_wine_runtime_start_server(
                        prefixCString,
                        nlsCString
                    )
                )
            }
        }

        probe()
    }

    private func startWineDesktop() {
        guard linked,
              serverState == Int32(WINARC_WINESERVER_RUNNING),
              let paths = runtimePaths() else {
            return
        }

        winios_init()

        startResult = paths.prefix.path.withCString { prefixCString in
            paths.bundle.path.withCString { bundleCString in
                Int32(
                    winarc_wine_runtime_start_desktop(
                        prefixCString,
                        bundleCString
                    )
                )
            }
        }

        probe()
    }
}
