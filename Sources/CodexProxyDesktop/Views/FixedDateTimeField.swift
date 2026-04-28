#if os(macOS)
import AppKit
import SwiftUI

struct FixedDateTimeField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPickerPresented = false

    @Binding var value: Date

    let title: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let displayText = DesktopDateTimeFormat.string(from: self.value)

        Button {
            self.isPickerPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)

                Text(displayText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: self.isPickerPresented ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .interactiveCursor(isEnabled: self.isEnabled)
        .modifier(FixedDateTimeFieldChromeModifier(isActive: self.isPickerPresented))
        .popover(isPresented: self.$isPickerPresented, arrowEdge: .bottom) {
            FixedDateTimePopover(value: self.$value)
        }
        .help("\(self.title): \(displayText)")
    }
}

private struct FixedDateTimeFieldChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var isActive = false

    func body(content: Content) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        self.isActive
                            ? palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.92 : 0.98)
                            : palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.82 : 0.90)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(self.isActive ? palette.accent.opacity(0.72) : palette.border, lineWidth: 1)
            )
    }
}

private struct FixedDateTimePopover: View {
    @Binding var value: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(DesktopDateTimeFormat.string(from: self.value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)

            NativePopoverDateTimePicker(value: self.$value)
                .frame(width: 300, height: 190)
        }
        .padding(12)
    }
}

private struct NativePopoverDateTimePicker: NSViewRepresentable {
    @Binding var value: Date

    func makeCoordinator() -> Coordinator {
        Coordinator(value: self.$value)
    }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerMode = .single
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.calendar = Calendar(identifier: .gregorian)
        picker.locale = .current
        picker.timeZone = .current
        picker.dateValue = self.value
        picker.textColor = .labelColor
        picker.drawsBackground = false
        picker.isBezeled = false
        picker.isBordered = false
        picker.controlSize = .regular
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.didChangeValue(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        picker.calendar = Calendar(identifier: .gregorian)
        picker.locale = .current
        picker.timeZone = .current
        if picker.dateValue != self.value {
            picker.dateValue = self.value
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding private var value: Date

        init(value: Binding<Date>) {
            self._value = value
        }

        @objc func didChangeValue(_ sender: NSDatePicker) {
            if self.value != sender.dateValue {
                self.value = sender.dateValue
            }
        }
    }
}
#endif
