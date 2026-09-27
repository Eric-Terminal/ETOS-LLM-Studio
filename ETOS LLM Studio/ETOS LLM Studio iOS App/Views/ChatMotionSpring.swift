// ============================================================================
// ChatMotionSpring.swift
// ============================================================================
// 聊天交互共用的标量弹簧。重定向只替换目标，保留当时的位置与速度。
// ============================================================================

import Foundation

struct ChatMotionSpring: Sendable {
    private(set) var position: CGFloat
    private(set) var velocity: CGFloat
    private(set) var target: CGFloat
    private(set) var responseDuration: TimeInterval
    private(set) var dampingRatio: CGFloat

    /// responseDuration 表示无阻尼自然周期，与 SwiftUI spring 的 response 语义一致。
    nonisolated init(
        position: CGFloat,
        velocity: CGFloat = 0,
        target: CGFloat,
        responseDuration: TimeInterval,
        dampingRatio: CGFloat = 1
    ) {
        self.position = position
        self.velocity = velocity
        self.target = target
        self.responseDuration = max(responseDuration, 0.001)
        self.dampingRatio = max(dampingRatio, 0.001)
    }

    nonisolated mutating func retarget(
        to target: CGFloat,
        responseDuration: TimeInterval? = nil,
        dampingRatio: CGFloat? = nil
    ) {
        self.target = target
        if let responseDuration { self.responseDuration = max(responseDuration, 0.001) }
        if let dampingRatio { self.dampingRatio = max(dampingRatio, 0.001) }
    }

    /// 使用解析解而非逐帧欧拉积分，60/120Hz 与偶发掉帧不会改变运动轨迹。
    nonisolated mutating func advance(by deltaTime: TimeInterval) {
        guard deltaTime > 0, deltaTime.isFinite else { return }
        let time = CGFloat(deltaTime)
        let frequency = 2 * CGFloat.pi / CGFloat(responseDuration)
        let displacement = position - target
        let decay = exp(-dampingRatio * frequency * time)
        let newDisplacement: CGFloat
        let newVelocity: CGFloat

        if abs(dampingRatio - 1) < 0.0001 {
            let coefficient = velocity + frequency * displacement
            newDisplacement = (displacement + coefficient * time) * decay
            newVelocity = (velocity - frequency * coefficient * time) * decay
        } else if dampingRatio < 1 {
            let dampedFrequency = frequency * sqrt(1 - dampingRatio * dampingRatio)
            let coefficient = (velocity + dampingRatio * frequency * displacement) / dampedFrequency
            let cosine = cos(dampedFrequency * time)
            let sine = sin(dampedFrequency * time)
            newDisplacement = decay * (displacement * cosine + coefficient * sine)
            newVelocity = decay * (
                velocity * cosine
                    - (dampingRatio * frequency * coefficient + dampedFrequency * displacement) * sine
            )
        } else {
            let root = sqrt(dampingRatio * dampingRatio - 1)
            let slowRate = -frequency * (dampingRatio - root)
            let fastRate = -frequency * (dampingRatio + root)
            let slowCoefficient = (velocity - fastRate * displacement) / (slowRate - fastRate)
            let fastCoefficient = displacement - slowCoefficient
            let slowTerm = slowCoefficient * exp(slowRate * time)
            let fastTerm = fastCoefficient * exp(fastRate * time)
            newDisplacement = slowTerm + fastTerm
            newVelocity = slowRate * slowTerm + fastRate * fastTerm
        }

        position = target + newDisplacement
        velocity = newVelocity
    }

    nonisolated var isSettled: Bool {
        abs(position - target) < 0.1 && abs(velocity) < 1
    }

    nonisolated mutating func finish() {
        position = target
        velocity = 0
    }
}
