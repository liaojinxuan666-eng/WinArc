import SwiftUI

struct MadeiraLogView: View {
    @Environment(\.dismiss) private var dismiss

    private enum LogKind: String, CaseIterable, Identifiable {
        case current = "当前"
        case previous = "上一轮"

        var id: String { rawValue }
    }

    @State private var kind: LogKind = .current
    @State private var text = ""

    private let timer = Timer.publish(
        every: 1.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("日志", selection: $kind) {
                    ForEach(LogKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                ScrollView([.vertical, .horizontal]) {
                    Text(text.isEmpty ? "日志为空" : text)
                        .font(
                            .system(
                                size: 10,
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
            .background(WinArcTheme.background.ignoresSafeArea())
            .navigationTitle("Madeira Runtime 日志")
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("关闭") { dismiss() }
                }

                ToolbarItemGroup(
                    placement: .primaryAction
                ) {
                    Button("刷新") { reload() }

                    ShareLink(item: selectedURL) {
                        Label(
                            "导出",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
            }
            .onAppear(perform: reload)
            .onChange(of: kind) { _ in reload() }
            .onReceive(timer) { _ in reload() }
        }
        .preferredColorScheme(.dark)
    }

    private var selectedURL: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        switch kind {
        case .current:
            return docs.appendingPathComponent("madeira-log.txt")
        case .previous:
            return docs.appendingPathComponent("madeira-log.prev.txt")
        }
    }

    private func reload() {
        text = (
            try? String(
                contentsOf: selectedURL,
                encoding: .utf8
            )
        ) ?? ""
    }
}
