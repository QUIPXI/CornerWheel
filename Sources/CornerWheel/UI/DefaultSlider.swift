import AppKit
import SwiftUI

/// A continuous native slider with a light snap to its default on release.
struct DefaultSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let label: String
    let formatValue: (Double) -> String
    var roundingIncrement: Double? = nil
    var step: Double? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> DefaultSliderControl {
        let slider = DefaultSliderControl(frame: .zero)
        if step != nil { slider.cell = HiddenTickSliderCell() }
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.isVertical = false
        slider.trackFillColor = NSColor(srgbRed: 0.46, green: 0.65, blue: 0.91, alpha: 1)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: DefaultSliderControl, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if let step, step > 0 {
            slider.numberOfTickMarks = Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1
            slider.allowsTickMarkValuesOnly = true
        } else {
            slider.numberOfTickMarks = 0
            slider.allowsTickMarkValuesOnly = false
        }
        slider.defaultValue = defaultValue
        slider.roundingIncrement = roundingIncrement
        slider.isEnabled = isEnabled
        // Keep native pointer tracking independent of rounded saved values.
        if !slider.isTrackingPointer { slider.doubleValue = value }
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(formatValue(value))
        let help = "Default: \(formatValue(defaultValue)). Release near the default value to snap to it."
        slider.toolTip = help
        slider.setAccessibilityHelp(help)
        slider.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: DefaultSlider

        init(_ parent: DefaultSlider) { self.parent = parent }

        @objc func changed(_ slider: DefaultSliderControl) {
            parent.value = slider.resolvedValue(slider.doubleValue, snapToDefault: false)
            slider.setAccessibilityValueDescription(parent.formatValue(parent.value))
        }
    }
}

/// Preserve native stepped dragging, keyboard and accessibility behavior
/// without adding visible tick marks to the settings sliders.
private final class HiddenTickSliderCell: NSSliderCell {
    override func drawTickMarks() {}
}

final class DefaultSliderControl: NSSlider {
    var defaultValue = 0.0
    var roundingIncrement: Double?
    private(set) var isTrackingPointer = false

    override func mouseDown(with event: NSEvent) {
        isTrackingPointer = true
        super.mouseDown(with: event)
        isTrackingPointer = false
        // A narrow release zone (about three points of travel) provides a
        // gentle snap without resisting the drag or trapping keyboard steps.
        doubleValue = resolvedValue(doubleValue, snapToDefault: true)
        sendAction(action, to: target)
        needsDisplay = true
    }

    func resolvedValue(_ proposedValue: Double, snapToDefault: Bool) -> Double {
        let clamped = min(maxValue, max(minValue, proposedValue))
        if snapToDefault, abs(clamped - defaultValue) <= (maxValue - minValue) * 0.02 {
            return defaultValue
        }
        if let increment = roundingIncrement, increment > 0 {
            return min(maxValue, max(minValue, (clamped / increment).rounded() * increment))
        }
        return clamped
    }

}
