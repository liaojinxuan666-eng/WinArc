import SwiftUI

struct RuntimeLogView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(WinArcRuntimeLog.showLiveKey)
    private var showLiveLog = false

    @State private var logText = ""
    @State private var refreshID = 0

    private let timer = Timer.publish(
        every: 1.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Label(
                        WinArcRuntimeLog.isCapturing
                            ? "当前正在写入日志。"
                            : "当前没有写入；历史日志仍可查看和导出。",
                        systemImage:
                            WinArcRuntimeLog.isCapturing
                                ? "record.circle"
                                : "doc.text"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Spacer()
                }

                ScrollView([.vertical, .horizontal]) {
                    Text(logText)
                        .font(
                            .system(
                                size: 11,
                                design: .monospaced
                            )
                        )
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                        .padding(12)
                }
                .background(.black.opacity(0.35))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                )
            }
            .padding(16)
            .navigationTitle("WinArc 运行日志")
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("关闭") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(
                    placement: .primaryAction
                ) {
                    Button("刷新") {
                        reload()
                    }

                    Button(
                        "清空",
                        role: .destructive
                    ) {
                        WinArcRuntimeLog.clear()
                        reload()
                    }

                    ShareLink(
                        item: WinArcRuntimeLog.fileURL
                    ) {
                        Label(
                            "导出",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
            }
            .onAppear {
                WinArcRuntimeLog.ensureLogFileExists()
                reload()
            }
            .onReceive(timer) { _ in
                if showLiveLog &&
                   WinArcRuntimeLog.isCapturing {
                    reload()
                }
            }
            .id(refreshID)
        }
    }

    private func reload() {
        logText = WinArcRuntimeLog.tail()
        refreshID &+= 1
    }
}

struct RuntimeLiveLogPanel: View {
    @State private var text = ""

    private let timer = Timer.publish(
        every: 1.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "实时日志",
                    systemImage: "terminal"
                )
                .font(.caption.weight(.semibold))

                Spacer()

                Text(
                    WinArcRuntimeLog.isCapturing
                        ? "REC"
                        : "IDLE"
                )
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(
                    WinArcRuntimeLog.isCapturing
                        ? .green
                        : .secondary
                )
            }

            ScrollView(.vertical) {
                Text(text)
                    .font(
                        .system(
                            size: 9,
                            design: .monospaced
                        )
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                    .textSelection(.enabled)
            }
            .frame(height: 120)
        }
        .padding(14)
        .background(.black.opacity(0.30))
        .clipShape(
            RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
        )
        .onAppear(perform: reload)
        .onReceive(timer) { _ in
            reload()
        }
    }

    private func reload() {
        text = WinArcRuntimeLog.tail(
            maxBytes: 24 * 1024
        )
    }
}
