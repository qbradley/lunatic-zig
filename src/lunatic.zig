const std = @import("std");

pub const Distributed = struct {
    pub extern "lunatic::distributed" fn node_id() i64;
};

pub const Message = struct {
    const Internal = struct {
        pub extern "lunatic::message" fn write_data(data_ptr: u32, data_len: u32) u32;
        pub extern "lunatic::message" fn read_data(data_ptr: u32, data_len: u32) u32;
        pub extern "lunatic::message" fn push_module(module_id: u64) u64;
        pub extern "lunatic::message" fn take_module(index: u64) u64;
        pub extern "lunatic::message" fn send(process_id: u64) u32;
        pub extern "lunatic::message" fn send_receive_skip_search(process_id: u64, wait_on_tag: i64, timeout_duration: u64) u32;
        pub extern "lunatic::message" fn receive(tag_ptr: u32, tag_len: u32, timeout_duration: u64) u32;
    };
    pub extern "lunatic::message" fn push_tcp_stream(stream_id: u64) u64;
    pub extern "lunatic::message" fn take_tcp_stream(index: u64) u64;
    pub extern "lunatic::message" fn push_tls_stream(stream_id: u64) u64;
    pub extern "lunatic::message" fn take_tls_stream(index: u64) u64;
    pub extern "lunatic::message" fn push_udp_stream(socket_id: u64) u64;
    pub extern "lunatic::message" fn take_udp_stream(index: u64) u64;

    pub extern "lunatic::message" fn create_data(tag: i64, buffer_capacity: u64) void;
    pub extern "lunatic::message" fn get_tag() i64;
    pub extern "lunatic::message" fn seek_data(index: u64) void;
    pub extern "lunatic::message" fn data_size() u64;
    pub fn write_data(comptime T: type, value: T) void {
        const ptr = @ptrToInt(&value);
        const len = @sizeOf(T);
        std.debug.print("write_data({})\n", .{len});
        const written = Internal.write_data(ptr, len);
        if (written != len) {
            @panic("Unable to write all the data to the message");
        }
    }
    pub fn read_data(comptime T: type) T {
        var value: T = undefined;
        const ptr = @ptrToInt(&value);
        const len = @sizeOf(T);
        const read = Internal.read_data(ptr, len);
        if (read != len) {
            @panic("Unable to read all the data from the message");
        }
        return value;
    }
    pub fn send(process: Process) void {
        _ = Internal.send(process.process_id);
    }
    pub fn send_receive_skip_search(process: Process, wait_on_tag: i64, timeout_duration: u64) void {
        _ = Internal.send(process.process_id, wait_on_tag, timeout_duration);
    }
    pub fn push_module(module: Process.Module) u64 {
        return Internal.push_module(module.module_id);
    }
    pub fn take_module(index: u64) Process.Module {
        const module_id = Internal.take_module(index);
        return .{
            .module_id = module_id,
        };
    }

    pub const ReceiveResult = enum {
        DataMessage,
        SignalMessage,
        Timeout,
    };
    pub fn receive(tags: []const i64, timeout_duration: u64) ReceiveResult {
        const result = Internal.receive(
            @ptrToInt(tags.ptr),
            tags.len,
            timeout_duration,
        );
        switch (result) {
            0 => return .DataMessage,
            1 => return .SignalMessage,
            9027 => return .Timeout,
            else => unreachable,
        }
    }
    pub fn receive_all(timeout_duration: u64) ReceiveResult {
        return receive(&.{}, timeout_duration);
    }
};

