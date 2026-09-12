import SwiftUI
import UIKit

private final class WinArcWineDesktopHostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()

        winios_set_compositor_frame(bounds)
        winios_set_screen_size(1280, 720, window?.screen.scale ?? UIScreen.main.scale)
    }
}

struct WineDesktopSurfaceView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = WinArcWineDesktopHostView()
        view.backgroundColor = UIColor(white: 0.025, alpha: 1.0)
        view.clipsToBounds = true

        winios_attach_compositor(view)
        winios_set_screen_size(1280, 720, UIScreen.main.scale)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        winios_attach_compositor(uiView)
        winios_set_compositor_frame(uiView.bounds)
        winios_set_screen_size(
            1280,
            720,
            uiView.window?.screen.scale ?? UIScreen.main.scale
        )
    }
}
