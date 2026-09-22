//
//  HTTPMethodPicker.swift
//  devkit
//
//  M2：请求方法选择器。常态下是一整块按钮，点击从按钮下沿弹出预设列表；
//  选项与按钮同款外形（圆角块 + 等宽粗体居中），按方法着色，展开 / 收起淡入淡出。
//  预设之外的方法通过列表底部“自定义…”入口录入：按钮原地变成输入框，回车 / 失焦落定、Esc 取消。
//
//  不用系统 Menu：其条目样式无法自定义，且 `.borderlessButton` 会自动再画一个向下箭头，
//  与自绘的 chevron 叠加成“两个箭头”。
//

import SwiftUI

/// 按钮与选项共用的尺寸：选项要和按钮长得一样，宽度 / 圆角必须对齐。
private enum HTTPMethodLayout {
    static let width: CGFloat = 102
    static let height: CGFloat = 34
    static let fieldWidth: CGFloat = 66
    static let chevronWidth: CGFloat = 18
    static let cornerRadius: CGFloat = 8
    static let itemHeight: CGFloat = 30
    static let itemSpacing: CGFloat = 4
    static let panelPadding: CGFloat = 6
    static let gapBelowButton: CGFloat = 4
    /// 收起挡板的尺寸：远大于窗口即可，SwiftUI 没有窗口级“点击外部”API。
    static let scrimSize: CGFloat = 4_000
}

struct HTTPMethodPicker: View {
    @Binding var method: String
    var presets: [HTTPMethodPreset] = HTTPMethodPreset.allCases

