import SwiftUI

struct RuntimeStatusView: View {
    @State private var linked = false
    @State private var abi: UInt32 = 0
    @State private var serverEntry: UInt = 0
    @State private var clientEntry: UInt = 0

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(linked ? Color.green.opacity(0.16) : Color.orange.opacity(0.16))

                Image(systemName: linked ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(linked ? .green : .orange)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(linked ? "Wine 运行时已链接" : "Wine 运行时未链接")
                    .font(.system(size: 17, weight: .semibold))

                if linked {
                    Text("ABI \(abi) · wineserver / __wine_main entry ready")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WinArcTheme.secondary)

                    Text("当前阶段：只探测链接，不执行 Wine")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                } else {
                    Text("WinArc.app 没有找到 Wine runtime boundary")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WinArcTheme.secondary)
                }
            }

            Spacer()

            Button("重新检测") {
                probe()
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .winArcGlass()
        .onAppear(perform: probe)
    }

    private func probe() {
        linked = winarc_wine_runtime_is_linked() != 0
        abi = winarc_wine_runtime_abi()
        serverEntry = UInt(winarc_wine_runtime_server_entry())
        clientEntry = UInt(winarc_wine_runtime_client_entry())

        if serverEntry == 0 || clientEntry == 0 {
            linked = false
        }
    }
}
