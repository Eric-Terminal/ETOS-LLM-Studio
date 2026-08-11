// ============================================================================
// MCPNativeLocationExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 位置工具只执行一次性请求，不保留位置、不注册持续后台更新。
// ============================================================================

import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(MapKit)
import MapKit
#endif

actor MCPNativeLocationExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(CoreLocation)
        switch toolName {
        case "location.get_current":
            return try await currentLocation(arguments)
        case "location.reverse_geocode":
            return try await reverseGeocode(arguments)
        case "location.search_places":
            return try await searchPlaces(arguments)
        default:
            throw MCPBuiltInPersonalDataError.unsupportedTool(toolName)
        }
        #else
        throw MCPBuiltInPersonalDataError.unavailable(
            NSLocalizedString("当前平台没有 CoreLocation。", comment: "CoreLocation unavailable")
        )
        #endif
    }
}

#if canImport(CoreLocation)
private extension MCPNativeLocationExecutor {
    func currentLocation(_ arguments: [String: Any]) async throws -> [String: Any] {
        let accuracy: CLLocationAccuracy
        switch arguments.personalDataString("accuracy") ?? "best" {
        case "best":
            accuracy = kCLLocationAccuracyBest
        case "hundred_meters":
            accuracy = kCLLocationAccuracyHundredMeters
        case "kilometer":
            accuracy = kCLLocationAccuracyKilometer
        default:
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("accuracy 必须是 best、hundred_meters 或 kilometer。", comment: "Invalid location accuracy")
            )
        }
        let location = try await MCPCurrentLocationRequest.request(desiredAccuracy: accuracy)
        return result(toolName: "location.get_current", extra: [
            "location": locationPayload(location),
            "tracking": false
        ])
    }

    func reverseGeocode(_ arguments: [String: Any]) async throws -> [String: Any] {
        let latitude = try arguments.personalDataRequiredDouble("latitude")
        let longitude = try arguments.personalDataRequiredDouble("longitude")
        let location = CLLocation(latitude: latitude, longitude: longitude)
        #if canImport(MapKit)
        if #available(iOS 26.0, watchOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                throw MCPBuiltInPersonalDataError.invalidArgument(
                    NSLocalizedString("无法为该坐标创建反向地理编码请求。", comment: "Reverse geocoding request unavailable")
                )
            }
            let items = try await request.mapItems
            return result(toolName: "location.reverse_geocode", extra: [
                "coordinate": locationPayload(location),
                "places": items.map(mapItemPayload),
                "count": items.count
            ])
        }
        #endif

        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        let places = placemarks.map { placemark in
            [
                "name": placemark.name ?? "",
                "street": placemark.thoroughfare ?? "",
                "city": placemark.locality ?? "",
                "state": placemark.administrativeArea ?? "",
                "postal_code": placemark.postalCode ?? "",
                "country": placemark.country ?? "",
                "iso_country_code": placemark.isoCountryCode ?? ""
            ] as [String: Any]
        }
        return result(toolName: "location.reverse_geocode", extra: [
            "coordinate": locationPayload(location),
            "places": places,
            "count": places.count
        ])
    }

    func searchPlaces(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(MapKit)
        let query = try arguments.personalDataRequiredString("query")
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let latitude = arguments.personalDataDouble("latitude"),
           let longitude = arguments.personalDataDouble("longitude") {
            let radius = max(arguments.personalDataDouble("radius_meters") ?? 5_000, 100)
            let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        let limit = min(max(arguments.personalDataInt("limit") ?? 10, 1), 25)
        let places = response.mapItems.prefix(limit).map(mapItemPayload)
        return result(toolName: "location.search_places", extra: [
            "query": query,
            "places": Array(places),
            "count": places.count
        ])
        #else
        throw MCPBuiltInPersonalDataError.unavailable(
            NSLocalizedString("当前平台没有 MapKit。", comment: "MapKit unavailable")
        )
        #endif
    }

    func locationPayload(_ location: CLLocation) -> [String: Any] {
        [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "altitude_meters": location.altitude,
            "horizontal_accuracy_meters": location.horizontalAccuracy,
            "vertical_accuracy_meters": location.verticalAccuracy,
            "timestamp": MCPBuiltInPersonalDataDateCodec.string(location.timestamp) ?? ""
        ]
    }

    #if canImport(MapKit)
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
    #endif

    func result(toolName: String, extra: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [
            "provider": "etos_builtin_personal_data",
            "tool_name": toolName
        ]
        output.merge(extra) { _, new in new }
        return output
    }
}

@MainActor
private final class MCPCurrentLocationRequest: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var requestedLocation = false

    static func request(desiredAccuracy: CLLocationAccuracy) async throws -> CLLocation {
        let request = MCPCurrentLocationRequest()
        return try await request.start(desiredAccuracy: desiredAccuracy)
    }

    private func start(desiredAccuracy: CLLocationAccuracy) async throws -> CLLocation {
        manager.delegate = self
        manager.desiredAccuracy = desiredAccuracy
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                requestOnce()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(MCPBuiltInPersonalDataError.permissionDenied(
                    NSLocalizedString("位置访问权限不足。", comment: "Location permission insufficient")
                )))
            @unknown default:
                finish(.failure(MCPBuiltInPersonalDataError.permissionDenied(
                    NSLocalizedString("未知位置权限状态。", comment: "Unknown location permission")
                )))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestOnce()
        case .denied, .restricted:
            finish(.failure(MCPBuiltInPersonalDataError.permissionDenied(
                NSLocalizedString("用户未授予位置访问权限。", comment: "Location permission denied")
            )))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(MCPBuiltInPersonalDataError.permissionDenied(
                NSLocalizedString("未知位置权限状态。", comment: "Unknown location permission")
            )))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func requestOnce() {
        guard !requestedLocation else { return }
        requestedLocation = true
        manager.requestLocation()
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        manager.delegate = nil
        continuation.resume(with: result)
    }
}
#endif
