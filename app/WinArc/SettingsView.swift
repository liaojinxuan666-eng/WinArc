import SwiftUI

struct SettingsView: View {
    @AppStorage(WinArcRuntimeLog.enabledKey)
    private var logEnabled = true

    @AppStorage(WinArcRuntimeLog.modeKey)
    private var logModeRaw =
        WinArcRuntimeLogMode.gameLoading.rawValue

    @AppStorage(WinArcRuntimeLog.showLiveKey)
    private var showLiveLog = false

    @State private var showingRuntimeLog = false

    private var logMode: WinArcRuntimeLogMode {
        get {
            WinArcRuntimeLogMode(rawValue: logModeRaw)
                ?? .gameLoading
        }
        nonmutating set {
            logModeRaw = newValue.rawValue
        }
    }

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

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(
                            "运行日志",
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .font(.headline)

                        Spacer()

                        if WinArcRuntimeLog.isCapturing {
                            Label("记录中", systemImage: "record.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        } else if logEnabled {
                            Text("等待启动")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(WinArcTheme.secondary)
                        } else {
                            Text("关闭")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(WinArcTheme.secondary)
                        }
                    }

                    Toggle(
                        "启用运行日志",
                        isOn: $logEnabled
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("记录方式")
                            .font(.subheadline.weight(.semibold))

                        Picker(
                            "记录方式",
                            selection: Binding(
                                get: { logMode },
                                set: { logMode = $0 }
                            )
                        ) {
                            ForEach(
                                WinArcRuntimeLogMode.allCases
                            ) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!logEnabled)

                        Text(logMode.detail)
                            .font(.footnote)
                            .foregroundStyle(
                                WinArcTheme.secondary
                            )
                    }

                    Divider()

                    Toggle(
                        "运行时显示实时日志",
                        isOn: $showLiveLog
                    )
                    .disabled(!logEnabled)

                    Text(
                        showLiveLog
                            ? "首页会显示一个小型实时日志窗口。"
                            : "日志完全在后台记录，不挡游戏画面；跑完后可在这里查看或导出。"
                    )
                    .font(.footnote)
                    .foregroundStyle(WinArcTheme.secondary)

                    Divider()

                    HStack(spacing: 10) {
                        Button("查看日志") {
                            WinArcRuntimeLog.ensureLogFileExists()
                            showingRuntimeLog = true
                        }
                        .buttonStyle(.borderedProminent)

                        ShareLink(
                            item: WinArcRuntimeLog.fileURL
                        ) {
                            Label(
                                "导出",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .buttonStyle(.bordered)

                        Button(
                            "清空",
                            role: .destructive
                        ) {
                            WinArcRuntimeLog.clear()
                        }
                        .buttonStyle(.bordered)
                    }

                    Text(
                        "日志文件保存在 Documents/WinArcLogs。单个当前日志达到 16 MB 时自动轮换一次，避免“一直日志”无限占空间。"
                    )
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.42))
                }
                .padding(22)
                .winArcGlass()

                Text("WinArc Shell v0.0.1")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .sheet(isPresented: $showingRuntimeLog) {
            RuntimeLogView()
        }
        .onAppear {
            /*
             * @AppStorage defaults are mirrored by WinArcRuntimeLog,
             * but make sure the low-level capture state follows them if
             * Settings is the first screen opened after an upgrade.
             */
            WinArcRuntimeLog.applyPreferencesNow()
        }
        .onChange(of: logEnabled) { _, _ in
            WinArcRuntimeLog.applyPreferencesNow()
        }
        .onChange(of: logModeRaw) { _, _ in
            WinArcRuntimeLog.applyPreferencesNow()
        }
    }
}
