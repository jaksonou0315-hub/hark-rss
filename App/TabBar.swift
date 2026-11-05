import SwiftUI

enum HarkTab: Int, CaseIterable, Identifiable {
    case timeline, starred, later, sources, settings
    var id: Int { rawValue }
    var title: String { ["时间线", "收藏", "稍后读", "订阅", "设置"][rawValue] }
    var icon: String {
        ["antenna.radiowaves.left.and.right", "star", "clock", "list.bullet.rectangle", "gearshape"][rawValue]
    }
    var selectedIcon: String {
        ["antenna.radiowaves.left.and.right", "star.fill", "clock.fill", "list.bullet.rectangle.fill", "gearshape.fill"][rawValue]
    }
    var tint: Color { [Color.blue, .orange, .purple, .teal, .indigo][rawValue] }
}

/// Shared state of the floating tab bar.
final class TabBarState: ObservableObject {
    static let shared = TabBarState()
    @Published var collapsed = UserDefaults.standard.bool(forKey: "HarkBarCollapsed")
    @Published var actionsOpen = UserDefaults.standard.bool(forKey: "HarkActions")
}

/// Floating Liquid Glass tab bar.
/// - The selected tab expands to show its label; the others shrink to icons.
/// - Scrolling down collapses the bar into one pill; tap or swipe up to expand again.
/// - The + button morphs out a glass quick-action panel.
struct ExpandableTabBar: View {
    @Binding var selection: Int
    @EnvironmentObject var store: FeedStore
    @ObservedObject private var state = TabBarState.shared
    @Namespace private var ns

    private var current: HarkTab { HarkTab(rawValue: selection) ?? .timeline }
    private var unread: Int { store.unreadTotal }

    var body: some View {
        GlassGroup(spacing: 16) {
            VStack(alignment: .trailing, spacing: 10) {
                if state.actionsOpen {
                    actionsPanel
                        .transition(.scale(scale: 0.4, anchor: .bottomTrailing).combined(with: .opacity))
                }
                MiniPlayerBar()
                HStack(spacing: 10) {
                    if state.collapsed {
                        collapsedPill
                        Spacer(minLength: 0)
                    } else {
                        tabsCapsule
                    }
                    actionButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: state.collapsed)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: state.actionsOpen)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: selection)
    }

    // MARK: Expanded bar

    private var tabsCapsule: some View {
        HStack(spacing: 0) {
            ForEach(HarkTab.allCases) { t in
                tabButton(t)
                if t != HarkTab.allCases.last { Spacer(minLength: 0) }
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .glass(in: Capsule())
        .glassID("bar", ns)
        .gesture(DragGesture(minimumDistance: 16).onEnded { v in
            if v.translation.height > 16 { state.collapsed = true }
        })
    }

    private func tabButton(_ t: HarkTab) -> some View {
        let on = t.rawValue == selection
        return Button {
            state.actionsOpen = false
            selection = t.rawValue
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? t.selectedIcon : t.icon)
                    .font(.system(size: 17, weight: on ? .semibold : .regular))
                    .symbolRenderingMode(.hierarchical)
                    .overlay(alignment: .topTrailing) {
                        if t == .timeline && unread > 0 && !on {
                            Circle().fill(.red).frame(width: 8, height: 8).offset(x: 4, y: -2)
                        }
                    }
                if on {
                    Text(t.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                    if t == .timeline && unread > 0 {
                        Text(unread > 999 ? "999+" : "\(unread)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.red))
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
            }
            .foregroundStyle(on ? t.tint : Color.primary.opacity(0.72))
            .padding(.horizontal, on ? 14 : 12)
            .frame(height: 46)
            .background {
                if on {
                    Capsule().fill(t.tint.opacity(0.18))
                        .overlay(Capsule().stroke(t.tint.opacity(0.25), lineWidth: 0.6))
                        .matchedGeometryEffect(id: "selection", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Collapsed bar

    private var collapsedPill: some View {
        Button { state.collapsed = false } label: {
            HStack(spacing: 8) {
                Image(systemName: current.selectedIcon)
                    .font(.system(size: 17, weight: .semibold))
                Text(current.title).font(.subheadline.weight(.semibold))
                if current == .timeline && unread > 0 {
                    Text("\(min(unread, 999))")
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                }
                Image(systemName: "chevron.up").font(.caption2.weight(.bold)).opacity(0.55)
            }
            .foregroundStyle(current.tint)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(in: Capsule(), interactive: true)
        .glassID("bar", ns)
        .gesture(DragGesture(minimumDistance: 10).onEnded { v in
            if v.translation.height < -10 { state.collapsed = false }
        })
        .accessibilityLabel("展开标签栏，当前：\(current.title)")
    }

    // MARK: Quick actions

    private var actionButton: some View {
        Button { state.actionsOpen.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .semibold))
                .rotationEffect(.degrees(state.actionsOpen ? 45 : 0))
                .foregroundStyle(state.actionsOpen ? current.tint : Color.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle(), tint: state.actionsOpen ? current.tint.opacity(0.25) : nil, interactive: true)
        .glassID("action", ns)
        .accessibilityLabel(state.actionsOpen ? "收起快捷操作" : "快捷操作")
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("快捷操作")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            action("刷新全部订阅", store.loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise", .blue) {
                Task { await store.refresh() }
            }
            action("全部标为已读", "checkmark.circle", .green) { store.markAllRead(store.items) }
            action("添加订阅", "plus.circle", .teal) {
                selection = HarkTab.sources.rawValue
                store.requestAddSource = true
            }
            action(state.collapsed ? "展开标签栏" : "收起标签栏",
                   state.collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical", .indigo) {
                state.collapsed.toggle()
            }
        }
        .padding(8)
        .frame(width: 236, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .glassID("panel", ns)
    }

    private func action(_ title: String, _ icon: String, _ c: Color, _ run: @escaping () -> Void) -> some View {
        Button {
            run()
            state.actionsOpen = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(c)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(c.opacity(0.16)))
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
