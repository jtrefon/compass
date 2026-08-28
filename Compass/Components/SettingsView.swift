//
//  SettingsView.swift
//  Compass
//
//  Created by AI Assistant on 20/12/2025.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var ui: UIStateManager
    @StateObject private var openRouterViewModel = OpenRouterSettingsViewModel()
    @StateObject private var alibabaViewModel = OpenRouterSettingsViewModel(
        store: AlibabaSettingsStore(),
        providerDisplayName: "Alibaba Cloud"
    )
    @StateObject private var kiloCodeViewModel = OpenRouterSettingsViewModel(
        store: KiloCodeSettingsStore(),
        providerDisplayName: "Kilo Code"
    )
    @StateObject private var deepSeekViewModel = OpenRouterSettingsViewModel(
        store: DeepSeekSettingsStore(),
        providerDisplayName: "DeepSeek"
    )
    @StateObject private var openCodeGoViewModel = OpenRouterSettingsViewModel(
        store: OpenCodeGoSettingsStore(),
        providerDisplayName: "OpenCode Go"
    )
    @StateObject private var openCodeGoSubscriptionViewModel = OpenRouterSettingsViewModel(
        store: OpenCodeGoSubscriptionSettingsStore(),
        providerDisplayName: "OpenCode Go (Subscription)"
    )
    @StateObject private var customEndpointViewModel = OpenRouterSettingsViewModel(
        store: CustomEndpointSettingsStore(),
        providerDisplayName: "Custom Endpoint"
    )
    @StateObject private var providerSelectionViewModel = AIProviderSelectionViewModel()
    @StateObject private var localModelViewModel = LocalModelSettingsViewModel()


    var body: some View {
        ZStack {
            // Native Glass Background Effects
            SettingsBackgroundView()

            VStack(spacing: AppConstants.Settings.cardPadding) {
                TabView {
                    GeneralSettingsTab(ui: ui)
                        .tabItem {
                            Label(localized("settings.tabs.general"), systemImage: "gearshape")
                        }

                        AISettingsTab(
                            openRouterViewModel: openRouterViewModel,
                            alibabaViewModel: alibabaViewModel,
                            kiloCodeViewModel: kiloCodeViewModel,
                            deepSeekViewModel: deepSeekViewModel,
                            openCodeGoViewModel: openCodeGoViewModel,
                            openCodeGoSubscriptionViewModel: openCodeGoSubscriptionViewModel,
                            customEndpointViewModel: customEndpointViewModel,
                            providerSelectionViewModel: providerSelectionViewModel,
                            localModelViewModel: localModelViewModel
                        )
                        .tabItem {
                            Label(localized("settings.tabs.ai"), systemImage: "sparkles")
                        }

                    AgentSettingsTab(ui: ui)
                        .tabItem {
                            Label(localized("settings.tabs.agent"), systemImage: "bolt.fill")
                        }

                    LanguageModulesTab()
                        .tabItem {
                            Label(localized("settings.tabs.modules"), systemImage: "puzzlepiece")
                        }
                }
            }
            .padding(AppConstants.Layout.spacingXL)
        }
        .frame(
            minWidth: AppConstants.Settings.windowMinWidth,
            idealWidth: AppConstants.Settings.windowIdealWidth,
            minHeight: AppConstants.Settings.windowMinHeight,
            idealHeight: AppConstants.Settings.windowIdealHeight
        )
    }
}

private struct SettingsBackgroundView: View {
    var body: some View {
        Color.clear
            .nativeGlassBackground(.sheet, cornerRadius: 0)
            .ignoresSafeArea()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(ui: DependencyContainer().makeAppState().ui)
    }
}
