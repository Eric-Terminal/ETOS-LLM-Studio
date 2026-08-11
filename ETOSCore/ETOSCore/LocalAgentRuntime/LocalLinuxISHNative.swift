// ============================================================================
// LocalLinuxISHNative.swift
// ============================================================================
// ETOS LLM Studio
//
// 这里只声明 ETOS 自有 C 薄桥的稳定符号。上层不得直接导入 iSHApple，避免
// 第三方 ABI 类型进入聊天、MCP、文件工具或 SwiftUI。
// ============================================================================

import Foundation

typealias ETOSISHRootFSProgressCallback = @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32,
    UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
    UnsafePointer<CChar>?
) -> Int32

typealias ETOSISHCommandStreamCallback = @convention(c) (
    UnsafeMutableRawPointer?, UInt64, UInt32,
    UnsafeRawPointer?, UInt32, Int32
) -> Void

typealias ETOSISHCommandCompletionCallback = @convention(c) (
    UnsafeMutableRawPointer?, UInt64, Int32, Int32, Int32, Int32,
    UInt64, UInt64, UInt64
) -> Void

typealias ETOSISHMountInfoCallback = @convention(c) (
    UnsafeMutableRawPointer?, UInt64, UInt64, Int32, Int32,
    UInt64, UInt64, UnsafePointer<CChar>?
) -> Void

typealias ETOSISHGuestFileInfoCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
    UInt64, UInt64, UInt64, UInt64,
    UInt32, UInt32, UInt32, UInt32, UInt32,
    Int64, Int64, Int64, UInt32, UInt32, UInt32
) -> Void

typealias ETOSISHDiagnosticCallback = @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, UInt32, UInt32,
    Int32, Int32, UInt32, UInt64, UInt64, UInt64, UInt64,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Void

@_silgen_name("etos_ish_is_available")
func etosISHIsAvailable() -> Int32