pub const Process = struct {
    process_id: u64,

    const Self = @This();

    const Internal = struct {
        pub extern "lunatic::process" fn spawn(link: i64, config_id: i64, module_id: i64, func_strptr: u32, func_str_len: u32, params_ptr: u32, params_len: u32, id_ptr: u32) u32;
        pub extern "lunatic::process" fn create_config() i64;
        pub extern "lunatic::process" fn drop_config(config_id: u64) void;
        pub extern "lunatic::process" fn config_set_max_memory(config_id: u64, max_memory: u64) void;
        pub extern "lunatic::process" fn config_get_max_memory(config_id: u64) u64;
        pub extern "lunatic::process" fn config_set_max_fuel(config_id: u64, max_fuel: u64) void;
        pub extern "lunatic::process" fn config_get_max_fuel(config_id: u64) u64;
        pub extern "lunatic::process" fn config_set_can_compile_modules(config_id: u64, can: u32) void;
        pub extern "lunatic::process" fn config_can_compile_modules(config_id: u64) u32;
        pub extern "lunatic::process" fn config_set_can_create_configs(config_id: u64, can: u32) void;
        pub extern "lunatic::process" fn config_can_create_configs(config_id: u64) u32;
        pub extern "lunatic::process" fn config_set_can_spawn_processes(config_id: u64, can: u32) void;
        pub extern "lunatic::process" fn config_can_spawn_processes(config_id: u64) u32;
        pub extern "lunatic::process" fn compile_module(module_data_ptr: u32, module_data_len: u32, id_ptr: u32) i32;
        pub extern "lunatic::process" fn drop_module(module_id: u64) void;
        pub extern "lunatic::process" fn link(tag: i64, process_id: u64) void;
        pub extern "lunatic::process" fn unlink(process_id: u64) void;
        pub extern "lunatic::process" fn kill(process_id: u64) void;
        pub extern "lunatic::process" fn exists(process_id: u64) i32;
        pub extern "lunatic::process" fn die_when_link_dies(trap: u32) void;
    };

    pub extern "lunatic::process" fn environment_id() u64;
    pub extern "lunatic::process" fn process_id() u64;
    pub extern "lunatic::process" fn sleep_ms(millis: u64) void;

    pub const Trap = enum {
        Signal,
        DieAndNotify,
    };
    pub fn die_when_link_dies(trap: Trap) void {
        const trap_id = switch (trap) {
            .Signal => 0,
            .DieAndNotify => 2,
        };
        Internal.die_when_link_dies(trap_id);
    }
    pub fn link(self: Self, tag: i64) void {
        Internal.link(tag, self.process_id);
    }
    pub fn unlink(self: Self) void {
        Internal.unlink(self.process_id);
    }
    pub fn kill(self: Self) void {
        Internal.kill(self.process_id);
    }
    pub fn exists(self: Self) bool {
        return Internal.exists(self.process_id) != 0;
    }

    pub const Module = struct {
        module_id: u64,

        pub fn deinit(self: Module) void {
            Internal.drop_module(self.module_id);
        }
    };

    pub fn compile_module(module_data: []const u8) !u64 {
        var id: u64 = undefined;
        const result = Internal.compile_module(
            @ptrToInt(module_data.ptr),
            module_data.len,
            @ptrToInt(&id),
        );
        if (result == 0) {
            return .{
                .module_id = id,
            };
        } else {
            return error.CompileModuleFailed;
        }
    }

    pub const Config = struct {
        config_id: u64,

        pub fn set_max_memory(self: Config, max_memory: u64) void {
            Internal.config_set_max_memory(self.config_id, max_memory);
        }
        pub fn get_max_memory(self: Config) u64 {
            return Internal.config_get_max_memory(self.config_id);
        }
        pub fn set_max_fuel(self: Config, max_fuel: u64) void {
            Internal.config_set_max_fuel(self.config_id, max_fuel);
        }
        pub fn get_max_fuel(self: Config) u64 {
            return Internal.config_get_max_fuel(self.config_id);
        }
        pub fn set_can_compile_modules(self: Config, can: bool) void {
            Internal.config_set_can_compile_modules(self.config_id, if (can) 1 else 0);
        }
        pub fn get_can_compile_modules(self: Config) bool {
            return Internal.config_get_can_compile_modules(self.config_id) != 0;
        }
        pub fn set_can_create_configs(self: Config, can: bool) void {
            Internal.config_set_can_create_configs(self.config_id, if (can) 1 else 0);
        }
        pub fn get_can_create_configs(self: Config) bool {
            return Internal.config_get_can_create_configs(self.config_id) != 0;
        }
        pub fn set_can_spawn_processes(self: Config, can: bool) void {
            Internal.config_set_can_spawn_processes(self.config_id, if (can) 1 else 0);
        }
        pub fn get_can_spawn_processes(self: Config) bool {
            return Internal.config_get_can_spawn_processes(self.config_id) != 0;
        }

        pub fn deinit(self: Config) void {
            Internal.drop_config(self.config_id);
        }
    };

    pub fn create_config() !Config {
        const result = Internal.create_config();
        if (result < 0) {
            return error.PermissionDenied;
        }
        return .{ .config_id = @intCast(u64, result) };
    }

    pub const SpawnOptions = struct {
        link: i64 = 0,
        config: ?Config = null,
        module: ?Module = null,
    };
    pub fn spawn(export_name: []const u8, options: SpawnOptions) !Self {
        var config_id: i64 = -1;
        if (options.config) |config| {
            config_id = @intCast(i64, config.config_id);
        }
        var module_id: i64 = -1;
        if (options.module) |module| {
            module_id = @intCast(i64, module.module_id);
        }
        var id: u64 = undefined;
        const result = Internal.spawn(
            options.link,
            config_id,
            module_id,
            @ptrToInt(export_name.ptr),
            export_name.len,
            0,
            0,
            @ptrToInt(&id),
        );
        if (result == 0) {
            return .{ .process_id = id };
        } else {
            std.debug.print("Spawn failed with error {}\n", .{id});
            return error.SpawnFailed;
        }
    }
};
