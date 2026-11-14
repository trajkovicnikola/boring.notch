//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Pomodoro", icon: "stopwatch.fill", view: .pomodoro)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var shelfState = ShelfStateViewModel.shared
    @Namespace var animation
    @Default(.boringShelf) private var boringShelf
    @Default(.showPomodoroTab) private var showPomodoroTab

    private var visibleTabs: [TabModel] {
        Self.visibleTabs(
            shelfEnabled: boringShelf,
            shelfIsEmpty: shelfState.isEmpty,
            alwaysShowTabs: coordinator.alwaysShowTabs,
            showPomodoroTab: showPomodoroTab
        )
    }

    /// The shelf tab keeps its original rule (enabled, and either has items
    /// or "always show tabs" is on); the Pomodoro tab follows its own
    /// setting. The header only shows the bar when there's more than Home.
    static func visibleTabs(
        shelfEnabled: Bool,
        shelfIsEmpty: Bool,
        alwaysShowTabs: Bool,
        showPomodoroTab: Bool
    ) -> [TabModel] {
        tabs.filter { tab in
            switch tab.view {
            case .home: true
            case .shelf: shelfEnabled && (!shelfIsEmpty || alwaysShowTabs)
            case .pomodoro: showPomodoroTab
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}
