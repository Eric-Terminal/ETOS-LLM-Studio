// ============================================================================
// RequestBodySliderAnimatedValue.swift
// ============================================================================
// ETOS LLM Studio
//
// 为结构化控制滑块提供可中断、保留字符连续性的值过渡。
// ============================================================================

import Foundation
import SwiftUI

public struct RequestBodySliderAnimatedValue: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let text: String
    private let position: Double
    private let isNumeric: Bool

    @State private var glyphs: [Glyph]
    @State private var movesTowardHigherPosition = true

    public init(text: String, position: Double, isNumeric: Bool) {
        self.text = text
        self.position = position
        self.isNumeric = isNumeric
        _glyphs = State(initialValue: Self.initialGlyphs(for: text))
    }

    public var body: some View {
        Group {
            if isNumeric {
                numericText
            } else {
                characterText
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }

    @ViewBuilder
    private var numericText: some View {
        if reduceMotion {
            Text(text)
        } else {
            Text(text)
                // 位置增大时让新数字从上方落下，与滑动方向保持空间对应。
                .contentTransition(.numericText(value: -position))
                .animation(Self.valueAnimation, value: text)
        }
    }

    private var characterText: some View {
        HStack(spacing: 0) {
            ForEach(glyphs) { glyph in
                Text(String(glyph.character))
                    .transition(characterTransition)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .clipped()
        .onChange(of: ValueSnapshot(text: text, position: position)) { previous, current in
            updateCharacters(from: previous, to: current)
        }
    }

    private var characterTransition: AnyTransition {
        let insertionEdge: Edge = movesTowardHigherPosition ? .top : .bottom
        let removalEdge: Edge = movesTowardHigherPosition ? .bottom : .top
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }

    private func updateCharacters(from previous: ValueSnapshot, to current: ValueSnapshot) {
        if current.position != previous.position {
            movesTowardHigherPosition = current.position > previous.position
        }
        guard current.text != previous.text else { return }

        let matchedIndices = RequestBodySliderTextDiff.matchedPreviousIndices(
            from: String(glyphs.map(\.character)),
            to: current.text
        )
        let characters = Array(current.text)
        let updatedGlyphs = characters.indices.map { index in
            if let previousIndex = matchedIndices[index], glyphs.indices.contains(previousIndex) {
                return Glyph(id: glyphs[previousIndex].id, character: characters[index])
            }
            return Glyph(character: characters[index])
        }

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                glyphs = updatedGlyphs
            }
        } else {
            withAnimation(Self.valueAnimation) {
                glyphs = updatedGlyphs
            }
        }
    }

    private static func initialGlyphs(for text: String) -> [Glyph] {
        text.map { Glyph(character: $0) }
    }

    private static let valueAnimation = Animation.spring(
        response: 0.28,
        dampingFraction: 1
    )
}

private extension RequestBodySliderAnimatedValue {
    struct Glyph: Identifiable {
        let id: UUID
        let character: Character

        init(id: UUID = UUID(), character: Character) {
            self.id = id
            self.character = character
        }
    }

    struct ValueSnapshot: Equatable {
        let text: String
        let position: Double
    }
}

enum RequestBodySliderTextDiff {
    static func matchedPreviousIndices(from previous: String, to current: String) -> [Int?] {
        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        guard !currentCharacters.isEmpty else { return [] }
        guard !previousCharacters.isEmpty else {
            return Array(repeating: nil, count: currentCharacters.count)
        }

        var lengths = Array(
            repeating: Array(repeating: 0, count: currentCharacters.count + 1),
            count: previousCharacters.count + 1
        )
        for previousIndex in stride(from: previousCharacters.count - 1, through: 0, by: -1) {
            for currentIndex in stride(from: currentCharacters.count - 1, through: 0, by: -1) {
                if previousCharacters[previousIndex] == currentCharacters[currentIndex] {
                    lengths[previousIndex][currentIndex] = lengths[previousIndex + 1][currentIndex + 1] + 1
                } else {
                    lengths[previousIndex][currentIndex] = max(
                        lengths[previousIndex + 1][currentIndex],
                        lengths[previousIndex][currentIndex + 1]
                    )
                }
            }
        }

        var matchedIndices = Array<Int?>(repeating: nil, count: currentCharacters.count)
        var previousIndex = 0
        var currentIndex = 0
        while previousIndex < previousCharacters.count, currentIndex < currentCharacters.count {
            if previousCharacters[previousIndex] == currentCharacters[currentIndex] {
                matchedIndices[currentIndex] = previousIndex
                previousIndex += 1
                currentIndex += 1
            } else if lengths[previousIndex + 1][currentIndex] >= lengths[previousIndex][currentIndex + 1] {
                previousIndex += 1
            } else {
                currentIndex += 1
            }
        }
        return matchedIndices
    }
}
