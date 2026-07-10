// ============================================================================
// ChatTranscriptImageDrawingSupport.swift
// ============================================================================
// 聊天长图中使用的轻量矢量图标，避免依赖平台 UI 框架。
// ============================================================================

import CoreGraphics
import Foundation

extension ChatTranscriptImageRenderer {
    func drawStar(center: CGPoint, radius: CGFloat, context: CGContext) {
        let points = 10
        for index in 0..<points {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
            let pointRadius = index.isMultiple(of: 2) ? radius : radius * 0.45
            let point = CGPoint(
                x: center.x + cos(angle) * pointRadius,
                y: center.y + sin(angle) * pointRadius
            )
            if index == 0 {
                context.move(to: point)
            } else {
                context.addLine(to: point)
            }
        }
        context.closePath()
        context.strokePath()
    }

    func drawSettingsIcon(center: CGPoint, context: CGContext, color: CGColor) {
        context.setStrokeColor(color)
        context.setLineWidth(1.8)
        for (offset, knob) in [(-6.0, -4.0), (0.0, 5.0), (6.0, -1.0)] {
            let y = center.y + CGFloat(offset)
            context.move(to: CGPoint(x: center.x - 9, y: y))
            context.addLine(to: CGPoint(x: center.x + 9, y: y))
            context.strokePath()
            context.strokeEllipse(in: CGRect(x: center.x + CGFloat(knob) - 2, y: y - 2, width: 4, height: 4))
        }
    }

    func drawPaperclip(center: CGPoint, color: CGColor, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: center.x + 5, y: center.y - 7))
        context.addCurve(
            to: CGPoint(x: center.x - 5, y: center.y + 7),
            control1: CGPoint(x: center.x + 10, y: center.y - 1),
            control2: CGPoint(x: center.x - 1, y: center.y + 12)
        )
        context.addCurve(
            to: CGPoint(x: center.x - 2, y: center.y - 5),
            control1: CGPoint(x: center.x - 11, y: center.y + 4),
            control2: CGPoint(x: center.x - 8, y: center.y - 7)
        )
        context.addLine(to: CGPoint(x: center.x + 5, y: center.y + 3))
        context.strokePath()
        context.restoreGState()
    }

    func drawMicrophone(center: CGPoint, color: CGColor, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.stroke(CGRect(x: center.x - 4, y: center.y - 8, width: 8, height: 13))
        context.move(to: CGPoint(x: center.x - 8, y: center.y + 1))
        context.addCurve(
            to: CGPoint(x: center.x + 8, y: center.y + 1),
            control1: CGPoint(x: center.x - 7, y: center.y + 11),
            control2: CGPoint(x: center.x + 7, y: center.y + 11)
        )
        context.strokePath()
        context.move(to: CGPoint(x: center.x, y: center.y + 8))
        context.addLine(to: CGPoint(x: center.x, y: center.y + 12))
        context.move(to: CGPoint(x: center.x - 4, y: center.y + 12))
        context.addLine(to: CGPoint(x: center.x + 4, y: center.y + 12))
        context.strokePath()
        context.restoreGState()
    }

    func drawPhotoPlaceholder(in rect: CGRect, color: CGColor, context: CGContext) {
        context.setStrokeColor(color)
        context.setLineWidth(1.8)
        let iconRect = CGRect(x: rect.midX - 18, y: rect.midY - 15, width: 36, height: 30)
        context.addPath(CGPath(roundedRect: iconRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: iconRect.minX + 7, y: iconRect.minY + 6, width: 6, height: 6))
        context.move(to: CGPoint(x: iconRect.minX + 5, y: iconRect.maxY - 5))
        context.addLine(to: CGPoint(x: iconRect.midX - 3, y: iconRect.midY))
        context.addLine(to: CGPoint(x: iconRect.midX + 4, y: iconRect.maxY - 8))
        context.addLine(to: CGPoint(x: iconRect.maxX - 5, y: iconRect.maxY - 5))
        context.strokePath()
    }

    func drawDocumentIcon(in rect: CGRect, color: CGColor, context: CGContext) {
        context.setStrokeColor(color)
        context.setLineWidth(1.5)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.strokePath()
        context.move(to: CGPoint(x: rect.minX + 5, y: rect.midY - 2))
        context.addLine(to: CGPoint(x: rect.maxX - 5, y: rect.midY - 2))
        context.move(to: CGPoint(x: rect.minX + 5, y: rect.midY + 3))
        context.addLine(to: CGPoint(x: rect.maxX - 7, y: rect.midY + 3))
        context.strokePath()
    }

    func drawToolIcon(in rect: CGRect, color: CGColor, context: CGContext) {
        context.setStrokeColor(color)
        context.setLineWidth(1.6)
        context.strokeEllipse(in: rect.insetBy(dx: 3, dy: 3))
        context.move(to: CGPoint(x: rect.midX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.midX, y: rect.minY + 4))
        context.move(to: CGPoint(x: rect.midX, y: rect.maxY - 4))
        context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        context.move(to: CGPoint(x: rect.minX, y: rect.midY))
        context.addLine(to: CGPoint(x: rect.minX + 4, y: rect.midY))
        context.move(to: CGPoint(x: rect.maxX - 4, y: rect.midY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.strokePath()
    }

    func drawWaveform(in rect: CGRect, color: CGColor, context: CGContext) {
        context.setStrokeColor(color)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        let heights: [CGFloat] = [6, 14, 20, 10, 16, 7]
        let spacing = rect.width / CGFloat(heights.count - 1)
        for (index, height) in heights.enumerated() {
            let x = rect.minX + CGFloat(index) * spacing
            context.move(to: CGPoint(x: x, y: rect.midY - height / 2))
            context.addLine(to: CGPoint(x: x, y: rect.midY + height / 2))
        }
        context.strokePath()
    }
}
