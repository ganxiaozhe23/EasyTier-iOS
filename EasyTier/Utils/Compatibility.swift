import SwiftUI

#if os(iOS)
    let ToolbarLeading: ToolbarItemPlacement = {
        if #available(iOS 16.0, *) {
            return .topBarLeading
        }
        return .navigationBarLeading
    }()

    let ToolbarTrailing: ToolbarItemPlacement = {
        if #available(iOS 16.0, *) {
            return .topBarTrailing
        }
        return .navigationBarTrailing
    }()
#else
    let ToolbarLeading = ToolbarItemPlacement.navigation
    let ToolbarTrailing = ToolbarItemPlacement.primaryAction
#endif

struct AdaptiveNavigationRoot<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
#if os(iOS)
        if #available(iOS 16.0, *) {
            NavigationStack {
                content
            }
        } else {
            NavigationView {
                content
            }
            .navigationViewStyle(.stack)
        }
#else
        NavigationStack {
            content
        }
#endif
    }
}

struct AdaptiveLabeledContent<Content: View>: View {
    let label: LocalizedStringKey
    let content: () -> Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            LabeledContent(label) {
                content()
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer(minLength: 12)
                content()
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

extension AdaptiveLabeledContent where Content == Text {
    init(_ label: LocalizedStringKey, value: String) {
        self.init(label) {
            Text(value)
        }
    }
}

struct AdaptiveNavigationButton<Item: Hashable>: View {
    let title: LocalizedStringKey
    let value: Item
    @Binding var selection: Item?

    init(_ title: LocalizedStringKey, value: Item, selection: Binding<Item?>) {
        self.title = title
        self.value = value
        _selection = selection
    }

    var body: some View {
        Button {
            selection = value
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selection == value {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func decimalKeyboardType() -> some View {
#if os(iOS)
        return self.keyboardType(.decimalPad)
#else
        return self
#endif
    }
    
    func numberKeyboardType() -> some View {
#if os(iOS)
        return self.keyboardType(.numberPad)
#else
        return self
#endif
    }
    
    func adaptiveNavigationBarTitleInline() -> some View {
#if os(iOS)
        return self.navigationBarTitleDisplayMode(.inline)
#else
        return self
#endif
    }
    
    func adaptiveNoTextInputAutocapitalization() -> some View {
#if os(iOS)
        return self.textInputAutocapitalization(.never)
#else
        return self
#endif
    }

    @ViewBuilder
    func adaptiveScrollDismissesKeyboardImmediately() -> some View {
#if os(iOS)
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
#else
        self
#endif
    }

    @ViewBuilder
    func adaptiveGroupedFormStyle() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.formStyle(.grouped)
        } else {
            self
        }
    }
}
