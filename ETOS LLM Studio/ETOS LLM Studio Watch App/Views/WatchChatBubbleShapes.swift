// ============================================================================
// WatchChatBubbleShapes.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡使用的基础形状定义。
// ============================================================================

import SwiftUI

struct BubbleCornerShape: Shape {
    let topLeft: CGFloat
    let topRight: CGFloat
    let bottomLeft: CGFloat
    let bottomRight: CGFloat

    func path(in rect: CGRect) -> Path {
        let tl = min(min(topLeft, rect.width / 2), rect.height / 2)
        let tr = min(min(topRight, rect.width / 2), rect.height / 2)
        let bl = min(min(bottomLeft, rect.width / 2), rect.height / 2)
        let br = min(min(bottomRight, rect.width / 2), rect.height / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
            radius: tr,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(
            center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
            radius: bl,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(
            center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
            radius: tl,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
