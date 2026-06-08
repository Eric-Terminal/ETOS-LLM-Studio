// ============================================================================
// MCPBuiltInPersonalDataEventKit.swift
// ============================================================================
// ETOS LLM Studio
//
// EventKit 日历与提醒事项执行器。读取和写入都只在工具调用时申请权限。
// ============================================================================

import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif

actor MCPBuiltInPersonalDataEventKitExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(EventKit)
        switch toolName {
        case "calendar.query_events":
            return try await queryEvents(arguments: arguments)
        case "calendar.create_event":
            return try await createEvent(arguments: arguments)
        case "calendar.update_event":
            return try await updateEvent(arguments: arguments)
        case "calendar.delete_event":
            return try await deleteEvent(arguments: arguments)
        case "reminder.query_reminders":
            return try await queryReminders(arguments: arguments)
        case "reminder.create_reminder":
            return try await createReminder(arguments: arguments)
        case "reminder.update_reminder":
            return try await updateReminder(arguments: arguments)
        case "reminder.delete_reminder":
            return try await deleteReminder(arguments: arguments)
        default:
            throw MCPBuiltInPersonalDataError.unsupportedTool(toolName)
        }
        #else
        throw MCPBuiltInPersonalDataError.unavailable(NSLocalizedString("当前平台没有 EventKit。", comment: "EventKit unavailable"))
        #endif
    }
}

#if canImport(EventKit)
private extension MCPBuiltInPersonalDataEventKitExecutor {
    var store: EKEventStore {
        EKEventStore()
    }

    func queryEvents(arguments: [String: Any]) async throws -> [String: Any] {
        let startDate = try arguments.personalDataRequiredDate("start_date")
        let endDate = try arguments.personalDataRequiredDate("end_date")
        let store = self.store
        try await requestEventAccess(store: store, writeOnlyAllowed: false)
        let calendars = try eventCalendars(from: arguments, store: store)
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(eventPayload)

        return [
            "provider": "etos_builtin_personal_data",
            "tool_name": "calendar.query_events",
            "start_date": MCPBuiltInPersonalDataDateCodec.string(startDate) ?? "",
            "end_date": MCPBuiltInPersonalDataDateCodec.string(endDate) ?? "",
            "events": events,
            "count": events.count
        ]
    }

    func createEvent(arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(NSLocalizedString("watchOS 不支持通过 EventKit 写入日历事件。", comment: "watchOS EventKit write unsupported"))
        #else
        let title = try arguments.personalDataRequiredString("title")
        let startDate = try arguments.personalDataRequiredDate("start_date")
        let endDate = try arguments.personalDataRequiredDate("end_date")
        let store = self.store
        try await requestEventAccess(store: store, writeOnlyAllowed: true)

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        try applyEventFields(event, arguments: arguments, store: store)
        try store.save(event, span: .thisEvent, commit: true)

        return writeResult(toolName: "calendar.create_event", itemKey: "event", payload: eventPayload(event))
        #endif
    }

    func updateEvent(arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(NSLocalizedString("watchOS 不支持通过 EventKit 写入日历事件。", comment: "watchOS EventKit write unsupported"))
        #else
        let eventID = try arguments.personalDataRequiredString("event_id")
        let store = self.store
        try await requestEventAccess(store: store, writeOnlyAllowed: false)
        guard let event = store.event(withIdentifier: eventID) else {
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("找不到指定日历事件。", comment: "Event not found"))
        }

        if let title = arguments.personalDataString("title"), !title.isEmpty {
            event.title = title
        }
        if let startDate = try arguments.personalDataDate("start_date") {
            event.startDate = startDate
        }
        if let endDate = try arguments.personalDataDate("end_date") {
            event.endDate = endDate
        }
        try applyEventFields(event, arguments: arguments, store: store)
        try store.save(event, span: .thisEvent, commit: true)

