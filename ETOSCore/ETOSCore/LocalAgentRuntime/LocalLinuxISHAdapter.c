#include "LocalLinuxISHAdapter.h"

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if TARGET_OS_WATCH || (TARGET_OS_IOS && !TARGET_OS_MACCATALYST && !TARGET_OS_VISION)
#define ETOS_ISH_SUPPORTED 1
#include "../../../Dependencies/ish-multiarch/sdk/iSHApple/Headers/iSHApple.h"

// iSH 的静态对象依赖这些系统库。让薄桥对象携带自动链接信息，避免把平台
// 细节扩散到 App target 的工程配置。
__asm__(".linker_option \"-lsqlite3\"\n"
        ".linker_option \"-lresolv\"\n"
        ".linker_option \"-lz\"\n"
        ".linker_option \"-liSHApple\"\n");
#else
#define ETOS_ISH_SUPPORTED 0
#define ETOS_ISH_ENOSYS (-38)
#define ETOS_ISH_EINVAL (-22)
#endif

int32_t etos_ish_is_available(void) {
    return ETOS_ISH_SUPPORTED;
}

#if ETOS_ISH_SUPPORTED

struct etos_rootfs_progress_context {
    void *context;
    etos_ish_rootfs_progress_callback callback;
};

static int32_t etos_rootfs_progress(
        void *opaque,
        const struct ish_apple_rootfs_archive_progress_v1 *progress) {
    struct etos_rootfs_progress_context *bridge = opaque;
    if (bridge == NULL || bridge->callback == NULL)
        return ISH_APPLE_ROOTFS_ARCHIVE_PROGRESS_CONTINUE;
    return bridge->callback(
            bridge->context,
            progress->phase,
            progress->flags,
            progress->compressed_bytes_completed,
            progress->compressed_bytes_total,
            progress->extracted_bytes_completed,
            progress->extracted_bytes_total,
            progress->entries_completed,
            progress->entries_total,
            progress->current_path);
}

struct etos_command_context {
    void *context;
    etos_ish_command_stream_callback stream;
    etos_ish_command_completion_callback completed;
};

static void etos_command_stream(
        void *opaque,
        ish_apple_command_session *session,
        uint64_t request_id,
        uint32_t stream,
        const void *bytes,
        uint32_t length,
        int32_t terminal_error) {
    (void) session;
    struct etos_command_context *bridge = opaque;
    bridge->stream(bridge->context, request_id, stream,
            bytes, length, terminal_error);
}

static void etos_command_completed(
        void *opaque,
        ish_apple_command_session *session,
        const struct ish_apple_command_result_v1 *result) {
    (void) session;
    struct etos_command_context *bridge = opaque;
    bridge->completed(
            bridge->context,
            result->request_id,
            result->reason,
            result->exit_code,
            result->termination_signal,
            result->error,
            result->stdout_bytes,
            result->stderr_bytes,
            result->elapsed_milliseconds);
    free(bridge);
}

static struct ish_apple_mount_id etos_mount_id(uint64_t high, uint64_t low) {
    return (struct ish_apple_mount_id) {.high = high, .low = low};
}

static struct ish_apple_guest_file_request_v1 etos_guest_request(
        uint64_t request_id,
        const char *path,
        uint32_t flags) {
    return (struct ish_apple_guest_file_request_v1) {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(struct ish_apple_guest_file_request_v1),
        .flags = flags,
        .request_id = request_id,
        .path = path,
    };
}

static void etos_deliver_guest_info(
        void *context,
        etos_ish_guest_file_info_callback callback,
        const char *name,
        const struct ish_apple_guest_file_info_v1 *info) {
    callback(
            context,
            name,
            info->device,
            info->inode,
            info->size,
            info->blocks,
            info->mode,
            info->link_count,
            info->user_id,
            info->group_id,
            info->block_size,
            info->access_time_seconds,
            info->modification_time_seconds,
            info->status_change_time_seconds,
            info->access_time_nanoseconds,
            info->modification_time_nanoseconds,
            info->status_change_time_nanoseconds);
}

#endif

