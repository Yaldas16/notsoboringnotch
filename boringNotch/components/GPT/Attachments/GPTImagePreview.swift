import SwiftUI

struct GPTImagePreview: View {
    let attachment: GPTImageAttachment
    let side: CGFloat

    var body: some View {
        Image(decorative: attachment.preview, scale: 1)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel("Attached image, \(attachment.width) by \(attachment.height) pixels")
    }
}
