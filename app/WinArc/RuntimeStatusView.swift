import Foundation
import SwiftUI

struct RuntimeStatusView: View {
    @State private var linked = false
    @State private var abi: UInt32 = 0
    @State private var serverEntry: UInt = 0
    @State private var clientEntry: UInt = 0

    @State private var serverState: Int32 = Int32(WINARC_WINESERVER_NOT_STARTED)
    @State private var serverExitCode: Int32 = -9999
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

            if linked && serverState == Int32(WINARC_WINESERVER_NOT_STARTED) {
                Button("启动 wineserver") {
                    startWineServer()
                }
                .buttonStyle(.borderedProminent)
            } else if serverState == Int32(WINARC_WINESERVER_STARTING) ||
                        serverState == Int32(WINARC_WINESERVER_RUNNING) {
                Label("运行中", systemImage: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Button("重新检测") {
                    probe()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .winArcGlass()
        .onAppear(perform: probe)
        .onReceive(refreshTimer) { _ in
            probe()
        }
    }

    private var statusColor: Color {
        if !linked { return .orange }

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

        switch serverState {
        case Int32(WINARC_WINESERVER_STARTING):
            return "正在 WinArc 进程内创建 Wine server pthread"
        case Int32(WINARC_WINESERVER_RUNNING):
            return "ABI \(abi) · Wine server 正在 WinArc Mach 进程内执行"
        case Int32(WINARC_WINESERVER_RETURNED):
            if !lastError.isEmpty {
                return lastError
            }
            return "wineserver_main 已返回 · exit \(serverExitCode)"
        default:
            return "ABI \(abi) · wineserver / __wine_main entry ready"
        }
    }

    private var statusDetail: String {
        if !linked {
            return "先修复最终 Mach-O 链接。"
        }

        switch serverState {
        case Int32(WINARC_WINESERVER_RUNNING):
            return "本阶段已开始真实执行 Wine；下一步接 socketpair + __wine_main 客户端。"
        case Int32(WINARC_WINESERVER_RETURNED):
            if startResult < 0 && !lastError.isEmpty {
                return "启动结果 \(startResult) · \(lastError)"
            }
            return "不要在同一进程重复初始化；重新打开 WinArc 后再测试。"
        default:
            return "当前下一步：启动 wineserver；Windows 客户端暂未执行。"
        }
    }

    private func probe() {
        linked = winarc_wine_runtime_is_linked() != 0
        abi = winarc_wine_runtime_abi()
        serverEntry = UInt(winarc_wine_runtime_server_entry())
        clientEntry = UInt(winarc_wine_runtime_client_entry())

        if serverEntry == 0 || clientEntry == 0 {
            linked = false
        }

        serverState = Int32(winarc_wine_runtime_server_state())
        serverExitCode = Int32(winarc_wine_runtime_server_exit_code())

        if let errorPointer = winarc_wine_runtime_last_error() {
            lastError = String(cString: errorPointer)
        } else {
            lastError = ""
        }
    }

    private func startWineServer() {
        guard linked else { return }

        let fileManager = FileManager.default
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
                at: prefix,
                withIntermediateDirectories: true
            )
        } catch {
            lastError = "创建 WinePrefix 失败：\(error.localizedDescription)"
            startResult = -2
            return
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            lastError = "找不到 WinArc.app Resources"
            startResult = -3
            return
        }

        let nls = resourceURL.appendingPathComponent(
            "nls",
            isDirectory: true
        )

        startResult = prefix.path.withCString { prefixCString in
            nls.path.withCString { nlsCString in
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
}