int32_t etos_ish_rootfs_install_archive(
        const char *archive_path,
        const char *expected_sha256,
        uint64_t expected_uncompressed_bytes,
        uint64_t expected_entry_count,
        const char *persistent_parent,
        const char *root_name,
        void *context,
        etos_ish_rootfs_progress_callback progress,
        int32_t *disposition_out) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_rootfs_archive_spec_v1 spec = {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(spec),
        .archive_path = archive_path,
        .expected_sha256 = expected_sha256,
        .persistent_parent = persistent_parent,
        .root_name = root_name,
        .expected_uncompressed_bytes = expected_uncompressed_bytes,
        .expected_entry_count = expected_entry_count,
    };
    if (progress == NULL)
        return ish_apple_rootfs_install_archive(&spec, NULL, disposition_out);
    struct etos_rootfs_progress_context bridge = {
        .context = context,
        .callback = progress,
    };
    struct ish_apple_rootfs_archive_callbacks_v1 callbacks = {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(callbacks),
        .context = &bridge,
        .progress = etos_rootfs_progress,
    };
    return ish_apple_rootfs_install_archive(&spec, &callbacks, disposition_out);
#else
    (void) archive_path; (void) expected_sha256;
    (void) expected_uncompressed_bytes; (void) expected_entry_count;
    (void) persistent_parent; (void) root_name; (void) context; (void) progress;
    if (disposition_out != NULL) *disposition_out = 0;
    return ETOS_ISH_ENOSYS;
#endif
}

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
        uint32_t mount_count) {
#if ETOS_ISH_SUPPORTED
    if (mount_count != 0 && (mount_id_high == NULL || mount_id_low == NULL ||
            mount_access == NULL || mount_directory_fds == NULL ||
            mount_guest_directories == NULL))
        return ISH_APPLE_LINUX_EINVAL;
    struct ish_apple_mount_spec_v1 *mounts = NULL;
    if (mount_count != 0) {
        mounts = calloc(mount_count, sizeof(*mounts));
        if (mounts == NULL)
            return ISH_APPLE_LINUX_ENOMEM;
        for (uint32_t index = 0; index < mount_count; index++) {
            mounts[index] = (struct ish_apple_mount_spec_v1) {
                .version = ISH_APPLE_ABI_VERSION,
                .structure_size = sizeof(*mounts),
                .mount_id = etos_mount_id(mount_id_high[index], mount_id_low[index]),
                .access = mount_access[index],
                .host_directory_fd = mount_directory_fds[index],
                .guest_directory = mount_guest_directories[index],
            };
        }
    }
    struct ish_apple_runtime_spec_v2 spec = {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(spec),
        .root_data = root_data,
        .shared_directory = shared_directory,
        .socket_prefix = socket_prefix,
        .hostname = hostname,
        .boot_command = boot_command,
        .mounts = mounts,
        .mount_count = mount_count,
    };
    int32_t status = ish_apple_runtime_start_v2(&spec);
    free(mounts);
    return status;
#else
    (void) root_data; (void) shared_directory; (void) socket_prefix;
    (void) hostname; (void) boot_command; (void) mount_id_high; (void) mount_id_low;
    (void) mount_access; (void) mount_directory_fds;
    (void) mount_guest_directories; (void) mount_count;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_runtime_stop(void) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_runtime_stop();
#else
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_runtime_phase(void) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_runtime_current_phase();
#else
    return 0;
#endif
}

