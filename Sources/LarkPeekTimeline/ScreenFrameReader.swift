import AppKit
import SwiftUI

struct ScreenFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> ScreenFrameReportingView {
        let view = ScreenFrameReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ScreenFrameReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrame()
    }
}

final class ScreenFrameReportingView: NSView {
    var onChange: ((CGRect) -> Void)?
    private var lastReportedFrame = CGRect.null

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    func reportFrame() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let rawFrame = window.convertToScreen(self.convert(self.bounds, to: nil))
            let scale = window.backingScaleFactor
            let frame = CGRect(
                x: (rawFrame.minX * scale).rounded() / scale,
                y: (rawFrame.minY * scale).rounded() / scale,
                width: (rawFrame.width * scale).rounded() / scale,
                height: (rawFrame.height * scale).rounded() / scale
            )
            guard !frame.equalTo(self.lastReportedFrame) else { return }
            self.lastReportedFrame = frame
            self.onChange?(frame)
        }
    }
}
