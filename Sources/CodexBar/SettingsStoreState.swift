import Foundation

struct SettingsDefaultsState {
    var refreshFrequency: RefreshFrequency
    var adaptiveActivityScanConsent: AdaptiveActivityScanConsent
    var refreshAllProvidersOnMenuOpen: Bool
    var launchAtLogin: Bool
    var debugMenuEnabled: Bool
    var debugDisableKeychainAccess: Bool
    var debugFileLoggingEnabled: Bool
    var debugLogLevelRaw: String?
    var debugLoadingPatternRaw: String?
    var debugKeepCLISessionsAlive: Bool
    var statusChecksEnabled: Bool
    var sessionQuotaNotificationsEnabled: Bool
    var quotaWarningNotificationsEnabled: Bool
    var predictivePaceWarningNotificationsEnabled: Bool
    var quotaWarningThresholdsRaw: [Int]
    var quotaWarningSessionThresholdsRaw: [Int]
    var quotaWarningWeeklyThresholdsRaw: [Int]
    var quotaWarningSessionEnabled: Bool
    var quotaWarningWeeklyEnabled: Bool
    var quotaWarningSoundEnabled: Bool
    var quotaWarningOnScreenAlertEnabled: Bool
    var quotaWarningMarkersVisible: Bool
    var paceVisible: Bool
    var weeklyProgressWorkDays: Int?
    var workdayTickAppearanceRaw: String
    var usageBarsShowUsed: Bool
    var resetTimesShowAbsolute: Bool
    var providerChangelogLinksEnabled: Bool
    var menuBarShowsBrandIconWithPercent: Bool
    var menuBarHidesCritters: Bool
    var menuBarHighContrastOnInactiveDisplays: Bool
    var menuBarDisplayModeRaw: String?
    var menuBarShowsResetTimeWhenExhausted: Bool
    var kiroMenuBarDisplayModeRaw: String?
    var historicalTrackingEnabled: Bool
    var multiAccountMenuLayoutRaw: String
    var menuBarMetricPreferencesRaw: [String: String]
    var storedMenuBarLayout: MenuBarLayout?
    var menuBarLayoutConditionals: [MenuBarLayoutConditional]
    var menuBarLayoutOverridesRaw: [String: MenuBarLayout]
    var menuBarLayoutSizeRaw: String
    var menuBarLayoutGapRaw: String
    var menuBarLayoutVerticalAdjustment: Int
    var copilotBudgetExtrasEnabled: Bool
    var copilotIconSecondaryWindowIDRaw: String
    var costUsageEnabled: Bool
    var codexLocalSessionCostLedgerEnabled: Bool
    var costUsageHistoryDays: Int
    var costUsageBucketTimeZoneIdentifier: String
    var openCodexUsageLogsEnabled: Bool
    var hideNativeCodexCostWhenOpenCodexPresent: Bool
    var spendDashboardHiddenSourceIDs: [String]
    var costComparisonPeriodsEnabled: Bool
    var costSummaryDisplayStyleRaw: String
    var hidePersonalInfo: Bool
    var randomBlinkEnabled: Bool
    var confettiOnSessionLimitResetsEnabled: Bool
    var confettiOnWeeklyLimitResetsEnabled: Bool
    var menuBarShowsHighestUsage: Bool
    var claudeOAuthKeychainPromptModeRaw: String?
    var claudeOAuthKeychainReadStrategyRaw: String?
    var claudeOAuthDirectKeychainReadAllowed: Bool
    var claudeWebExtrasEnabledRaw: Bool
    var showOptionalCreditsAndExtraUsage: Bool
    var claudeDailyRoutinesUsageVisible: Bool
    var claudeModelScopedWeeklyUsageVisible: Bool
    var codexSparkUsageVisible: Bool
    var codexExternalOAuthSourcesAllowed: Bool
    var openAIWebAccessEnabled: Bool
    var openAIWebBatterySaverEnabled: Bool
    var backgroundWorkLowPowerModePreference: LowPowerModePreference
    var providerStorageFootprintsEnabled: Bool
    var jetbrainsIDEBasePath: String
    var mergeIcons: Bool
    var switcherShowsIcons: Bool
    var mergedMenuLastSelectedWasOverview: Bool
    var mergedOverviewSelectedProvidersRaw: [String]
    var selectedMenuProviderRaw: String?
    var providerDetectionCompleted: Bool
    var providersSortedAlphabetically: Bool
    var appLanguageRaw: String?
    var terminalAppRaw: String?
    var agentSessionsEnabled: Bool
    var agentSessionLabelStyleRaw: String
    var agentSessionsManualHosts: String
    var preferredCurrencyCode: String
    var iCloudSyncEnabled: Bool
    var iCloudSyncIncludeSecrets: Bool
    var iCloudSyncSnapshotsEnabled: Bool
    var iCloudSyncShowFleetAccounts: Bool
    var iCloudSyncDeviceID: String
    var notify: NotifyDefaultsState
}

/// The Notify! settings, grouped so one field carries them all into
/// `SettingsDefaultsState` rather than a dozen.
///
/// The device token is deliberately absent: it lives in the Keychain, never in
/// defaults. So are these values from `SyncedPreferences`, which is an explicit
/// allow-list — the three handles name tiles this Mac created, and a second Mac
/// adopting them would have two publishers writing one Live Activity.
struct NotifyDefaultsState {
    /// Off until the user links a device. A feature that talks to someone
    /// else's server cannot ship enabled.
    var enabled: Bool
    var deviceID: String

    /// The four surfaces, each switchable alone, because they fail for
    /// different reasons: a Mac link cannot start a tile but keeps its widgets
    /// happily, and a Home Screen widget can be refused by a server-side kill
    /// switch while the other two are being served.
    var liveActivityEnabled: Bool
    var widgetEnabled: Bool
    var screenWidgetEnabled: Bool
    var notificationsEnabled: Bool

    /// Which provider instances may fill the tile's six metric slots. Empty
    /// means automatic, and severity decides.
    var instanceSelectionRaw: [String]

    /// Which single window the Lock Screen gauge shows. Both empty means
    /// whichever quota needs attention most.
    var gaugeInstanceID: String
    var gaugeQuotaKey: String

    /// The handles of the tile and widgets CodexBar created, so every write
    /// after the first addresses its own rather than upserting over whatever
    /// the user last started from another script.
    var activityID: String
    var widgetID: String
    var screenWidgetID: String
}
