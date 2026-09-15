// SPDX-License-Identifier: MPL-2.0

import CoreImage
import CoreGraphics
import SwiftUI
import UIKit

final class ClientPixelBufferRenderView: UIView {
    private static let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    private let ciContext = CIContext(options: [
        .workingColorSpace: ClientPixelBufferRenderView.displayColorSpace,
        .outputColorSpace: ClientPixelBufferRenderView.displayColorSpace
    ])

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // The SwiftUI container owns aspect fitting so touch mapping and video
        // presentation use the same rect. A second aspect fit here can create
        // accidental pillarboxing when the initial/default stream size is stale.
        layer.contentsGravity = .resize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: Self.displayColorSpace])
        guard let cgImage = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.displayColorSpace) else { return }

        DispatchQueue.main.async {
            self.layer.contents = cgImage
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.layer.contents = nil
        }
    }
}

struct ClientVideoView: UIViewRepresentable {
    @ObservedObject var model: ClientModel

    func makeUIView(context: Context) -> ClientPixelBufferRenderView {
        let view = ClientPixelBufferRenderView()
        model.attachRenderer(view)
        return view
    }

    func updateUIView(_ uiView: ClientPixelBufferRenderView, context: Context) {
        model.attachRenderer(uiView)
    }
}
