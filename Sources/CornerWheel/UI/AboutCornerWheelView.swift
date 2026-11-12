import AppKit
import SwiftUI

struct AboutCornerWheelView: View {
    var body: some View {
        GroupBox("About CornerWheel") {
            VStack(alignment: .leading, spacing: 10) {
                Text("CornerWheel is free. No purchase, account or activation key is required.")
                    .font(.callout)
                HStack(spacing: 16) {
                    Link("Privacy", destination: URL(string: "https://cornerwheel.com/privacy.html")!)
                    Link("Terms of Use", destination: URL(string: "https://cornerwheel.com/terms.html")!)
                    Link("Support", destination: URL(string: "mailto:support@cornerwheel.com")!)
                }
                if let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                    Button("Third-party Notices") { NSWorkspace.shared.open(notices) }
                        .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