    @State private var isPresented = false
    /// 按钮态 / 自定义录入态。
    @State private var isEditingMethod = false
    /// 录入态的草稿；落定时归一化（去空白 + 大写）写回 `method`。
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            if isEditingMethod {
                editor
            } else {
                button
            }
        }
        .background(scrim)
        .overlay(alignment: .top) { panel }
    }

    // MARK: - 触发按钮

    /// 整块可点：文字只展示不可编辑，点击即展开 / 收起预设列表。
    private var button: some View {
        HStack(spacing: 2) {
            Text(method.isEmpty ? "方法" : method)
                .font(.body.monospaced().weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: HTTPMethodLayout.fieldWidth)
                .multilineTextAlignment(.center)

            chevron
        }
        .padding(.horizontal, 8)
        .frame(width: HTTPMethodLayout.width, height: HTTPMethodLayout.height)
        .background(chipBackground(tint.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .animation(Theme.Motion.micro, value: isPresented)
        .animation(Theme.Motion.micro, value: method)
    }

    /// 自定义录入态：与按钮同尺寸，回车或失去焦点落定，Esc 放弃。
    private var editor: some View {
        HStack(spacing: 2) {
            TextField("方法", text: $draft)
                .textFieldStyle(.plain)
                .font(.body.monospaced().weight(.semibold))
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                .onSubmit(commitDraft)
                .frame(width: HTTPMethodLayout.fieldWidth)

            Image(systemName: "return")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: HTTPMethodLayout.chevronWidth)
        }
        .padding(.horizontal, 8)
        .frame(width: HTTPMethodLayout.width, height: HTTPMethodLayout.height)
        .background(chipBackground(tint.opacity(0.18)))
        .onExitCommand { cancelEdit() }
        // 失焦（点外部 / Tab 走）即落定，与“回车”同一出口。
        .onChange(of: fieldFocused) { _, focused in
            if !focused && isEditingMethod { commitDraft() }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isPresented ? 180 : 0))
            .frame(width: HTTPMethodLayout.chevronWidth)
    }

    private func chipBackground(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: HTTPMethodLayout.cornerRadius)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: HTTPMethodLayout.cornerRadius)
                    .strokeBorder(tint.opacity(isEditingMethod ? 0.65 : 0), lineWidth: 1)
            )
    }

    /// 当前方法的强调色；自定义 / 空方法回落到次要色。
    private var tint: Color { HTTPDisplay.color(forMethod: method) }

    // MARK: - 弹层

    /// 挂在按钮下沿的预设列表。`if` + transition 即渐入渐出。
    /// overlay 以按钮顶边为基准，故用一个与按钮等高的透明占位把列表顶到按钮下方。
    @ViewBuilder
    private var panel: some View {
        if isPresented {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: HTTPMethodLayout.height + HTTPMethodLayout.gapBelowButton)

                VStack(spacing: HTTPMethodLayout.itemSpacing) {
                    ForEach(presets) { preset in
                        HTTPMethodItem(
                            preset: preset,
                            isSelected: preset.rawValue == method.uppercased(),
                            action: { select(preset) }
                        )
                    }

                    Divider()
                        .padding(.vertical, 2)

                    Button(action: beginEdit) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.pencil")
                            Text("自定义…")
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(HTTPMethodLayout.panelPadding)
                .frame(width: HTTPMethodLayout.width + HTTPMethodLayout.panelPadding * 2)
                .background(panelBackground)
                .transition(Theme.Transitions.dropdown)
            }
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: HTTPMethodLayout.cornerRadius + 3)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: HTTPMethodLayout.cornerRadius + 3)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: Theme.Palette.dragShadow, radius: 8, x: 0, y: 4)
    }

    /// 透明挡板：吃掉弹层之外的点击，点任意处即收起。
    @ViewBuilder
    private var scrim: some View {
        if isPresented {
            Color.clear
                .frame(width: HTTPMethodLayout.scrimSize, height: HTTPMethodLayout.scrimSize)
                .contentShape(Rectangle())
                .onTapGesture { close() }
        }
    }

    // MARK: - 交互

    private func toggle() {
        withAnimation(Theme.Motion.content) { isPresented.toggle() }
    }

    private func select(_ preset: HTTPMethodPreset) {
        withAnimation(Theme.Motion.content) {
            method = preset.rawValue
            isPresented = false
        }
    }

    private func close() {
        guard isPresented else { return }
        withAnimation(Theme.Motion.content) { isPresented = false }
    }

    /// 进入自定义方法录入：收起弹层，按钮原地换成输入框并抢焦点。
    private func beginEdit() {
        withAnimation(Theme.Motion.content) {
            isPresented = false
            draft = method
            isEditingMethod = true
        }
        DispatchQueue.main.async { fieldFocused = true }
    }

    /// 落定：HTTP 方法按惯例归一化为大写；空草稿保留原值。
    private func commitDraft() {
        guard isEditingMethod else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        withAnimation(Theme.Motion.content) {
            if !value.isEmpty { method = value }
            fieldFocused = false
            isEditingMethod = false
        }
    }

    /// 放弃录入，不回写草稿。
    private func cancelEdit() {
        guard isEditingMethod else { return }
        withAnimation(Theme.Motion.content) {
            fieldFocused = false
            isEditingMethod = false
        }
    }
}

/// 弹层中的单个方法选项：与触发按钮同款的着色圆角块，仅颜色随方法变化。
private struct HTTPMethodItem: View {
    let preset: HTTPMethodPreset
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var color: Color { HTTPDisplay.color(forMethod: preset.rawValue) }

    var body: some View {
        Text(preset.label)
            .font(.body.monospaced().weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .frame(height: HTTPMethodLayout.itemHeight)
            .background(
                RoundedRectangle(cornerRadius: HTTPMethodLayout.cornerRadius)
                    .fill(color.opacity(isHovering ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HTTPMethodLayout.cornerRadius)
                    .strokeBorder(color.opacity(isSelected ? 0.65 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { isHovering = $0 }
            .animation(Theme.Motion.micro, value: isHovering)
            .animation(Theme.Motion.micro, value: isSelected)
    }
}

#Preview {
    HTTPMethodPicker(method: .constant("GET"))
        .padding(40)
        .frame(width: 600, height: 400)
}
