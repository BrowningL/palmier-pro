import SwiftUI

struct TextTab: View {
    let clip: Clip
    @Environment(EditorViewModel.self) private var editor

    private var style: TextStyle { clip.textStyle ?? TextStyle() }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            contentField
            InspectorSection("Typography") {
                fontRow
                sizeSlider
                lineHeightRow
            }
            InspectorSection("Appearance") {
                colorRow
                opacitySlider
                strokeRow
                if style.border.enabled { strokeWidthRow }
                shadowRow
            }
            InspectorSection("Background") {
                backgroundToggleRow
                if style.background.enabled {
                    backgroundPaddingHRow
                    backgroundPaddingVRow
                    backgroundCornerRow
                }
                backgroundPresetRow
            }
            InspectorSection("Layout") {
                alignmentRow
                positionSection
            }
        }
    }

    // MARK: - Controls

    private var contentField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            InspectorRow(icon: "textformat", label: "Content")
            TextContentField(
                text: Binding(
                    get: { clip.textContent ?? "" },
                    set: { new in
                        editor.applyClipProperty(clipId: clip.id, rebuild: true) { $0.textContent = new }
                        editor.fitTextClipToContent(clipId: clip.id)
                    }
                ),
                onCommit: { new in
                    editor.commitClipProperty(clipId: clip.id) { $0.textContent = new }
                    editor.fitTextClipToContent(clipId: clip.id)
                }
            )
            .frame(minHeight: 80)
            .padding(AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(AppTheme.Opacity.hint))
            )
        }
    }

    private var fontRow: some View {
        InspectorRow(icon: "character", label: "Font") {
            FontPickerField(
                current: style.fontName,
                onPreview: { name in
                    editor.applyTextStyle(clipId: clip.id) { $0.fontName = name }
                },
                onChange: { newName in
                    editor.commitTextStyle(clipId: clip.id) { $0.fontName = newName }
                    editor.fitTextClipToContent(clipId: clip.id)
                },
                onCancel: {
                    editor.revertClipProperty(clipId: clip.id)
                }
            )
        }
    }

    private var sizeSlider: some View {
        InspectorRow(icon: "textformat.size", label: "Size") {
            ScrubbableNumberField(
                value: style.fontSize,
                range: 12...300,
                format: "%.0f",
                valueSuffix: " pt",
                fieldWidth: 50,
                onChanged: { newVal in
                    editor.applyTextStyle(clipId: clip.id) { $0.fontSize = newVal }
                    editor.fitTextClipToContent(clipId: clip.id)
                }
            ) { newVal in
                editor.commitTextStyle(clipId: clip.id) { $0.fontSize = newVal }
                editor.fitTextClipToContent(clipId: clip.id)
            }
        }
    }

    private var lineHeightRow: some View {
        InspectorRow(icon: "arrow.up.and.down.text.horizontal", label: "Line Height") {
            ScrubbableNumberField(
                value: style.lineHeightMultiple,
                range: 0.5...2,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: 50,
                onChanged: { newVal in
                    editor.applyTextStyle(clipId: clip.id) { $0.lineHeightMultiple = newVal }
                    editor.fitTextClipToContent(clipId: clip.id)
                }
            ) { newVal in
                editor.commitTextStyle(clipId: clip.id) { $0.lineHeightMultiple = newVal }
                editor.fitTextClipToContent(clipId: clip.id)
            }
        }
    }

    private var opacitySlider: some View {
        InspectorRow(icon: "circle.lefthalf.filled", label: "Opacity") {
            ScrubbableNumberField(
                value: clip.opacity,
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: 50,
                onChanged: { newVal in
                    editor.applyClipProperty(clipId: clip.id) { $0.opacity = newVal }
                }
            ) { newVal in
                editor.commitClipProperty(clipId: clip.id) { $0.opacity = newVal }
            }
        }
    }

    private var colorRow: some View {
        InspectorRow(icon: "paintpalette", label: "Color") {
            ColorField(
                displayColor: style.color.swiftUIColor,
                onUserChange: { new in
                    editor.debouncedCommitTextStyle(clipId: clip.id, key: "textColor") {
                        $0.color = TextStyle.RGBA(new)
                    }
                }
            )
        }
    }

    private var alignmentRow: some View {
        InspectorRow(icon: "text.alignleft", label: "Alignment") {
            Picker(
                "",
                selection: Binding(
                    get: { style.alignment },
                    set: { new in
                        editor.commitTextStyle(clipId: clip.id) { $0.alignment = new }
                    }
                )
            ) {
                Image(systemName: "text.alignleft").tag(TextStyle.Alignment.left)
                Image(systemName: "text.aligncenter").tag(TextStyle.Alignment.center)
                Image(systemName: "text.alignright").tag(TextStyle.Alignment.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.white.opacity(AppTheme.Opacity.strong))
            .fixedSize()
        }
    }

    private var backgroundToggleRow: some View {
        InspectorRow(icon: "rectangle.fill", label: "Pill") {
            HStack(spacing: AppTheme.Spacing.sm) {
                ColorField(
                    displayColor: style.background.color.swiftUIColor,
                    onUserChange: { new in
                        editor.debouncedCommitTextStyle(clipId: clip.id, key: "backgroundColor") {
                            $0.background.color = TextStyle.RGBA(new)
                        }
                    }
                )
                .opacity(style.background.enabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
                .disabled(!style.background.enabled)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { style.background.enabled },
                        set: { new in
                            editor.commitTextStyle(clipId: clip.id) { $0.background.enabled = new }
                            editor.fitTextClipToContent(clipId: clip.id)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.white.opacity(AppTheme.Opacity.strong))
            }
        }
    }

    private func backgroundMetricRow(
        icon: String,
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        refit: Bool,
        set: @escaping (inout TextStyle, Double) -> Void
    ) -> some View {
        InspectorRow(icon: icon, label: label) {
            ScrubbableNumberField(
                value: value,
                range: range,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: 50,
                onChanged: { newVal in
                    editor.applyTextStyle(clipId: clip.id) { set(&$0, newVal) }
                    if refit { editor.fitTextClipToContent(clipId: clip.id) }
                }
            ) { newVal in
                editor.commitTextStyle(clipId: clip.id) { set(&$0, newVal) }
                if refit { editor.fitTextClipToContent(clipId: clip.id) }
            }
        }
    }

    private var backgroundPaddingHRow: some View {
        backgroundMetricRow(
            icon: "arrow.left.and.right",
            label: "Padding H",
            value: style.background.paddingH,
            range: 0...1,
            refit: true,
            set: { $0.background.paddingH = $1 }
        )
    }

    private var backgroundPaddingVRow: some View {
        backgroundMetricRow(
            icon: "arrow.up.and.down",
            label: "Padding V",
            value: style.background.paddingV,
            range: 0...1,
            refit: true,
            set: { $0.background.paddingV = $1 }
        )
    }

    private var backgroundCornerRow: some View {
        backgroundMetricRow(
            icon: "rectangle.roundedtop",
            label: "Corner",
            value: style.background.cornerRadius,
            range: 0...0.6,
            refit: false,
            set: { $0.background.cornerRadius = $1 }
        )
    }

    private var backgroundPresetRow: some View {
        InspectorRow(icon: "wand.and.stars", label: "Preset") {
            HStack(spacing: AppTheme.Spacing.sm) {
                backgroundPresetButton(title: "IG Dark", preset: .instagramDark)
                backgroundPresetButton(title: "IG Light", preset: .instagramLight)
            }
        }
    }

    private func backgroundPresetButton(title: String, preset: TextStyle.Preset) -> some View {
        Button(title) {
            editor.commitTextStyle(clipId: clip.id) {
                $0.apply(preset)
            }
            editor.fitTextClipToContent(clipId: clip.id)
        }
        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var strokeRow: some View {
        toggleColorRow(
            icon: "a.square",
            label: "Stroke",
            enabled: style.border.enabled,
            color: style.border.color.swiftUIColor,
            debounceKey: "strokeColor",
            setEnabled: { $0.border.enabled = $1 },
            setColor: { $0.border.color = $1 },
            onEnabledChanged: { editor.fitTextClipToContent(clipId: clip.id) }
        )
    }

    private var strokeWidthRow: some View {
        InspectorRow(icon: "lineweight", label: "Thickness") {
            ScrubbableNumberField(
                value: style.border.width,
                range: TextStyle.Stroke.widthRange,
                format: "%.1f",
                valueSuffix: "%",
                fieldWidth: 50,
                onChanged: { newVal in
                    editor.applyTextStyle(clipId: clip.id) { $0.border.width = newVal }
                    editor.fitTextClipToContent(clipId: clip.id)
                }
            ) { newVal in
                editor.commitTextStyle(clipId: clip.id) { $0.border.width = newVal }
                editor.fitTextClipToContent(clipId: clip.id)
            }
        }
    }

    private func toggleColorRow(
        icon: String,
        label: String,
        enabled: Bool,
        color: Color,
        debounceKey: String,
        setEnabled: @escaping (inout TextStyle, Bool) -> Void,
        setColor: @escaping (inout TextStyle, TextStyle.RGBA) -> Void,
        onEnabledChanged: (() -> Void)? = nil
    ) -> some View {
        InspectorRow(icon: icon, label: label) {
            HStack(spacing: AppTheme.Spacing.sm) {
                ColorField(
                    displayColor: color,
                    onUserChange: { new in
                        editor.debouncedCommitTextStyle(clipId: clip.id, key: debounceKey) {
                            setColor(&$0, TextStyle.RGBA(new))
                        }
                    }
                )
                .opacity(enabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
                .disabled(!enabled)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { new in
                            editor.commitTextStyle(clipId: clip.id) { setEnabled(&$0, new) }
                            onEnabledChanged?()
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.white.opacity(AppTheme.Opacity.strong))
            }
        }
    }

    private var shadowRow: some View {
        toggleColorRow(
            icon: "square.on.square",
            label: "Shadow",
            enabled: style.shadow.enabled,
            color: style.shadow.color.swiftUIColor,
            debounceKey: "shadowColor",
            setEnabled: { $0.shadow.enabled = $1 },
            setColor: { $0.shadow.color = $1 }
        )
    }

    @ViewBuilder
    private var positionSection: some View {
        InspectorRow(icon: "arrow.up.and.down.and.arrow.left.and.right", label: "Position") {
            InspectorPositionFields(clips: [clip])
        }
    }
}
