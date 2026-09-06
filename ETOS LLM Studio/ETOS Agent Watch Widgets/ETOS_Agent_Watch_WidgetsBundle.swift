// ============================================================================
// ETOS_Agent_Watch_WidgetsBundle.swift
// ETOS Agent Watch Widgets
// ============================================================================

import WidgetKit
import SwiftUI

@main
struct ETOS_Agent_Watch_WidgetsBundle: WidgetBundle {
    var body: some Widget {
        ETOSWatchNewAgentWidget()
        ETOSWatchRecentTaskWidget()
        ETOSWatchDailyPulseWidget()
    }
}
