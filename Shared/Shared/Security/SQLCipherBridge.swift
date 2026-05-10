// ============================================================================
// SQLCipherBridge.swift
// ============================================================================
// ETOS LLM Studio
//
// 桥接 SQLCipher C 函数 sqlite3_key。
// 该函数由 GRDB 的 SQLCipher 变体提供，但未通过 Swift 模块图暴露。
// 使用 @_silgen_name 将 Swift 声明直接链接到已链接二进制中的 C 符号。
// ============================================================================

import Foundation

/// 对已打开的 sqlite3 原始连接应用 SQLCipher passphrase。
/// 等价于在 sqlite3_open_v2 之后立即调用 sqlite3_key(db, pKey, nKey)。
@_silgen_name("sqlite3_key")
@discardableResult
internal func sqlite3_key(_ db: OpaquePointer!, _ pKey: UnsafeRawPointer!, _ nKey: Int32) -> Int32

/// 对已打开的 sqlite3 原始连接重新设置 SQLCipher passphrase。
/// 等价于在 SQLCipher 连接上执行 sqlite3_rekey(db, pKey, nKey)。
@_silgen_name("sqlite3_rekey")
@discardableResult
internal func sqlite3_rekey(_ db: OpaquePointer!, _ pKey: UnsafeRawPointer!, _ nKey: Int32) -> Int32
