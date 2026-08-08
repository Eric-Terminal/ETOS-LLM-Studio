#ifndef ETOS_LOCAL_LINUX_ISH_ADAPTER_H
#define ETOS_LOCAL_LINUX_ISH_ADAPTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t (*etos_ish_rootfs_progress_callback)(
        void *context,
        uint32_t phase,
        uint32_t flags,
        uint64_t compressed_completed,
        uint64_t compressed_total,
        uint64_t extracted_completed,
        uint64_t extracted_total,
        uint64_t entries_completed,
        uint64_t entries_total,
        const char *current_path);

typedef void (*etos_ish_command_stream_callback)(
        void *context,
        uint64_t request_id,
        uint32_t stream,
        const void *bytes,
        uint32_t length,
        int32_t terminal_error);

typedef void (*etos_ish_command_completion_callback)(
        void *context,
        uint64_t request_id,
        int32_t reason,
        int32_t exit_code,
        int32_t termination_signal,
        int32_t linux_error,
        uint64_t stdout_bytes,
        uint64_t stderr_bytes,
        uint64_t elapsed_milliseconds);

typedef void (*etos_ish_mount_info_callback)(
        void *context,
        uint64_t id_high,
        uint64_t id_low,
        int32_t access,
        int32_t state,
        uint64_t active_leases,
        uint64_t active_references,
        const char *guest_directory);

typedef void (*etos_ish_guest_file_info_callback)(
        void *context,
        const char *name,
        uint64_t device,
        uint64_t inode,
        uint64_t size,
        uint64_t blocks,
        uint32_t mode,
        uint32_t link_count,
        uint32_t user_id,
        uint32_t group_id,
        uint32_t block_size,
        int64_t access_time_seconds,
        int64_t modification_time_seconds,
        int64_t status_change_time_seconds,
        uint32_t access_time_nanoseconds,
        uint32_t modification_time_nanoseconds,
        uint32_t status_change_time_nanoseconds);

typedef void (*etos_ish_diagnostic_callback)(
        void *context,
        uint32_t category,
        uint32_t kind,
        uint32_t scope,
        uint32_t architecture,
        uint32_t backend,
        int32_t linux_error,
        int32_t signal,
        uint32_t opcode,
        uint64_t sequence,
        uint64_t request_id,
        uint64_t guest_pc,
        uint64_t syscall_number,
        const char *syscall_name,
        const char *build_identity);

int32_t etos_ish_is_available(void);

int32_t etos_ish_rootfs_install_archive(
        const char *archive_path,
        const char *expected_sha256,
        uint64_t expected_uncompressed_bytes,
        uint64_t expected_entry_count,
        const char *persistent_parent,
        const char *root_name,
        void *context,
        etos_ish_rootfs_progress_callback progress,
        int32_t *disposition_out);

int32_t etos_ish_runtime_start(
        const char *root_data,
        const char *shared_directory,
        const char *socket_prefix,
        const char *hostname,
        const char *boot_command,
        const uint64_t *mount_id_high,
        const uint64_t *mount_id_low,
        const int32_t *mount_access,
        const int32_t *mount_directory_fds,
        const char *const *mount_guest_directories,
        uint32_t mount_count);
int32_t etos_ish_runtime_phase(void);
int32_t etos_ish_runtime_last_error(void);
int32_t etos_ish_runtime_capabilities(
        uint64_t *feature_flags,
        uint32_t *guest_architecture,
        uint32_t *backend,
        uint32_t *public_abi_version);

int32_t etos_ish_command_start(
        uint64_t request_id,
        const char *executable,
        const char *const *arguments,
        uint32_t argument_count,
        const char *const *environment,
        uint32_t environment_count,
        const char *working_directory,
        uint32_t timeout_milliseconds,
        uint64_t output_byte_limit,
        void *context,
        etos_ish_command_stream_callback stream,
        etos_ish_command_completion_callback completed,
        void **session_out);
