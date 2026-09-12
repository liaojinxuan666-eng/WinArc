import Foundation
import SwiftUI

enum WinArcRuntimeLog {
    static var directoryURL: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("WinArcLogs", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("winarc-runtime.log")
    }

    @discardableResult
    static func install() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }

        return fileURL.path.withCString {
            winarc_runtime_log_install($0) >= 0
        }
    }

    static func mark(_ subsystem: String, _ message: String) {
        install()

        subsystem.withCString { subsystemCString in
            message.withCString { messageCString in
                winarc_runtime_log_mark(
                    subsystemCString,
                    messageCString
                )
            }
        }
    }

    static func tail(maxBytes: Int = 512 * 1024) -> String {
        let url = fileURL

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "还没有运行日志。"
        }

        defer {
            try? handle.close()
        }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(maxBytes)
            ? end - UInt64(maxBytes)
            : 0

        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd(),
              let data,
              !data.isEmpty else {
            return "日志文件为空。"
        }

        var text = String(decoding: data, as: UTF8.self)

        if start > 0 {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            text = "……仅显示最后 \(maxBytes / 1024) KB……\n" + text
        }

        return text
    }

    static func clear() {
        install()

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }

        try? handle.truncate(atOffset: 0)
        try? handle.synchronize()
        try? handle.close()

        mark("LOG", "log cleared")
    }
}

struct RuntimeLogView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var logText = ""
    @State private var refreshID = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Label(
                        "闪退后重新打开 WinArc，这里仍能看到闪退前最后写入的阶段。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Spacer()
                }

                ScrollView([.vertical, .horizontal]) {
                    Text(logText)
                        .font(.system(size: 11, design: .monospaced))
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button("刷新") {
                        reload()
                    }

                    Button("清空", role: .destructive) {
                        WinArcRuntimeLog.clear()
                        reload()
                    }

                    ShareLink(item: WinArcRuntimeLog.fileURL) {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .onAppear {
                WinArcRuntimeLog.install()
                reload()
            }
            .id(refreshID)
        }
    }

    private func reload() {
        logText = WinArcRuntimeLog.tail()
        refreshID &+= 1
    }
}