        return writeResult(toolName: "calendar.update_event", itemKey: "event", payload: eventPayload(event))
        #endif
    }

    func deleteEvent(arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(NSLocalizedString("watchOS 不支持通过 EventKit 删除日历事件。", comment: "watchOS EventKit delete unsupported"))
        #else
        let eventID = try arguments.personalDataRequiredString("event_id")
        let store = self.store
        try await requestEventAccess(store: store, writeOnlyAllowed: false)
        guard let event = store.event(withIdentifier: eventID) else {
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("找不到指定日历事件。", comment: "Event not found"))
        }
        let payload = eventPayload(event)
        let span: EKSpan = arguments.personalDataBool("future_events") == true ? .futureEvents : .thisEvent
        try store.remove(event, span: span, commit: true)

        return writeResult(toolName: "calendar.delete_event", itemKey: "deleted_event", payload: payload)
        #endif
    }

    func queryReminders(arguments: [String: Any]) async throws -> [String: Any] {
        let store = self.store
        try await requestReminderAccess(store: store)
        let calendars = try reminderCalendars(from: arguments, store: store)
        let predicate = store.predicateForReminders(in: calendars)
        let reminders = try await fetchReminders(store: store, predicate: predicate)
        let completedFilter = arguments.personalDataBool("completed")
        let startDate = try arguments.personalDataDate("start_date")
        let endDate = try arguments.personalDataDate("end_date")
        let filtered = reminders
            .filter { reminder in
                if let completedFilter, reminder.isCompleted != completedFilter {
                    return false
                }
                guard startDate != nil || endDate != nil else { return true }
                guard let dueDate = reminder.dueDateComponents?.date else { return false }
                if let startDate, dueDate < startDate { return false }
                if let endDate, dueDate > endDate { return false }
                return true
            }
            .sorted {
                ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
            }
            .map(reminderPayload)

        return [
            "provider": "etos_builtin_personal_data",
            "tool_name": "reminder.query_reminders",
            "reminders": filtered,
            "count": filtered.count
        ]
    }

    func createReminder(arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(NSLocalizedString("watchOS 不支持通过 EventKit 写入提醒事项。", comment: "watchOS EventKit reminder write unsupported"))
        #else
        let title = try arguments.personalDataRequiredString("title")
        let store = self.store
        try await requestReminderAccess(store: store)
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        try applyReminderFields(reminder, arguments: arguments, store: store)
        try store.save(reminder, commit: true)
        return writeResult(toolName: "reminder.create_reminder", itemKey: "reminder", payload: reminderPayload(reminder))
        #endif
    }

    func updateReminder(arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(NSLocalizedString("watchOS 不支持通过 EventKit 写入提醒事项。", comment: "watchOS EventKit reminder write unsupported"))
        #else
        let reminderID = try arguments.personalDataRequiredString("reminder_id")
        let store = self.store
        try await requestReminderAccess(store: store)
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("找不到指定提醒事项。", comment: "Reminder not found"))
        }
        if let title = arguments.personalDataString("title"), !title.isEmpty {
            reminder.title = title
        }
        try applyReminderFields(reminder, arguments: arguments, store: store)
        try store.save(reminder, commit: true)
        return writeResult(toolName: "reminder.update_reminder", itemKey: "reminder", payload: reminderPayload(reminder))
        #endif
    }

    func deleteReminder(arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(NSLocalizedString("watchOS 不支持通过 EventKit 删除提醒事项。", comment: "watchOS EventKit reminder delete unsupported"))
        #else
        let reminderID = try arguments.personalDataRequiredString("reminder_id")
        let store = self.store
        try await requestReminderAccess(store: store)
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("找不到指定提醒事项。", comment: "Reminder not found"))
        }
        let payload = reminderPayload(reminder)
        try store.remove(reminder, commit: true)
        return writeResult(toolName: "reminder.delete_reminder", itemKey: "deleted_reminder", payload: payload)
        #endif
    }

    func requestEventAccess(store: EKEventStore, writeOnlyAllowed: Bool) async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return
        case .writeOnly where writeOnlyAllowed:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            if granted { return }
            throw MCPBuiltInPersonalDataError.permissionDenied(NSLocalizedString("用户未授予日历访问权限。", comment: "Calendar permission denied"))
        case .restricted:
            throw MCPBuiltInPersonalDataError.permissionDenied(NSLocalizedString("日历访问被系统限制。", comment: "Calendar access restricted"))
        case .denied, .writeOnly:
            throw MCPBuiltInPersonalDataError.permissionDenied(NSLocalizedString("日历访问权限不足。", comment: "Calendar permission insufficient"))
        @unknown default:
            throw MCPBuiltInPersonalDataError.permissionDenied(NSLocalizedString("未知日历权限状态。", comment: "Unknown calendar permission"))
        }
    }

    func requestReminderAccess(store: EKEventStore) async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            if granted { return }
            throw MCPBuiltInPersonalDataError.permissionDenied(NSLocalizedString("用户未授予提醒事项访问权限。", comment: "Reminder permission denied"))
        case .restricted:
            throw MCPBuiltInPersonalDataError.permissionDenied(NSLocalizedString("提醒事项访问被系统限制。", comment: "Reminder access restricted"))
        case .denied, .writeOnly:
            throw MCPBuiltInPersonalDataError.permissionDenied(NSLocalizedString("提醒事项访问权限不足。", comment: "Reminder permission insufficient"))
        @unknown default:
            throw MCPBuiltInPersonalDataError.permissionDenied(NSLocalizedString("未知提醒事项权限状态。", comment: "Unknown reminder permission"))
        }
    }

    func eventCalendars(from arguments: [String: Any], store: EKEventStore) throws -> [EKCalendar]? {
        guard let calendarID = arguments.personalDataString("calendar_id"), !calendarID.isEmpty else { return nil }
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("找不到指定日历。", comment: "Calendar not found"))
        }
        return [calendar]
    }

    func reminderCalendars(from arguments: [String: Any], store: EKEventStore) throws -> [EKCalendar]? {
        guard let calendarID = arguments.personalDataString("calendar_id"), !calendarID.isEmpty else { return nil }
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("找不到指定提醒事项列表。", comment: "Reminder calendar not found"))
        }
        return [calendar]
    }

    #if !os(watchOS)
    func applyEventFields(_ event: EKEvent, arguments: [String: Any], store: EKEventStore) throws {
        if let calendarID = arguments.personalDataString("calendar_id"), !calendarID.isEmpty {
            guard let calendar = store.calendar(withIdentifier: calendarID) else {
                throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("找不到指定日历。", comment: "Calendar not found"))
            }
            event.calendar = calendar
        } else if event.calendar == nil {
            guard let defaultCalendar = store.defaultCalendarForNewEvents else {
                throw MCPBuiltInPersonalDataError.unavailable(NSLocalizedString("没有可用于新事件的默认日历。", comment: "No default calendar"))
            }
            event.calendar = defaultCalendar
        }
        if let location = arguments.personalDataString("location") {
            event.location = location
        }
        if let notes = arguments.personalDataString("notes") {
            event.notes = notes
        }
        if let minutes = arguments.personalDataDouble("alarm_minutes_before") {
            event.alarms = [EKAlarm(relativeOffset: -minutes * 60)]
        }
        if let recurrence = arguments.personalDataString("recurrence"), !recurrence.isEmpty {
            event.recurrenceRules = [try recurrenceRule(for: recurrence)]
        }
    }

    func applyReminderFields(_ reminder: EKReminder, arguments: [String: Any], store: EKEventStore) throws {
        if let calendarID = arguments.personalDataString("calendar_id"), !calendarID.isEmpty {
            guard let calendar = store.calendar(withIdentifier: calendarID) else {
                throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("找不到指定提醒事项列表。", comment: "Reminder calendar not found"))
            }
            reminder.calendar = calendar
        } else if reminder.calendar == nil {
            guard let defaultCalendar = store.defaultCalendarForNewReminders() else {
                throw MCPBuiltInPersonalDataError.unavailable(NSLocalizedString("没有可用于新提醒事项的默认列表。", comment: "No default reminders list"))
            }
            reminder.calendar = defaultCalendar
        }
        if let notes = arguments.personalDataString("notes") {
            reminder.notes = notes
        }
        if let dueDate = try arguments.personalDataDate("due_date") {
            reminder.dueDateComponents = Calendar.current.dateComponents(in: .current, from: dueDate)
        }
        if let completed = arguments.personalDataBool("completed") {
            reminder.isCompleted = completed
        }
        if let priority = arguments.personalDataString("priority") {
            reminder.priority = reminderPriority(priority)
        }

        var alarms: [EKAlarm] = []
        if let alarmDate = try arguments.personalDataDate("alarm_date") {
            alarms.append(EKAlarm(absoluteDate: alarmDate))
        }
        if let locationAlarm = try locationAlarm(arguments: arguments) {
            alarms.append(locationAlarm)
        }
        if !alarms.isEmpty {
            reminder.alarms = alarms
        }
    }

    func recurrenceRule(for rawValue: String) throws -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch rawValue.lowercased() {
        case "daily":
            frequency = .daily
        case "weekly":
            frequency = .weekly
        case "monthly":
            frequency = .monthly
        case "yearly":
            frequency = .yearly
        default:
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("recurrence 必须是 daily、weekly、monthly 或 yearly。", comment: "Invalid recurrence"))
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)
    }

    func reminderPriority(_ rawValue: String) -> Int {
        switch rawValue.lowercased() {
        case "high":
            return 1
        case "medium":
            return 5
        case "low":
            return 9
        default:
            return 0
        }
    }

    func locationAlarm(arguments: [String: Any]) throws -> EKAlarm? {
        guard let latitude = arguments.personalDataDouble("latitude"),
              let longitude = arguments.personalDataDouble("longitude") else {
            return nil
        }
        #if canImport(CoreLocation)
        let title = arguments.personalDataString("location_title") ?? NSLocalizedString("位置提醒", comment: "Location reminder fallback title")
        let structuredLocation = EKStructuredLocation(title: title)
        structuredLocation.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        structuredLocation.radius = max(arguments.personalDataDouble("radius_meters") ?? 100, 1)

        let alarm = EKAlarm()
        alarm.structuredLocation = structuredLocation
        alarm.proximity = arguments.personalDataString("proximity") == "leave" ? .leave : .enter
        return alarm
        #else
        throw MCPBuiltInPersonalDataError.unavailable(NSLocalizedString("当前平台没有 CoreLocation，无法创建位置提醒。", comment: "CoreLocation unavailable"))
        #endif
    }
    #endif

    func fetchReminders(store: EKEventStore, predicate: NSPredicate) async throws -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    func eventPayload(_ event: EKEvent) -> [String: Any] {
        [
            "id": event.eventIdentifier ?? "",
            "calendar_id": event.calendar.calendarIdentifier,
            "calendar_title": event.calendar.title,
            "title": event.title ?? "",
            "start_date": MCPBuiltInPersonalDataDateCodec.string(event.startDate) ?? "",
            "end_date": MCPBuiltInPersonalDataDateCodec.string(event.endDate) ?? "",
            "is_all_day": event.isAllDay,
            "location": event.location ?? NSNull(),
            "notes": event.notes ?? NSNull(),
            "attendees": event.attendees?.map { participant in
                [
                    "name": participant.name ?? "",
                    "url": participant.url.absoluteString,
                    "role": participant.participantRole.rawValue,
                    "status": participant.participantStatus.rawValue
                ] as [String: Any]
            } ?? [],
            "has_recurrence_rules": !(event.recurrenceRules?.isEmpty ?? true)
        ]
    }

    func reminderPayload(_ reminder: EKReminder) -> [String: Any] {
        [
            "id": reminder.calendarItemIdentifier,
            "calendar_id": reminder.calendar.calendarIdentifier,
            "calendar_title": reminder.calendar.title,
            "title": reminder.title ?? "",
            "notes": reminder.notes ?? NSNull(),
            "is_completed": reminder.isCompleted,
            "completed_date": MCPBuiltInPersonalDataDateCodec.string(reminder.completionDate) ?? NSNull(),
            "due_date": MCPBuiltInPersonalDataDateCodec.string(reminder.dueDateComponents?.date) ?? NSNull(),
            "priority": reminder.priority,
            "alarms": reminder.alarms?.map(alarmPayload) ?? []
        ]
    }

    func alarmPayload(_ alarm: EKAlarm) -> [String: Any] {
        [
            "absolute_date": MCPBuiltInPersonalDataDateCodec.string(alarm.absoluteDate) ?? NSNull(),
            "relative_offset_seconds": alarm.relativeOffset,
            "proximity": alarm.proximity.rawValue,
            "location_title": alarm.structuredLocation?.title ?? NSNull(),
            "latitude": alarm.structuredLocation?.geoLocation?.coordinate.latitude ?? NSNull(),
            "longitude": alarm.structuredLocation?.geoLocation?.coordinate.longitude ?? NSNull(),
            "radius_meters": alarm.structuredLocation?.radius ?? NSNull()
        ]
    }

    func writeResult(toolName: String, itemKey: String, payload: [String: Any]) -> [String: Any] {
        [
            "provider": "etos_builtin_personal_data",
            "tool_name": toolName,
            "saved": true,
            itemKey: payload
        ]
    }
}
#endif
