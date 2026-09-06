//
//  ETOS_Agent_WidgetsBundle.swift
//  ETOS Agent Widgets
//
//  Created by Eric on 2026/8/11.
//

import WidgetKit
import SwiftUI

@main
struct ETOS_Agent_WidgetsBundle: WidgetBundle {
    var body: some Widget {
        ETOSNewAgentWidget()
        ETOSRecentTasksWidget()
        ETOSDailyPulseWidget()
        ETOS_Agent_WidgetsLiveActivity()
    }
}