int32_t etos_ish_runtime_last_error(void) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_runtime_last_error();
#else
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_runtime_capabilities(
        uint64_t *feature_flags,
        uint32_t *guest_architecture,
        uint32_t *backend,
        uint32_t *public_abi_version) {
#if ETOS_ISH_SUPPORTED
    if (feature_flags == NULL || guest_architecture == NULL || backend == NULL ||
            public_abi_version == NULL)
        return ISH_APPLE_LINUX_EINVAL;
    struct ish_apple_runtime_capabilities_v1 capabilities = {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(capabilities),
    };
    int32_t status = ish_apple_runtime_copy_capabilities(&capabilities);
    if (status == 0) {
        *feature_flags = capabilities.feature_flags;
        *guest_architecture = capabilities.guest_architecture;
        *backend = capabilities.backend;
        *public_abi_version = capabilities.public_abi_version;
    }
    return status;
#else
    if (feature_flags != NULL) *feature_flags = 0;
    if (guest_architecture != NULL) *guest_architecture = 0;
    if (backend != NULL) *backend = 0;
    if (public_abi_version != NULL) *public_abi_version = 0;
    return ETOS_ISH_ENOSYS;
#endif
}

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
        void **session_out) {
#if ETOS_ISH_SUPPORTED
    if (stream == NULL || completed == NULL || session_out == NULL)
        return ISH_APPLE_LINUX_EINVAL;
    struct etos_command_context *bridge = calloc(1, sizeof(*bridge));
    if (bridge == NULL)
        return ISH_APPLE_LINUX_ENOMEM;
    bridge->context = context;
    bridge->stream = stream;
    bridge->completed = completed;
    struct ish_apple_command_spec_v1 spec = {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(spec),
        .timeout_milliseconds = timeout_milliseconds,
        .request_id = request_id,
        .output_byte_limit = output_byte_limit,
        .executable = executable,
        .arguments = arguments,
        .environment = environment,
        .working_directory = working_directory,
        .argument_count = argument_count,
        .environment_count = environment_count,
    };
    struct ish_apple_command_callbacks_v1 callbacks = {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(callbacks),
        .context = bridge,
        .stream = etos_command_stream,
        .completed = etos_command_completed,
    };
    ish_apple_command_session *session = NULL;
    int32_t status = ish_apple_command_session_start(&spec, &callbacks, &session);
    if (status != 0) {
        free(bridge);
        return status;
    }
    *session_out = session;
    return 0;
#else
    (void) request_id; (void) executable; (void) arguments; (void) argument_count;
    (void) environment; (void) environment_count; (void) working_directory;
    (void) timeout_milliseconds; (void) output_byte_limit; (void) context;
    (void) stream; (void) completed;
    if (session_out != NULL) *session_out = NULL;
    return ETOS_ISH_ENOSYS;
#endif
}

void etos_ish_command_release(void *session) {
#if ETOS_ISH_SUPPORTED
    ish_apple_command_session_release(session);
#else
    (void) session;
#endif
}

int32_t etos_ish_command_write(void *session, const void *bytes, uint32_t length, uint32_t *accepted_out) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_command_session_write_stdin(session, bytes, length, accepted_out);
#else
    (void) session; (void) bytes; (void) length;
    if (accepted_out != NULL) *accepted_out = 0;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_command_close_input(void *session) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_command_session_close_stdin(session);
#else
    (void) session; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_command_interrupt(void *session) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_command_session_interrupt(session);
#else
    (void) session; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_command_cancel(void *session) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_command_session_cancel(session);
#else
    (void) session; return ETOS_ISH_ENOSYS;
#endif
}

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
        void **session_out) {
#if ETOS_ISH_SUPPORTED
    if (session_out == NULL)
        return ISH_APPLE_LINUX_EINVAL;
    struct ish_apple_terminal_spec_v1 spec = {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(spec),
        .columns = columns,
        .rows = rows,
        .terminal_id = terminal_id,
        .executable = executable,
        .arguments = arguments,
        .environment = environment,
        .working_directory = working_directory,
        .argument_count = argument_count,
        .environment_count = environment_count,
    };
    ish_apple_terminal_session *session = NULL;
    int32_t status = ish_apple_terminal_session_start(&spec, &session);
    if (status == 0) *session_out = session;
    return status;
#else
    (void) terminal_id; (void) executable; (void) arguments; (void) argument_count;
    (void) environment; (void) environment_count; (void) working_directory;
    (void) columns; (void) rows;
    if (session_out != NULL) *session_out = NULL;
    return ETOS_ISH_ENOSYS;
#endif
}

void etos_ish_terminal_release(void *session) {
#if ETOS_ISH_SUPPORTED
    ish_apple_terminal_session_release(session);
#else
    (void) session;
#endif
}

void *etos_ish_terminal_retain(void *session) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_terminal_session_retain(session);
#else
    (void) session; return NULL;