@_silgen_name("etos_ish_rootfs_install_archive")
func etosISHRootFSInstallArchive(
    _ archivePath: UnsafePointer<CChar>,
    _ expectedSHA256: UnsafePointer<CChar>,
    _ expectedUncompressedBytes: UInt64,
    _ expectedEntryCount: UInt64,
    _ persistentParent: UnsafePointer<CChar>,
    _ rootName: UnsafePointer<CChar>,
    _ context: UnsafeMutableRawPointer?,
    _ progress: ETOSISHRootFSProgressCallback,
    _ dispositionOut: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("etos_ish_runtime_start")
func etosISHRuntimeStart(
    _ rootData: UnsafePointer<CChar>,
    _ sharedDirectory: UnsafePointer<CChar>,
    _ socketPrefix: UnsafePointer<CChar>,
    _ hostname: UnsafePointer<CChar>,
    _ bootCommand: UnsafePointer<CChar>,
    _ mountIDHigh: UnsafePointer<UInt64>?,
    _ mountIDLow: UnsafePointer<UInt64>?,
    _ mountAccess: UnsafePointer<Int32>?,
    _ mountDirectoryFDs: UnsafePointer<Int32>?,
    _ mountGuestDirectories: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mountCount: UInt32
) -> Int32

@_silgen_name("etos_ish_runtime_stop")
func etosISHRuntimeStop() -> Int32

@_silgen_name("etos_ish_runtime_phase")
func etosISHRuntimePhase() -> Int32

@_silgen_name("etos_ish_runtime_last_error")
func etosISHRuntimeLastError() -> Int32

@_silgen_name("etos_ish_runtime_capabilities")
func etosISHRuntimeCapabilities(
    _ featureFlags: UnsafeMutablePointer<UInt64>,
    _ guestArchitecture: UnsafeMutablePointer<UInt32>,
    _ backend: UnsafeMutablePointer<UInt32>,
    _ publicABIVersion: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("etos_ish_command_start")
func etosISHCommandStart(
    _ requestID: UInt64,
    _ executable: UnsafePointer<CChar>,
    _ arguments: UnsafePointer<UnsafePointer<CChar>?>,
    _ argumentCount: UInt32,
    _ environment: UnsafePointer<UnsafePointer<CChar>?>?,
    _ environmentCount: UInt32,
    _ workingDirectory: UnsafePointer<CChar>?,
    _ timeoutMilliseconds: UInt32,
    _ outputByteLimit: UInt64,
    _ context: UnsafeMutableRawPointer?,
    _ stream: ETOSISHCommandStreamCallback,
    _ completed: ETOSISHCommandCompletionCallback,
    _ sessionOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) -> Int32

@_silgen_name("etos_ish_command_release")
func etosISHCommandRelease(_ session: UnsafeMutableRawPointer?)

@_silgen_name("etos_ish_command_write")
func etosISHCommandWrite(
    _ session: UnsafeMutableRawPointer,
    _ bytes: UnsafeRawPointer?,
    _ length: UInt32,
    _ acceptedOut: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("etos_ish_command_close_input")
func etosISHCommandCloseInput(_ session: UnsafeMutableRawPointer) -> Int32

@_silgen_name("etos_ish_command_interrupt")
func etosISHCommandInterrupt(_ session: UnsafeMutableRawPointer) -> Int32

@_silgen_name("etos_ish_command_cancel")
func etosISHCommandCancel(_ session: UnsafeMutableRawPointer) -> Int32

@_silgen_name("etos_ish_terminal_start")
func etosISHTerminalStart(
    _ terminalID: UInt64,
    _ executable: UnsafePointer<CChar>,
    _ arguments: UnsafePointer<UnsafePointer<CChar>?>,
    _ argumentCount: UInt32,
    _ environment: UnsafePointer<UnsafePointer<CChar>?>?,
    _ environmentCount: UInt32,
    _ workingDirectory: UnsafePointer<CChar>?,
    _ columns: UInt16,
    _ rows: UInt16,
    _ sessionOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) -> Int32

@_silgen_name("etos_ish_terminal_retain")
func etosISHTerminalRetain(_ session: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?

@_silgen_name("etos_ish_terminal_release")
func etosISHTerminalRelease(_ session: UnsafeMutableRawPointer?)

@_silgen_name("etos_ish_terminal_read")
func etosISHTerminalRead(
    _ session: UnsafeMutableRawPointer,
    _ bytes: UnsafeMutableRawPointer?,
    _ capacity: UInt32,
    _ countOut: UnsafeMutablePointer<UInt32>,
    _ droppedOut: UnsafeMutablePointer<UInt64>
) -> Int32

@_silgen_name("etos_ish_terminal_write")
func etosISHTerminalWrite(
    _ session: UnsafeMutableRawPointer,
    _ bytes: UnsafeRawPointer?,
    _ length: UInt32,
    _ acceptedOut: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("etos_ish_terminal_finish_input")
func etosISHTerminalFinishInput(_ session: UnsafeMutableRawPointer) -> Int32

@_silgen_name("etos_ish_terminal_resize")
func etosISHTerminalResize(_ session: UnsafeMutableRawPointer, _ columns: UInt16, _ rows: UInt16) -> Int32

@_silgen_name("etos_ish_terminal_interrupt")
func etosISHTerminalInterrupt(_ session: UnsafeMutableRawPointer) -> Int32

@_silgen_name("etos_ish_terminal_cancel")
func etosISHTerminalCancel(_ session: UnsafeMutableRawPointer) -> Int32

@_silgen_name("etos_ish_terminal_result")
func etosISHTerminalResult(
    _ session: UnsafeMutableRawPointer,
    _ terminalID: UnsafeMutablePointer<UInt64>,
    _ reason: UnsafeMutablePointer<Int32>,
    _ exitCode: UnsafeMutablePointer<Int32>,
    _ terminationSignal: UnsafeMutablePointer<Int32>,
    _ linuxError: UnsafeMutablePointer<Int32>,
    _ outputBytes: UnsafeMutablePointer<UInt64>,
    _ droppedBytes: UnsafeMutablePointer<UInt64>,
    _ elapsedMilliseconds: UnsafeMutablePointer<UInt64>
) -> Int32

@_silgen_name("etos_ish_mount_add")
func etosISHMountAdd(
    _ idHigh: UInt64, _ idLow: UInt64, _ access: Int32,
    _ hostDirectoryFD: Int32, _ guestDirectory: UnsafePointer<CChar>
) -> Int32

@_silgen_name("etos_ish_mount_remove")
func etosISHMountRemove(_ idHigh: UInt64, _ idLow: UInt64, _ force: Int32) -> Int32

@_silgen_name("etos_ish_mount_list")
func etosISHMountList(_ context: UnsafeMutableRawPointer?, _ callback: ETOSISHMountInfoCallback) -> Int32

@_silgen_name("etos_ish_mount_lease_acquire")
func etosISHMountLeaseAcquire(
    _ idHigh: UInt64, _ idLow: UInt64,
    _ leaseOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) -> Int32

@_silgen_name("etos_ish_mount_lease_release")
func etosISHMountLeaseRelease(_ lease: UnsafeMutableRawPointer?)

@_silgen_name("etos_ish_guest_file_stat")
func etosISHGuestFileStat(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ context: UnsafeMutableRawPointer?, _ callback: ETOSISHGuestFileInfoCallback
) -> Int32

@_silgen_name("etos_ish_guest_file_list")
func etosISHGuestFileList(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ cursor: UInt64, _ capacity: UInt32,
    _ context: UnsafeMutableRawPointer?, _ callback: ETOSISHGuestFileInfoCallback,
    _ nextCursorOut: UnsafeMutablePointer<UInt64>, _ eofOut: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("etos_ish_guest_file_read")
func etosISHGuestFileRead(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ offset: UInt64, _ bytes: UnsafeMutableRawPointer?, _ capacity: UInt32,
    _ countOut: UnsafeMutablePointer<UInt32>, _ totalSizeOut: UnsafeMutablePointer<UInt64>,
    _ eofOut: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("etos_ish_guest_file_write")
func etosISHGuestFileWrite(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ bytes: UnsafeRawPointer?, _ length: UInt32, _ mode: UInt32
) -> Int32

@_silgen_name("etos_ish_guest_file_copy")
func etosISHGuestFileCopy(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ destination: UnsafePointer<CChar>
) -> Int32

@_silgen_name("etos_ish_guest_file_edit")
func etosISHGuestFileEdit(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ offset: UInt64, _ removedLength: UInt64,
    _ replacement: UnsafeRawPointer?, _ replacementLength: UInt32
) -> Int32

@_silgen_name("etos_ish_guest_file_remove")
func etosISHGuestFileRemove(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ removeFlags: UInt32
) -> Int32

@_silgen_name("etos_ish_guest_file_rename")
func etosISHGuestFileRename(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ destination: UnsafePointer<CChar>
) -> Int32

@_silgen_name("etos_ish_guest_file_mkdir")
func etosISHGuestFileMkdir(
    _ requestID: UInt64, _ path: UnsafePointer<CChar>, _ flags: UInt32,
    _ mode: UInt32, _ mkdirFlags: UInt32
) -> Int32

@_silgen_name("etos_ish_diagnostics_drain")
func etosISHDiagnosticsDrain(
    _ scope: UInt32, _ requestID: UInt64, _ maximumCount: UInt32,
    _ context: UnsafeMutableRawPointer?, _ callback: ETOSISHDiagnosticCallback,
    _ drainedOut: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("etos_ish_diagnostics_clear")
func etosISHDiagnosticsClear(
    _ scope: UInt32, _ requestID: UInt64, _ clearedOut: UnsafeMutablePointer<UInt32>
) -> Int32
