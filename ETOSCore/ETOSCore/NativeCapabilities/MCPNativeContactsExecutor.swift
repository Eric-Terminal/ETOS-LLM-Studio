// ============================================================================
// MCPNativeContactsExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// Contacts 执行器。权限只在实际调用时请求，写操作由 MCP 审批层逐次确认。
// ============================================================================

import Foundation
#if canImport(Contacts)
import Contacts
#endif

actor MCPNativeContactsExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(Contacts)
        switch toolName {
        case "contacts.search":
            return try await search(arguments)
        case "contacts.get":
            return try await get(arguments)
        case "contacts.create":
            return try await create(arguments)
        case "contacts.update":
            return try await update(arguments)
        case "contacts.delete":
            return try await delete(arguments)
        default:
            throw MCPBuiltInPersonalDataError.unsupportedTool(toolName)
        }
        #else
        throw MCPBuiltInPersonalDataError.unavailable(
            NSLocalizedString("当前平台没有 Contacts。", comment: "Contacts unavailable")
        )
        #endif
    }
}

#if canImport(Contacts)
private extension MCPNativeContactsExecutor {
    var keysToFetch: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor
        ]
    }

    func search(_ arguments: [String: Any]) async throws -> [String: Any] {
        let store = CNContactStore()
        try await requestAccess(store)
        let query = arguments.personalDataString("query") ?? ""
        let limit = min(max(arguments.personalDataInt("limit") ?? 25, 1), 100)
        var contacts: [CNContact] = []

        if query.isEmpty {
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.sortOrder = .userDefault
            try store.enumerateContacts(with: request) { contact, stop in
                contacts.append(contact)
                if contacts.count >= limit {
                    stop.pointee = true
                }
            }
        } else {
            let predicate = CNContact.predicateForContacts(matchingName: query)
            contacts = Array(try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch).prefix(limit))
            if contacts.isEmpty {
                let request = CNContactFetchRequest(keysToFetch: keysToFetch)
                let lowered = query.localizedLowercase
                try store.enumerateContacts(with: request) { contact, stop in
                    let searchable = ([
                        contact.givenName,
                        contact.familyName,
                        contact.organizationName
                    ] + contact.phoneNumbers.map(\.value.stringValue)
                        + contact.emailAddresses.map { String($0.value) })
                        .joined(separator: " ")
                        .localizedLowercase
                    if searchable.contains(lowered) {
                        contacts.append(contact)
                    }
                    if contacts.count >= limit {
                        stop.pointee = true
                    }
                }
            }
        }

        return result(toolName: "contacts.search", extra: [
            "query": query,
            "contacts": contacts.map(payload),
            "count": contacts.count
        ])
    }

    func get(_ arguments: [String: Any]) async throws -> [String: Any] {
        let identifier = try arguments.personalDataRequiredString("contact_id")
        let store = CNContactStore()
        try await requestAccess(store)
        let contact: CNContact
        do {
            contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
        } catch {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("找不到指定联系人。", comment: "Contact not found")
            )
        }
        return result(toolName: "contacts.get", extra: ["contact": payload(contact)])
    }

    func create(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(
            NSLocalizedString("watchOS 不支持通过 Contacts 写入联系人。", comment: "watchOS Contacts write unsupported")
        )
        #else
        let store = CNContactStore()
        try await requestAccess(store)
        let contact = CNMutableContact()
        try apply(arguments, to: contact, isCreate: true)
        let save = CNSaveRequest()
        save.add(contact, toContainerWithIdentifier: nil)
        try store.execute(save)
        let saved = try store.unifiedContact(withIdentifier: contact.identifier, keysToFetch: keysToFetch)
        return result(toolName: "contacts.create", extra: ["saved": true, "contact": payload(saved)])
        #endif
    }

    func update(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(
            NSLocalizedString("watchOS 不支持通过 Contacts 更新联系人。", comment: "watchOS Contacts update unsupported")
        )
        #else
        let identifier = try arguments.personalDataRequiredString("contact_id")
        let store = CNContactStore()
        try await requestAccess(store)
        let original: CNContact
        do {
            original = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
        } catch {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("找不到指定联系人。", comment: "Contact not found")
            )
        }
        guard let contact = original.mutableCopy() as? CNMutableContact else {
            throw MCPBuiltInPersonalDataError.unavailable(
                NSLocalizedString("系统未能创建可编辑的联系人副本。", comment: "Mutable contact unavailable")
            )
        }
        try apply(arguments, to: contact, isCreate: false)
        let save = CNSaveRequest()
        save.update(contact)
        try store.execute(save)
        let saved = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
        return result(toolName: "contacts.update", extra: ["saved": true, "contact": payload(saved)])
        #endif
    }

    func delete(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(
            NSLocalizedString("watchOS 不支持通过 Contacts 删除联系人。", comment: "watchOS Contacts delete unsupported")
        )
        #else
        let identifier = try arguments.personalDataRequiredString("contact_id")
        let store = CNContactStore()
        try await requestAccess(store)
        let original: CNContact
        do {
            original = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
        } catch {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("找不到指定联系人。", comment: "Contact not found")
            )
        }
        guard let contact = original.mutableCopy() as? CNMutableContact else {
            throw MCPBuiltInPersonalDataError.unavailable(
                NSLocalizedString("系统未能创建可编辑的联系人副本。", comment: "Mutable contact unavailable")
            )
        }
        let deleted = payload(original)
        let save = CNSaveRequest()
        save.delete(contact)
        try store.execute(save)
        return result(toolName: "contacts.delete", extra: ["deleted": true, "contact": deleted])
        #endif
    }

    func requestAccess(_ store: CNContactStore) async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else {
                throw MCPBuiltInPersonalDataError.permissionDenied(
                    NSLocalizedString("用户未授予联系人访问权限。", comment: "Contacts permission denied")
                )
            }
        case .denied, .restricted:
            throw MCPBuiltInPersonalDataError.permissionDenied(
                NSLocalizedString("联系人访问权限不足。", comment: "Contacts permission insufficient")
            )
        @unknown default:
            throw MCPBuiltInPersonalDataError.permissionDenied(
                NSLocalizedString("未知联系人权限状态。", comment: "Unknown Contacts permission")
            )
        }
    }

    func apply(_ arguments: [String: Any], to contact: CNMutableContact, isCreate: Bool) throws {
        if let value = arguments.personalDataString("given_name") {
            contact.givenName = value
        } else if isCreate {
            contact.givenName = try arguments.personalDataRequiredString("given_name")
        }
        if let value = arguments.personalDataString("family_name") {
            contact.familyName = value
        }
        if let value = arguments.personalDataString("organization") {
            contact.organizationName = value
        }
        if let values = arguments.personalDataStringArray("phone_numbers") {
            contact.phoneNumbers = values.map {
                CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
            }
        }
        if let values = arguments.personalDataStringArray("email_addresses") {
            contact.emailAddresses = values.map {
                CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
            }
        }

        let addressKeys = ["street", "city", "state", "postal_code", "country"]
        if addressKeys.contains(where: { arguments[$0] != nil }) {
            let address = CNMutablePostalAddress()
            address.street = arguments.personalDataString("street") ?? ""
            address.city = arguments.personalDataString("city") ?? ""
            address.state = arguments.personalDataString("state") ?? ""
            address.postalCode = arguments.personalDataString("postal_code") ?? ""
            address.country = arguments.personalDataString("country") ?? ""
            contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]
        }
    }

    func payload(_ contact: CNContact) -> [String: Any] {
        [
            "id": contact.identifier,
            "given_name": contact.givenName,
            "family_name": contact.familyName,
            "display_name": CNContactFormatter.string(from: contact, style: .fullName) ?? "",
            "organization": contact.organizationName,
            "phone_numbers": contact.phoneNumbers.map { item in
                [
                    "label": item.label.map(CNLabeledValue<NSString>.localizedString(forLabel:)) ?? "",
                    "value": item.value.stringValue
                ]
            },
            "email_addresses": contact.emailAddresses.map { item in
                [
                    "label": item.label.map(CNLabeledValue<NSString>.localizedString(forLabel:)) ?? "",
                    "value": String(item.value)
                ]
            },
            "postal_addresses": contact.postalAddresses.map { item in
                [
                    "label": item.label.map(CNLabeledValue<CNPostalAddress>.localizedString(forLabel:)) ?? "",
                    "street": item.value.street,
                    "city": item.value.city,
                    "state": item.value.state,
                    "postal_code": item.value.postalCode,
                    "country": item.value.country
                ]
            }
        ]
    }

    func result(toolName: String, extra: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [
            "provider": "etos_builtin_personal_data",
            "tool_name": toolName
        ]
        output.merge(extra) { _, new in new }
        return output
    }
}
#endif

private extension Dictionary where Key == String, Value == Any {
    func personalDataStringArray(_ key: String) -> [String]? {
        guard let values = self[key] as? [Any] else { return nil }
        return values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
