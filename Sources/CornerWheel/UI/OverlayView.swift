import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: OverlayViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if let frame = model.emptyStateFrame {
                    emptyState
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX + model.contentOffset.x,
                                  y: geometry.size.height - frame.midY - model.contentOffset.y)
                }

                ForEach(model.items) { item in
                    previewCard(item)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .scaleEffect(model.hoveredID == item.record.id ? 1.04 : 1)
                        .position(x: item.frame.midX + model.contentOffset.x,
                                  y: geometry.size.height - item.frame.midY - model.contentOffset.y)
                        .zIndex(model.hoveredID == item.record.id ? 3 :
                                model.selectedID == item.record.id ? 2 : 1)
                }

                if let failure = model.failureText {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.red, in: Capsule())
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.hoveredID)
        }
        .background(Color.clear)
    }

    private var emptyState: some View {
        Text("No apps to switch between")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewCard(_ item: OverlayViewModel.Item) -> some View {
        let selected = model.selectedID == item.record.id
        let applicationName = item.record.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowTitle = item.record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = windowTitle.isEmpty || windowTitle.localizedCaseInsensitiveCompare(applicationName) == .orderedSame
            ? applicationName : windowTitle
        let accessibilityName = label == applicationName ? applicationName : "\(label), \(applicationName)"
        return Button {
            model.onActivate?(item.record)
        } label: {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.22),
                                        Color(nsColor: .controlBackgroundColor)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Circle().fill(.red.opacity(0.8)).frame(width: 5, height: 5)
                        Circle().fill(.orange.opacity(0.8)).frame(width: 5, height: 5)
                        Circle().fill(.green.opacity(0.8)).frame(width: 5, height: 5)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 20)
                    .padding(.horizontal, 7)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.76))

                    Spacer(minLength: 3)
                    if let icon = item.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 38, weight: .ultraLight))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, height: 48)
                            .accessibilityHidden(true)
                    }
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                    Spacer(minLength: 3)
                }
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09))
                }
                .padding(7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .windowBackgroundColor).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: selected ? 2.5 : 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 11, y: 5)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            model.hoveredID = inside ? item.record.id :
                (model.hoveredID == item.record.id ? nil : model.hoveredID)
        }
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(selected ? "Selected. " : "")Static window card")
        .accessibilityHint("Activate this window. Right-click for window actions.")
        .accessibilityAction(named: Text(item.record.isMinimized ? "Restore Window" : "Minimize Window")) {
            model.onWindowAction?(item.record.isMinimized ? .restore : .minimize, item.record)
        }
        .accessibilityAction(named: Text("Close Window")) {
            model.onWindowAction?(.close, item.record)
        }
    }
}