void etos_ish_command_release(void *session);
int32_t etos_ish_command_write(
        void *session,
        const void *bytes,
        uint32_t length,
        uint32_t *accepted_out);
int32_t etos_ish_command_close_input(void *session);
int32_t etos_ish_command_interrupt(void *session);
int32_t etos_ish_command_cancel(void *session);

int32_t etos_ish_terminal_start(
        uint64_t terminal_id,
        const char *executable,
        const char *const *arguments,
        uint32_t argument_count,
        const char *const *environment,
        uint32_t environment_count,
        const char *working_directory,
        uint16_t columns,
        uint16_t rows,
        void **session_out);
void etos_ish_terminal_release(void *session);
void *etos_ish_terminal_retain(void *session);
int32_t etos_ish_terminal_read(
        void *session,
        void *bytes,
        uint32_t capacity,
        uint32_t *count_out,
        uint64_t *dropped_out);
int32_t etos_ish_terminal_write(
        void *session,
        const void *bytes,
        uint32_t length,
        uint32_t *accepted_out);
int32_t etos_ish_terminal_finish_input(void *session);
int32_t etos_ish_terminal_resize(void *session, uint16_t columns, uint16_t rows);
int32_t etos_ish_terminal_interrupt(void *session);
int32_t etos_ish_terminal_cancel(void *session);
int32_t etos_ish_terminal_result(
        void *session,
        uint64_t *terminal_id,
        int32_t *reason,
        int32_t *exit_code,
        int32_t *termination_signal,
        int32_t *linux_error,
        uint64_t *output_bytes,
        uint64_t *dropped_bytes,
        uint64_t *elapsed_milliseconds);

int32_t etos_ish_mount_add(
        uint64_t id_high,
        uint64_t id_low,
        int32_t access,
        int32_t host_directory_fd,
        const char *guest_directory);
int32_t etos_ish_mount_remove(uint64_t id_high, uint64_t id_low, int32_t force);
int32_t etos_ish_mount_list(void *context, etos_ish_mount_info_callback callback);
int32_t etos_ish_mount_lease_acquire(uint64_t id_high, uint64_t id_low, void **lease_out);
void etos_ish_mount_lease_release(void *lease);

int32_t etos_ish_guest_file_stat(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        void *context,
        etos_ish_guest_file_info_callback callback);
int32_t etos_ish_guest_file_list(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        uint64_t cursor,
        uint32_t capacity,
        void *context,
        etos_ish_guest_file_info_callback callback,
        uint64_t *next_cursor_out,
        int32_t *eof_out);
int32_t etos_ish_guest_file_read(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        uint64_t offset,
        void *bytes,
        uint32_t capacity,
        uint32_t *count_out,
        uint64_t *total_size_out,
        int32_t *eof_out);
int32_t etos_ish_guest_file_write(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        const void *bytes,
        uint32_t length,
        uint32_t mode);
int32_t etos_ish_guest_file_copy(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        const char *destination);
int32_t etos_ish_guest_file_edit(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        uint64_t offset,
        uint64_t removed_length,
        const void *replacement,
        uint32_t replacement_length);
int32_t etos_ish_guest_file_remove(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        uint32_t remove_flags);
int32_t etos_ish_guest_file_rename(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        const char *destination);
int32_t etos_ish_guest_file_mkdir(
        uint64_t request_id,
        const char *path,
        uint32_t flags,
        uint32_t mode,
        uint32_t mkdir_flags);

int32_t etos_ish_diagnostics_drain(
        uint32_t scope,
        uint64_t request_id,
        uint32_t maximum_count,
        void *context,
        etos_ish_diagnostic_callback callback,
        uint32_t *drained_out);
int32_t etos_ish_diagnostics_clear(
        uint32_t scope,
        uint64_t request_id,
        uint32_t *cleared_out);

#ifdef __cplusplus
}
#endif

#endif