#endif
}

int32_t etos_ish_terminal_read(void *session, void *bytes, uint32_t capacity, uint32_t *count_out, uint64_t *dropped_out) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_terminal_session_read_output(session, bytes, capacity, count_out, dropped_out);
#else
    (void) session; (void) bytes; (void) capacity;
    if (count_out != NULL) *count_out = 0;
    if (dropped_out != NULL) *dropped_out = 0;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_terminal_write(void *session, const void *bytes, uint32_t length, uint32_t *accepted_out) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_terminal_session_write_input(session, bytes, length, accepted_out);
#else
    (void) session; (void) bytes; (void) length;
    if (accepted_out != NULL) *accepted_out = 0;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_terminal_finish_input(void *session) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_terminal_session_finish_input(session);
#else
    (void) session; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_terminal_resize(void *session, uint16_t columns, uint16_t rows) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_terminal_session_resize(session, columns, rows);
#else
    (void) session; (void) columns; (void) rows; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_terminal_interrupt(void *session) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_terminal_session_interrupt(session);
#else
    (void) session; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_terminal_cancel(void *session) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_terminal_session_cancel(session);
#else
    (void) session; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_terminal_result(
        void *session,
        uint64_t *terminal_id,
        int32_t *reason,
        int32_t *exit_code,
        int32_t *termination_signal,
        int32_t *linux_error,
        uint64_t *output_bytes,
        uint64_t *dropped_bytes,
        uint64_t *elapsed_milliseconds) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_terminal_result_v1 result = {0};
    int32_t status = ish_apple_terminal_session_copy_result(session, &result);
    if (status == 0) {
        *terminal_id = result.terminal_id;
        *reason = result.reason;
        *exit_code = result.exit_code;
        *termination_signal = result.termination_signal;
        *linux_error = result.error;
        *output_bytes = result.output_bytes;
        *dropped_bytes = result.dropped_bytes;
        *elapsed_milliseconds = result.elapsed_milliseconds;
    }
    return status;
#else
    (void) session; (void) terminal_id; (void) reason; (void) exit_code;
    (void) termination_signal; (void) linux_error; (void) output_bytes;
    (void) dropped_bytes; (void) elapsed_milliseconds;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_mount_add(uint64_t high, uint64_t low, int32_t access, int32_t fd, const char *guest) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_mount_spec_v1 spec = {
        .version = ISH_APPLE_ABI_VERSION,
        .structure_size = sizeof(spec),
        .mount_id = etos_mount_id(high, low),
        .access = access,
        .host_directory_fd = fd,
        .guest_directory = guest,
    };
    return ish_apple_mount_add(&spec);
#else
    (void) high; (void) low; (void) access; (void) fd; (void) guest;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_mount_remove(uint64_t high, uint64_t low, int32_t force) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_mount_remove(etos_mount_id(high, low), force ? ISH_APPLE_MOUNT_REMOVE_FORCE : 0);
#else
    (void) high; (void) low; (void) force; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_mount_list(void *context, etos_ish_mount_info_callback callback) {
#if ETOS_ISH_SUPPORTED
    if (callback == NULL) return ISH_APPLE_LINUX_EINVAL;
    uint32_t count = 0;
    int32_t status = ish_apple_mount_list(NULL, 0, &count);
    if (status != 0 || count == 0) return status;
    struct ish_apple_mount_info_v1 *entries = calloc(count, sizeof(*entries));
    if (entries == NULL) return ISH_APPLE_LINUX_ENOMEM;
    for (uint32_t index = 0; index < count; index++) {
        entries[index].version = ISH_APPLE_ABI_VERSION;
        entries[index].structure_size = sizeof(*entries);
    }
    status = ish_apple_mount_list(entries, count, &count);
    for (uint32_t index = 0; status == 0 && index < count; index++) {
        char path[ISH_APPLE_MOUNT_GUEST_DIRECTORY_BYTES_MAX + 1];
        uint32_t required = 0;
        status = ish_apple_mount_copy_guest_directory(entries[index].mount_id,
                path, sizeof(path), &required);
        if (status == 0)
            callback(context, entries[index].mount_id.high, entries[index].mount_id.low,
                    entries[index].access, entries[index].state,
                    entries[index].active_leases, entries[index].active_references, path);
    }
    free(entries);
    return status;
#else
    (void) context; (void) callback; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_mount_lease_acquire(uint64_t high, uint64_t low, void **lease_out) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_mount_lease_acquire(etos_mount_id(high, low),
            (ish_apple_mount_lease **) lease_out);
#else
    (void) high; (void) low;
    if (lease_out != NULL) *lease_out = NULL;
    return ETOS_ISH_ENOSYS;
#endif
}

