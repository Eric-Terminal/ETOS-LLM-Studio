// ============================================================================
// MCPNativeMapsExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// MapKit 检索与路线计算保持在进程外 I/O 路径；打开地图和 URL 回到主线程。
// ============================================================================

import Foundation
#if canImport(MapKit)
import MapKit
#endif
#if os(iOS) && canImport(UIKit)
import UIKit
#endif
#if os(watchOS) && canImport(WatchKit)
import WatchKit
#endif

actor MCPNativeMapsExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        switch toolName {
        case "maps.search":
            return try await search(arguments)
        case "maps.directions":
            return try await directions(arguments)
        case "maps.open":
            return try await openMaps(arguments)
        case "device.open_url":
            return try await openURL(arguments)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
    }
}

private extension MCPNativeMapsExecutor {
    func search(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(MapKit)
        let query = try arguments.nativeRequiredString("query")
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let latitude = arguments.nativeDouble("latitude"),
           let longitude = arguments.nativeDouble("longitude") {
            let radius = max(arguments.nativeDouble("radius_meters") ?? 5_000, 100)
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        let limit = min(max(arguments.nativeInt("limit") ?? 10, 1), 25)
        let items = response.mapItems.prefix(limit).map(mapItemPayload)
        return ["query": query, "places": Array(items), "count": items.count]
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有 MapKit。", comment: "MapKit unavailable")
        )
        #endif
    }

    func directions(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(MapKit)
        let source = CLLocationCoordinate2D(
            latitude: try arguments.nativeRequiredDouble("source_latitude"),
            longitude: try arguments.nativeRequiredDouble("source_longitude")
        )
        let destination = CLLocationCoordinate2D(
            latitude: try arguments.nativeRequiredDouble("destination_latitude"),
            longitude: try arguments.nativeRequiredDouble("destination_longitude")
        )
        let request = MKDirections.Request()
        request.source = mapItem(at: source)
        request.destination = mapItem(at: destination)
        request.transportType = try transportType(arguments.nativeString("transport_type") ?? "automobile")
        request.requestsAlternateRoutes = arguments.nativeBool("alternates") ?? false
        let response = try await MKDirections(request: request).calculate()
        let routes = response.routes.map { route in
            [
                "name": route.name,
                "distance_meters": route.distance,
                "expected_travel_time_seconds": route.expectedTravelTime,
                "has_tolls": route.hasTolls,
                "has_highways": route.hasHighways,
                "steps": route.steps.map { step in
                    [
                        "instructions": step.instructions,
                        "notice": step.notice ?? NSNull(),
                        "distance_meters": step.distance
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
        return ["routes": routes, "count": routes.count]
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有 MapKit。", comment: "MapKit unavailable")
        )
        #endif
    }

    func openMaps(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(MapKit)
        let coordinate = CLLocationCoordinate2D(
            latitude: try arguments.nativeRequiredDouble("latitude"),
            longitude: try arguments.nativeRequiredDouble("longitude")
        )
        let item = mapItem(at: coordinate)
        item.name = arguments.nativeString("name")
        var options: [String: Any] = [:]
        if let mode = arguments.nativeString("directions_mode") {
            options[MKLaunchOptionsDirectionsModeKey] = try directionsMode(mode)
        }
        let launchOptions = options
        let opened = await MainActor.run {
            item.openInMaps(launchOptions: launchOptions)
        }
        return ["opened": opened, "latitude": coordinate.latitude, "longitude": coordinate.longitude]
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有 MapKit。", comment: "MapKit unavailable")
        )
        #endif
    }

    func openURL(_ arguments: [String: Any]) async throws -> [String: Any] {
        let rawURL = try arguments.nativeRequiredString("url")
        guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased() else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("url 必须是完整有效的 URL。", comment: "Invalid native open URL")
            )
        }
        let allowedSchemes: Set<String> = [
            "http", "https", "mailto", "tel", "sms", "facetime", "facetime-audio", "maps"
        ]
        guard allowedSchemes.contains(scheme) else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("该 URL scheme 不在允许列表中。", comment: "Native open URL scheme denied")
            )
        }

        #if os(iOS) && canImport(UIKit)
        let opened = await UIApplication.shared.open(url)
        return ["opened": opened, "url": url.absoluteString]
        #elseif os(watchOS) && canImport(WatchKit)
        await MainActor.run {
            WKApplication.shared().openSystemURL(url)
        }
        return ["opened": true, "url": url.absoluteString]
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台不能打开系统 URL。", comment: "System URL opening unavailable")
        )
        #endif
    }

    #if canImport(MapKit)
    func mapItem(at coordinate: CLLocationCoordinate2D) -> MKMapItem {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26.0, watchOS 26.0, *) {
            return MKMapItem(location: location, address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    func mapItemPayload(_ item: MKMapItem) -> [String: Any] {
        let location: CLLocation
        let address: String
        if #available(iOS 26.0, watchOS 26.0, *) {
            location = item.location
            address = item.address?.fullAddress ?? ""
        } else {
            location = item.placemark.location ?? CLLocation(latitude: 0, longitude: 0)
            address = [
                item.placemark.thoroughfare,
                item.placemark.locality,
                item.placemark.administrativeArea,
                item.placemark.postalCode,
                item.placemark.country
            ].compactMap { $0 }.joined(separator: ", ")
        }
        return [
            "name": item.name ?? "",
            "address": address,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "phone_number": item.phoneNumber ?? NSNull(),
            "url": item.url?.absoluteString ?? NSNull(),
            "category": item.pointOfInterestCategory?.rawValue ?? NSNull()
        ]
    }

    func transportType(_ value: String) throws -> MKDirectionsTransportType {
        switch value {
        case "automobile": return .automobile
        case "walking": return .walking
        case "transit": return .transit
        case "cycling": return .cycling
        default:
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("transport_type 必须是 automobile、walking、transit 或 cycling。", comment: "Invalid directions transport type")
            )
        }
    }

    func directionsMode(_ value: String) throws -> String {
        switch value {
        case "driving": return MKLaunchOptionsDirectionsModeDriving
        case "walking": return MKLaunchOptionsDirectionsModeWalking
        case "transit": return MKLaunchOptionsDirectionsModeTransit
        case "cycling": return MKLaunchOptionsDirectionsModeCycling
        default:
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("directions_mode 必须是 driving、walking、transit 或 cycling。", comment: "Invalid maps directions mode")
            )
        }
    }
    #endif
}
