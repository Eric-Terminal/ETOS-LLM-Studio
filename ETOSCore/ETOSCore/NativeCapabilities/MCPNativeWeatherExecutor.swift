// ============================================================================
// MCPNativeWeatherExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// WeatherKit 查询只使用工具显式提供的坐标，并随结果保留服务归属信息。
// ============================================================================

import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(WeatherKit)
import WeatherKit
#endif

actor MCPNativeWeatherExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(WeatherKit) && canImport(CoreLocation)
        let location = CLLocation(
            latitude: try arguments.nativeRequiredDouble("latitude"),
            longitude: try arguments.nativeRequiredDouble("longitude")
        )
        let service = WeatherService.shared
        let attribution = try await service.attribution
        var result: [String: Any]
        switch toolName {
        case "weather.current":
            let weather = try await service.weather(for: location, including: .current)
            result = ["weather": currentPayload(weather)]
        case "weather.hourly_forecast":
            let count = min(max(arguments.nativeInt("hours") ?? 24, 1), 48)
            let forecast = try await service.weather(for: location, including: .hourly)
            let hours = forecast.forecast.prefix(count).map(hourPayload)
            result = ["forecast": Array(hours), "count": hours.count]
        case "weather.daily_forecast":
            let count = min(max(arguments.nativeInt("days") ?? 7, 1), 10)
            let forecast = try await service.weather(for: location, including: .daily)
            let days = forecast.forecast.prefix(count).map(dayPayload)
            result = ["forecast": Array(days), "count": days.count]
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        result["location"] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude
        ]
        result["attribution"] = [
            "service_name": attribution.serviceName,
            "legal_page_url": attribution.legalPageURL.absoluteString
        ]
        return result
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有 WeatherKit。", comment: "WeatherKit unavailable")
        )
        #endif
    }
}

#if canImport(WeatherKit)
private extension MCPNativeWeatherExecutor {
    func currentPayload(_ weather: CurrentWeather) -> [String: Any] {
        [
            "date": date(weather.date),
            "condition": weather.condition.rawValue,
            "symbol_name": weather.symbolName,
            "temperature_celsius": celsius(weather.temperature),
            "apparent_temperature_celsius": celsius(weather.apparentTemperature),
            "humidity": weather.humidity,
            "cloud_cover": weather.cloudCover,
            "pressure_hectopascals": weather.pressure.converted(to: .hectopascals).value,
            "visibility_kilometers": weather.visibility.converted(to: .kilometers).value,
            "uv_index": weather.uvIndex.value,
            "wind": windPayload(weather.wind),
            "is_daylight": weather.isDaylight
        ]
    }

    func hourPayload(_ weather: HourWeather) -> [String: Any] {
        [
            "date": date(weather.date),
            "condition": weather.condition.rawValue,
            "symbol_name": weather.symbolName,
            "temperature_celsius": celsius(weather.temperature),
            "apparent_temperature_celsius": celsius(weather.apparentTemperature),
            "precipitation": weather.precipitation.rawValue,
            "precipitation_chance": weather.precipitationChance,
            "precipitation_millimeters": weather.precipitationAmount.converted(to: .millimeters).value,
            "humidity": weather.humidity,
            "uv_index": weather.uvIndex.value,
            "wind": windPayload(weather.wind),
            "is_daylight": weather.isDaylight
        ]
    }

    func dayPayload(_ weather: DayWeather) -> [String: Any] {
        [
            "date": date(weather.date),
            "condition": weather.condition.rawValue,
            "symbol_name": weather.symbolName,
            "high_temperature_celsius": celsius(weather.highTemperature),
            "low_temperature_celsius": celsius(weather.lowTemperature),
            "precipitation": weather.precipitation.rawValue,
            "precipitation_chance": weather.precipitationChance,
            "uv_index": weather.uvIndex.value,
            "sunrise": MCPBuiltInPersonalDataDateCodec.string(weather.sun.sunrise) ?? NSNull(),
            "sunset": MCPBuiltInPersonalDataDateCodec.string(weather.sun.sunset) ?? NSNull(),
            "wind": windPayload(weather.wind)
        ]
    }

    func windPayload(_ wind: Wind) -> [String: Any] {
        [
            "direction_degrees": wind.direction.converted(to: .degrees).value,
            "compass_direction": wind.compassDirection.rawValue,
            "speed_kilometers_per_hour": wind.speed.converted(to: .kilometersPerHour).value,
            "gust_kilometers_per_hour": wind.gust?.converted(to: .kilometersPerHour).value ?? NSNull()
        ]
    }

    func celsius(_ measurement: Measurement<UnitTemperature>) -> Double {
        measurement.converted(to: .celsius).value
    }

    func date(_ value: Date) -> String {
        MCPBuiltInPersonalDataDateCodec.string(value) ?? ""
    }
}
#endif