void etos_ish_mount_lease_release(void *lease) {
#if ETOS_ISH_SUPPORTED
    ish_apple_mount_lease_release(lease);
#else
    (void) lease;
#endif
}

int32_t etos_ish_guest_file_stat(uint64_t id, const char *path, uint32_t flags,
        void *context, etos_ish_guest_file_info_callback callback) {
#if ETOS_ISH_SUPPORTED
    if (callback == NULL) return ISH_APPLE_LINUX_EINVAL;
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    struct ish_apple_guest_file_info_v1 info = {0};
    int32_t status = ish_apple_guest_file_stat(&request, &info);
    if (status == 0) etos_deliver_guest_info(context, callback, NULL, &info);
    return status;
#else
    (void) id; (void) path; (void) flags; (void) context; (void) callback;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_guest_file_list(uint64_t id, const char *path, uint32_t flags,
        uint64_t cursor, uint32_t capacity, void *context,
        etos_ish_guest_file_info_callback callback, uint64_t *next, int32_t *eof) {
#if ETOS_ISH_SUPPORTED
    if (callback == NULL || capacity == 0 || next == NULL || eof == NULL)
        return ISH_APPLE_LINUX_EINVAL;
    struct ish_apple_guest_file_directory_entry_v1 *entries = calloc(capacity, sizeof(*entries));
    if (entries == NULL) return ISH_APPLE_LINUX_ENOMEM;
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    uint32_t count = 0;
    int32_t status = ish_apple_guest_file_list(&request, cursor, entries,
            capacity, &count, next, eof);
    for (uint32_t index = 0; status == 0 && index < count; index++)
        etos_deliver_guest_info(context, callback, entries[index].name, &entries[index].info);
    free(entries);
    return status;
#else
    (void) id; (void) path; (void) flags; (void) cursor; (void) capacity;
    (void) context; (void) callback; (void) next; (void) eof;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_guest_file_read(uint64_t id, const char *path, uint32_t flags,
        uint64_t offset, void *bytes, uint32_t capacity, uint32_t *count,
        uint64_t *total, int32_t *eof) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    return ish_apple_guest_file_read(&request, offset, bytes, capacity, count, total, eof);
#else
    (void) id; (void) path; (void) flags; (void) offset; (void) bytes; (void) capacity;
    (void) count; (void) total; (void) eof; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_guest_file_write(uint64_t id, const char *path, uint32_t flags,
        const void *bytes, uint32_t length, uint32_t mode) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    return ish_apple_guest_file_write(&request, bytes, length, mode);
#else
    (void) id; (void) path; (void) flags; (void) bytes; (void) length; (void) mode;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_guest_file_copy(uint64_t id, const char *path, uint32_t flags,
        const char *destination) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    return ish_apple_guest_file_copy(&request, destination);
#else
    (void) id; (void) path; (void) flags; (void) destination;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_guest_file_edit(uint64_t id, const char *path, uint32_t flags,
        uint64_t offset, uint64_t removed, const void *replacement, uint32_t length) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    return ish_apple_guest_file_edit(&request, offset, removed, replacement, length);
#else
    (void) id; (void) path; (void) flags; (void) offset; (void) removed;
    (void) replacement; (void) length; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_guest_file_remove(uint64_t id, const char *path, uint32_t flags, uint32_t remove_flags) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    return ish_apple_guest_file_remove(&request, remove_flags);
#else
    (void) id; (void) path; (void) flags; (void) remove_flags; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_guest_file_rename(uint64_t id, const char *path, uint32_t flags, const char *destination) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    return ish_apple_guest_file_rename(&request, destination);
#else
    (void) id; (void) path; (void) flags; (void) destination; return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_guest_file_mkdir(uint64_t id, const char *path, uint32_t flags, uint32_t mode, uint32_t mkdir_flags) {
#if ETOS_ISH_SUPPORTED
    struct ish_apple_guest_file_request_v1 request = etos_guest_request(id, path, flags);
    return ish_apple_guest_file_mkdir(&request, mode, mkdir_flags);
#else
    (void) id; (void) path; (void) flags; (void) mode; (void) mkdir_flags;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_diagnostics_drain(uint32_t scope, uint64_t request_id,
        uint32_t maximum, void *context, etos_ish_diagnostic_callback callback,
        uint32_t *drained_out) {
#if ETOS_ISH_SUPPORTED
    if (callback == NULL || maximum == 0 || drained_out == NULL)
        return ISH_APPLE_LINUX_EINVAL;
    uint32_t pending = 0;
    int32_t status = ish_apple_diagnostics_drain(scope, request_id, NULL, 0, &pending);
    if (status != 0 || pending == 0) {
        *drained_out = 0;
        return status;
    }
    uint32_t capacity = pending < maximum ? pending : maximum;
    struct ish_apple_diagnostic_event_v1 *events = calloc(capacity, sizeof(*events));
    if (events == NULL) return ISH_APPLE_LINUX_ENOMEM;
    for (uint32_t index = 0; index < capacity; index++) {
        events[index].version = ISH_APPLE_ABI_VERSION;
        events[index].structure_size = sizeof(*events);
    }
    uint32_t count = 0;
    status = ish_apple_diagnostics_drain(scope, request_id, events, capacity, &count);
    for (uint32_t index = 0; status == 0 && index < count; index++) {
        char process_name[ISH_APPLE_DIAGNOSTIC_PROCESS_NAME_BYTES_MAX + 1];
        char syscall_name[ISH_APPLE_DIAGNOSTIC_SYSCALL_NAME_BYTES_MAX + 1];
        char build_identity[ISH_APPLE_DIAGNOSTIC_BUILD_IDENTITY_BYTES_MAX + 1];
        memcpy(process_name, events[index].process_name,
                ISH_APPLE_DIAGNOSTIC_PROCESS_NAME_BYTES_MAX);
        memcpy(syscall_name, events[index].syscall_name,
                ISH_APPLE_DIAGNOSTIC_SYSCALL_NAME_BYTES_MAX);
        memcpy(build_identity, events[index].build_identity,
                ISH_APPLE_DIAGNOSTIC_BUILD_IDENTITY_BYTES_MAX);
        process_name[ISH_APPLE_DIAGNOSTIC_PROCESS_NAME_BYTES_MAX] = '\0';
        syscall_name[ISH_APPLE_DIAGNOSTIC_SYSCALL_NAME_BYTES_MAX] = '\0';
        build_identity[ISH_APPLE_DIAGNOSTIC_BUILD_IDENTITY_BYTES_MAX] = '\0';
        callback(context, events[index].category, events[index].kind,
                events[index].scope, events[index].architecture, events[index].backend,
                events[index].linux_error, events[index].signal, events[index].opcode,
                events[index].sequence, events[index].request_id, events[index].guest_pc,
                events[index].syscall_number, events[index].guest_process_id,
                events[index].guest_thread_group_id, process_name, syscall_name,
                build_identity);
    }
    *drained_out = status == 0 ? count : 0;
    free(events);
    return status;
#else
    (void) scope; (void) request_id; (void) maximum; (void) context; (void) callback;
    if (drained_out != NULL) *drained_out = 0;
    return ETOS_ISH_ENOSYS;
#endif
}

int32_t etos_ish_diagnostics_clear(uint32_t scope, uint64_t request_id, uint32_t *cleared_out) {
#if ETOS_ISH_SUPPORTED
    return ish_apple_diagnostics_clear(scope, request_id, cleared_out);
#else
    (void) scope; (void) request_id;
    if (cleared_out != NULL) *cleared_out = 0;
    return ETOS_ISH_ENOSYS;
#endif
}
