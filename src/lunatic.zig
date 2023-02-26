const std = @import("std");

pub const Node = struct {
    node_id: u64,

    pub const SpawnOptions = struct {
        config: ?Config = null,
        module: ?Module = null,
        parameters: ?[]const u8 = null,
    };
    pub fn spawn(self: Node, export_name: []const u8, parameters: anytype, options: SpawnOptions) !Process {
        return _spawn(self, export_name, &serialize_parameters(parameters), options);
    }
    fn _spawn(self: Node, export_name: []const u8, parameters: ?[]const u8, options: SpawnOptions) !Process {
        var config_id: i64 = 0;
        if (options.config) |config| {
            config_id = @intCast(i64, config.config_id);
        }
        var module_id: i64 = 0;
        if (options.module) |module| {
            module_id = @intCast(i64, module.module_id);
        }
        var parameters_ptr: u32 = 0;
        var parameters_len: u32 = 0;
        if (parameters) |params| {
            parameters_len = params.len;
            parameters_ptr = if (parameters_len > 0) @ptrToInt(params.ptr) else 0;
        }
        var id: u64 = undefined;
        const result = Internal.Distributed.spawn(
            self.node_id,
            config_id,
            module_id,
            @ptrToInt(export_name.ptr),
            export_name.len,
            parameters_ptr,
            parameters_len,
            @ptrToInt(&id),
        );

        // Something is fishy about error handling code here.
        // The local version of spawn seems to write an error_id
        // to the process id variable. The docs here don't say so
        // but the code appears to do so, but it apperas to do it
        // without returning an error. Examined in lunatic at
        // commit hash d428e931c8dc0504fd2be75db79166d95d50d145

        // this error check looks similar as below but it is different.
        // 1 means NodeDoesNotExist in this case, rather than ProcessDoesNotExist.
        switch (result) {
            0 => return .{ .process_id = id },
            1 => return error.NodeDoesNotExist,
            2 => return error.ModuleDoesNotExist,
            9027 => return error.NodeConnectionError,
            else => {
                std.debug.print("Spawn failed with error {}\n", .{result});
                return error.SpawnFailed;
            },
        }
    }

    pub fn send(self: Node, process: Process) !void {
        const result = Internal.Distributed.send(self.node_id, process.process_id);
        switch (result) {
            0 => return {},
            1 => return error.ProcessDoesNotExist,
            2 => return error.NodeDoesNotExist,
            9027 => return error.NodeConnectionError,
            else => {
                std.debug.print("Send failed with error {}\n", .{result});
                return error.SendFailed;
            },
        }
    }

    pub fn send_receive_skip_search(self: Node, process: Process, wait_on_tag: i64, timeout_duration: u64) !void {
        const result = Internal.Distributed.send_receive_skip_search(self.node_id, process.process_id, wait_on_tag, timeout_duration);
        switch (result) {
            0 => return {},
            1 => return error.ProcessDoesNotExist,
            2 => return error.NodeDoesNotExist,
            9027 => return error.NodeConnectionError,
            else => {
                std.debug.print("Send failed with error {}\n", .{result});
                return error.SendFailed;
            },
        }
    }
};

pub const Module = struct {
    module_id: u64,

    pub fn deinit(self: Module) void {
        Internal.Process.drop_module(self.module_id);
    }
};

pub const Distributed = struct {
    pub fn nodes_count() usize {
        return Internal.Distributed.nodes_count();
    }

    // Return the current node
    pub fn node() Node {
        return .{ .node_id = Internal.Process.node_id() };
    }

    pub fn module() Module {
        return .{ .module_id = Internal.Process.module_id() };
    }

    pub fn get_nodes(nodes: []Node) usize {
        return Internal.Process.get_nodes(
            @ptrToInt(nodes.ptr),
            nodes.len,
        );
    }

    const ExecLookupNodesResult = struct {
        query_id: u64,
        nodes_len: u64,
    };
    pub fn exec_lookup_nodes(query: []const u8) !ExecLookupNodesResult {
        var query_id: u64 = undefined;
        var nodes_len: u64 = undefined;
        var error_id: u64 = undefined;
        const result = Internal.Process.exec_lookup_nodes(
            @ptrToInt(query.ptr),
            query.len,
            @ptrToInt(&query_id),
            @ptrToInt(&nodes_len),
            @ptrToInt(&error_id),
        );
        if (result == 0) {
            return .{
                .query_id = query_id,
                .nodes_len = nodes_len,
            };
        } else {
            // TODO: log error
            Internal.Error.drop(error_id);
            return error.ExecLookupNodesFailed;
        }
    }
    pub fn copy_lookup_nodes_results(query_id: u64, nodes: []Node) !usize {
        var error_id: u64 = undefined;
        const result = Internal.Process.copy_lookup_nodes_results(
            query_id,
            @ptrToInt(nodes.ptr),
            nodes.len,
            &error_id,
        );
        if (result >= 0) {
            return @intCast(usize, result);
        } else {
            // TODO: log error
            Internal.Error.drop(error_id);
            return error.CopyLookupNodesResultsFailed;
        }
    }
};

pub const MessageWriter = struct {
    pub const Error = error{};
    pub const Writer = std.io.Writer(MessageWriter, Error, write);
    pub fn writer(self: MessageWriter) Writer {
        return .{ .context = self };
    }
    pub fn write(self: MessageWriter, bytes: []const u8) Error!usize {
        _ = self;
        const ptr = @ptrToInt(bytes.ptr);
        const len = bytes.len;
        return Internal.Message.write_data(ptr, len);
    }
    pub fn send(self: MessageWriter, process: Process) !void {
        _ = self;
        try Message.send(process);
    }
    pub fn writeModule(self: MessageWriter, module: Module) !void {
        const index = Message.push_module(module);
        try self.writer().writeIntLittle(u64, index);
    }
    pub fn writeTcpStream(self: MessageWriter, socket: Networking.Socket) !void {
        const index = Internal.Message.push_tcp_stream(socket.socket_id);
        try self.writer().writeIntLittle(u64, index);
    }
    pub fn writeTlsStream(self: MessageWriter, stream_id: u64) !void {
        const index = Internal.Message.push_tls_stream(stream_id);
        try self.writer().writeIntLittle(u64, index);
    }
    pub fn writeUdpStream(self: MessageWriter, stream_id: u64) !void {
        const index = Internal.Message.push_udp_stream(stream_id);
        try self.writer().writeIntLittle(u64, index);
    }
};

pub const MessageReader = struct {
    pub const Error = error{};
    pub const Reader = std.io.Reader(MessageReader, Error, read);
    pub fn reader(self: MessageReader) Reader {
        return .{ .context = self };
    }
    pub fn read(self: MessageReader, dst: []u8) Error!usize {
        _ = self;
        const ptr = @ptrToInt(dst.ptr);
        const len = dst.len;
        return Internal.Message.read_data(ptr, len);
    }
    pub fn forward(self: MessageReader, process: Process) !void {
        _ = self;
        Message.seek_data(0);
        try Message.send(process);
    }
    pub fn readModule(self: MessageReader) !Module {
        const index = try self.reader().readIntLittle(u64);
        return Message.take_module(index);
    }
    pub fn readTcpStream(self: MessageReader) !Networking.Socket {
        const index = try self.reader().readIntLittle(u64);
        const socket_id = Internal.Message.take_tcp_stream(index);
        return .{ .socket_id = socket_id };
    }
    pub fn readTlsStream(self: MessageReader) !u64 {
        const index = try self.reader().readIntLittle(u64);
        return Internal.Message.take_tls_stream(index);
    }
    pub fn readUdpStream(self: MessageReader) !u64 {
        const index = try self.reader().readIntLittle(u64);
        return Internal.Message.take_udp_stream(index);
    }
};

pub const Message = struct {
    pub fn create_message_stream(tag: i64, buffer_capacity: u64) MessageWriter {
        create_data(tag, buffer_capacity);
        return .{};
    }
    pub fn create_data(tag: i64, buffer_capacity: u64) void {
        Internal.Message.create_data(tag, buffer_capacity);
    }
    pub fn get_tag() i64 {
        return Internal.Message.get_tag();
    }
    pub fn seek_data(index: u64) void {
        Internal.Message.seek_data(index);
    }
    pub fn data_size() u64 {
        return Internal.Message.data_size();
    }
    pub fn write_data_buffer(buffer: []const u8) void {
        const ptr = @ptrToInt(buffer.ptr);
        const len = buffer.len;
        const written = Internal.Message.write_data(ptr, len);
        if (written != len) {
            @panic("Unable to write all the data to the message");
        }
    }
    pub fn read_data_buffer(buffer: []u8) void {
        const ptr = @ptrToInt(buffer.ptr);
        const len = buffer.len;
        const read = Internal.Message.read_data(ptr, len);
        return read;
    }
    pub fn write_data(comptime T: type, value: T) void {
        const ptr = @ptrToInt(&value);
        const len = @sizeOf(T);
        std.debug.print("write_data({})\n", .{len});
        const written = Internal.Message.write_data(ptr, len);
        if (written != len) {
            @panic("Unable to write all the data to the message");
        }
    }
    pub fn read_data(comptime T: type) T {
        var value: T = undefined;
        const ptr = @ptrToInt(&value);
        const len = @sizeOf(T);
        const read = Internal.Message.read_data(ptr, len);
        if (read != len) {
            @panic("Unable to read all the data from the message");
        }
        return value;
    }
    pub fn send(process: Process) !void {
        const result = Internal.Message.send(process.process_id);
        switch (result) {
            0 => return {},
            else => {
                std.debug.print("Send failed with error {}\n", .{result});
                return error.SendFailed;
            },
        }
    }
    pub fn send_receive_skip_search(process: Process, wait_on_tag: i64, timeout_duration: u64) !void {
        const result = Internal.Message.send_receive_skip_search(process.process_id, wait_on_tag, timeout_duration);
        switch (result) {
            0 => return {},
            9027 => return error.Timeout,
            else => {
                std.debug.print("Send failed with error {}\n", .{result});
                return error.SendFailed;
            },
        }
    }
    pub fn push_module(module: Module) u64 {
        return Internal.Message.push_module(module.module_id);
    }
    pub fn take_module(index: u64) Module {
        const module_id = Internal.Message.take_module(index);
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
        const result = Internal.Message.receive(
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

pub const Metrics = struct {
    pub fn counter(name: []const u8, value: u64) void {
        Internal.Metrics.counter(@ptrToInt(name.ptr), name.len, value);
    }
    pub fn increment_counter(name: []const u8) void {
        Internal.Metrics.increment_counter(@ptrToInt(name.ptr), name.len);
    }
    pub fn gauge(name: []const u8, value: f64) void {
        Internal.Metrics.gauge(@ptrToInt(name.ptr), name.len, value);
    }
    pub fn increment_gauge(name: []const u8, value: f64) void {
        Internal.Metrics.increment_gauge(@ptrToInt(name.ptr), name.len, value);
    }
    pub fn decrement_gauge(name: []const u8, value: f64) void {
        Internal.Metrics.decrement_gauge(@ptrToInt(name.ptr), name.len, value);
    }
    pub fn histogram(name: []const u8) void {
        Internal.Metrics.counter(@ptrToInt(name.ptr), name.len);
    }
};

pub const Config = struct {
    config_id: u64,

    pub fn set_max_memory(self: Config, max_memory: u64) void {
        Internal.Process.config_set_max_memory(self.config_id, max_memory);
    }

    pub fn get_max_memory(self: Config) u64 {
        return Internal.Process.config_get_max_memory(self.config_id);
    }

    pub fn set_max_fuel(self: Config, max_fuel: u64) void {
        Internal.Process.config_set_max_fuel(self.config_id, max_fuel);
    }

    pub fn get_max_fuel(self: Config) u64 {
        return Internal.Process.config_get_max_fuel(self.config_id);
    }

    pub fn set_can_compile_modules(self: Config, can: bool) void {
        Internal.Process.config_set_can_compile_modules(self.config_id, if (can) 1 else 0);
    }

    pub fn get_can_compile_modules(self: Config) bool {
        return Internal.Process.config_get_can_compile_modules(self.config_id) != 0;
    }

    pub fn set_can_create_configs(self: Config, can: bool) void {
        Internal.Process.config_set_can_create_configs(self.config_id, if (can) 1 else 0);
    }

    pub fn get_can_create_configs(self: Config) bool {
        return Internal.Process.config_get_can_create_configs(self.config_id) != 0;
    }

    pub fn set_can_spawn_processes(self: Config, can: bool) void {
        Internal.Process.config_set_can_spawn_processes(self.config_id, if (can) 1 else 0);
    }

    pub fn get_can_spawn_processes(self: Config) bool {
        return Internal.Process.config_get_can_spawn_processes(self.config_id) != 0;
    }

    pub fn add_environment_variable(self: Config, key: []const u8, value: []const u8) void {
        Internal.Wasi.config_add_environment_variable(
            self.config_id,
            @ptrToInt(key.ptr),
            key.len,
            @ptrToInt(value.ptr),
            value.len,
        );
    }

    pub fn add_command_line_argument(self: Config, argument: []const u8) void {
        Internal.Wasi.config_add_command_line_argument(
            self.config_id,
            @ptrToInt(argument.ptr),
            argument.len,
        );
    }

    pub fn preopen_dir(self: Config, directory: []const u8) void {
        Internal.Wasi.config_preopen_dir(
            self.config_id,
            @ptrToInt(directory.ptr),
            directory.len,
        );
    }

    pub fn deinit(self: Config) void {
        Internal.Process.drop_config(self.config_id);
    }
};

pub const Process = struct {
    process_id: u64,

    pub fn environment_id() u64 {
        return Internal.Process.environment_id();
    }
    pub fn process_id() u64 {
        return Internal.Process.process_id();
    }
    pub fn sleep_ms(millis: u64) void {
        Internal.Process.sleep_ms(millis);
    }

    pub const Trap = enum {
        Signal,
        DieAndNotify,
    };
    pub fn die_when_link_dies(trap: Trap) void {
        const trap_id = switch (trap) {
            .Signal => 0,
            .DieAndNotify => 2,
        };
        Internal.Process.die_when_link_dies(trap_id);
    }
    pub fn link(self: Process, tag: i64) void {
        Internal.Process.link(tag, self.process_id);
    }
    pub fn unlink(self: Process) void {
        Internal.Process.unlink(self.process_id);
    }
    pub fn kill(self: Process) void {
        Internal.Process.kill(self.process_id);
    }
    pub fn exists(self: Process) bool {
        return Internal.Process.exists(self.process_id) != 0;
    }

    pub fn compile_module(module_data: []const u8) !Module {
        var id: u64 = undefined;
        const result = Internal.Process.compile_module(
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

    pub fn create_config() !Config {
        const result = Internal.Process.create_config();
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
    pub fn spawn(export_name: []const u8, parameters: anytype, options: SpawnOptions) !Process {
        return _spawn(export_name, &serialize_parameters(parameters), options);
    }
    fn _spawn(export_name: []const u8, parameters: ?[]const u8, options: SpawnOptions) !Process {
        var config_id: i64 = -1;
        if (options.config) |config| {
            config_id = @intCast(i64, config.config_id);
        }
        var module_id: i64 = -1;
        if (options.module) |module| {
            module_id = @intCast(i64, module.module_id);
        }
        var parameters_ptr: u32 = 0;
        var parameters_len: u32 = 0;
        if (parameters) |params| {
            parameters_len = params.len;
            parameters_ptr = if (parameters_len > 0) @ptrToInt(params.ptr) else 0;
        }
        var id: u64 = undefined;
        const result = Internal.Process.spawn(
            options.link,
            config_id,
            module_id,
            @ptrToInt(export_name.ptr),
            export_name.len,
            parameters_ptr,
            parameters_len,
            @ptrToInt(&id),
        );
        if (result == 0) {
            return .{ .process_id = id };
        } else {
            const error_id = id;
            std.debug.print("Spawn failed with error {}\n", .{error_id});
            Internal.Error.drop(error_id);
            return error.SpawnFailed;
        }
    }
};

pub const Networking = struct {
    const CIOVec = struct {
        ptr: [*]const u8,
        len: u32,
    };
    pub const Socket = struct {
        socket_id: u64,

        pub fn read(self: Socket, buffer: []u8) !usize {
            var amount: u32 = undefined;
            const result = Internal.Networking.tcp_read(
                self.socket_id,
                @ptrToInt(buffer.ptr),
                buffer.len,
                @ptrToInt(&amount),
            );
            if (result == 0) {
                if (amount > 0) {
                    return amount;
                }
                return error.EndOfFile;
            } else {
                const error_id = amount;
                std.debug.print("read failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.ReadFailed;
            }
        }

        pub fn peek(self: Socket, buffer: []u8) !usize {
            var amount: u32 = undefined;
            const result = Internal.Networking.tcp_peek(
                self.socket_id,
                @ptrToInt(buffer.ptr),
                buffer.len,
                @ptrToInt(&amount),
            );
            if (result == 0) {
                if (amount > 0) {
                    return amount;
                }
                return error.EndOfFile;
            } else {
                const error_id = amount;
                std.debug.print("peek failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.PeekFailed;
            }
        }

        pub fn write(self: Socket, buffer: []const u8) !usize {
            var amount: u32 = undefined;
            var iovec: CIOVec = .{ .ptr = buffer.ptr, .len = buffer.len };
            const result = Internal.Networking.tcp_write_vectored(
                self.socket_id,
                @ptrToInt(&iovec),
                1,
                @ptrToInt(&amount),
            );
            if (result == 0) {
                if (amount > 0) {
                    return amount;
                }
                return error.EndOfFile;
            } else {
                const error_id = amount;
                std.debug.print("write failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.WriteFailed;
            }
        }

        pub fn clone(self: Socket) Socket {
            return .{ .socket_id = Internal.Networking.clone_tcp_stream(self.socket_id) };
        }

        pub fn set_read_timeout(self: Socket, duration: u64) void {
            Internal.Networking.set_read_timeout(self.socket_id, duration);
        }

        pub fn set_peek_timeout(self: Socket, duration: u64) void {
            Internal.Networking.set_peek_timeout(self.socket_id, duration);
        }

        pub fn get_read_timeout(self: Socket) u64 {
            return Internal.Networking.get_read_timeout(self.socket_id);
        }

        pub fn get_peek_timeout(self: Socket) u64 {
            return Internal.Networking.get_peek_timeout(self.socket_id);
        }

        pub fn flush(self: Socket) !void {
            var error_id: u64 = undefined;
            const result = Internal.Networking.tcp_flush(self.socket_id, @ptrToInt(&error_id));
            if (result != 0) {
                std.debug.print("flush failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.FlushFailed;
            }
        }

        pub fn peer_address(socket: Socket) Address {
            var dns_iterator_id: u64 = undefined;
            const result = Internal.Networking.tcp_peer_addr(socket.socket_id, &dns_iterator_id);
            if (result == 0) {
                var iterator = DnsIterator{ .dns_iterator_id = dns_iterator_id };
                defer iterator.deinit();

                return iterator.next().?;
            } else {
                const error_id = dns_iterator_id;
                std.debug.print("peer_address failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.PeerAddressFailed;
            }
        }

        pub fn deinit(self: Socket) void {
            Internal.Networking.drop_tcp_stream(self.socket_id);
        }
    };
    pub const TlsSocket = struct {
        socket_id: u64,

        pub fn read(self: TlsSocket, buffer: []u8) !usize {
            var amount: u32 = undefined;
            const result = Internal.Networking.tls_read(
                self.socket_id,
                @ptrToInt(buffer.ptr),
                buffer.len,
                @ptrToInt(&amount),
            );
            if (result == 0) {
                if (amount > 0) {
                    return amount;
                }
                return error.EndOfFile;
            } else {
                const error_id = amount;
                std.debug.print("read failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.ReadFailed;
            }
        }

        pub fn write(self: TlsSocket, buffer: []const u8) !usize {
            var amount: u32 = undefined;
            var iovec: CIOVec = .{ .ptr = buffer.ptr, .len = buffer.len };
            const result = Internal.Networking.tls_write_vectored(
                self.socket_id,
                @ptrToInt(&iovec),
                1,
                @ptrToInt(&amount),
            );
            if (result == 0) {
                if (amount > 0) {
                    return amount;
                }
                return error.EndOfFile;
            } else {
                const error_id = amount;
                std.debug.print("write failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.WriteFailed;
            }
        }

        pub fn clone(self: TlsSocket) TlsSocket {
            return .{ .socket_id = Internal.Networking.clone_tls_stream(self.socket_id) };
        }

        pub fn set_tls_read_timeout(self: TlsSocket, duration: u64) void {
            Internal.Networking.set_tls_read_timeout(self.socket_id, duration);
        }

        pub fn set_tls_write_timeout(self: TlsSocket, duration: u64) void {
            Internal.Networking.set_tls_write_timeout(self.socket_id, duration);
        }

        pub fn get_tls_read_timeout(self: TlsSocket) u64 {
            return Internal.Networking.get_tls_read_timeout(self.socket_id);
        }

        pub fn get_tls_write_timeout(self: TlsSocket) u64 {
            return Internal.Networking.get_tls_write_timeout(self.socket_id);
        }

        pub fn flush(self: TlsSocket) !void {
            var error_id: u64 = undefined;
            const result = Internal.Networking.tls_flush(self.socket_id, @ptrToInt(&error_id));
            if (result != 0) {
                std.debug.print("flush failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.FlushFailed;
            }
        }

        pub fn deinit(self: TlsSocket) void {
            Internal.Networking.drop_tls_stream(self.socket_id);
        }
    };
    pub const Listener = struct {
        listener_id: u64,

        pub fn accept(self: Listener) !Socket {
            var fd: u64 = undefined;
            var dns_iterator: u64 = undefined;
            const result = Internal.Networking.tcp_accept(
                self.listener_id,
                @ptrToInt(&fd),
                @ptrToInt(&dns_iterator),
            );
            if (result == 0) {
                Internal.Networking.drop_dns_iterator(dns_iterator);
                return .{ .socket_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("accept failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.BindFailed;
            }
        }
        pub fn local_address(listener: Listener) !Address {
            var dns_iterator_id: u64 = undefined;
            const result = Internal.Networking.tcp_local_addr(
                listener.listener_id,
                @ptrToInt(&dns_iterator_id),
            );
            if (result == 0) {
                var iterator = DnsIterator{ .dns_iterator_id = dns_iterator_id };
                defer iterator.deinit();

                return iterator.next().?;
            } else {
                const error_id = dns_iterator_id;
                std.debug.print("local_address failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.LocalAddressFailed;
            }
        }
        pub fn deinit(self: Listener) void {
            Internal.Networking.drop_tcp_listener(self.listener_id);
        }
    };
    pub const TlsListener = struct {
        listener_id: u64,

        pub fn accept(self: Listener) !TlsSocket {
            var fd: u64 = undefined;
            var dns_iterator: u64 = undefined;
            const result = Internal.Networking.tls_accept(
                self.listener_id,
                @ptrToInt(&fd),
                @ptrToInt(&dns_iterator),
            );
            if (result == 0) {
                Internal.Networking.drop_dns_iterator(dns_iterator);
                return .{ .socket_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("accept failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.BindFailed;
            }
        }
        pub fn local_address(listener: Listener) !Address {
            var dns_iterator_id: u64 = undefined;
            const result = Internal.Networking.tls_local_addr(
                listener.listener_id,
                @ptrToInt(&dns_iterator_id),
            );
            if (result == 0) {
                var iterator = DnsIterator{ .dns_iterator_id = dns_iterator_id };
                defer iterator.deinit();

                return iterator.next().?;
            } else {
                const error_id = dns_iterator_id;
                std.debug.print("local_address failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.LocalAddressFailed;
            }
        }
        pub fn deinit(self: Listener) void {
            Internal.Networking.drop_tls_listener(self.listener_id);
        }
    };
    pub const Address4 = struct {
        address: [4]u8,
    };
    pub const Address6 = struct {
        address: [16]u8,
        flow_info: u32,
        scope_id: u32,
    };
    pub const Address = struct {
        address: union(enum) {
            address4: Address4,
            address6: Address6,
        },
        port: u16,
    };
    pub const DnsIterator = struct {
        dns_iterator_id: u64,

        pub fn next(self: DnsIterator) ?Address {
            var addr_type: u32 = undefined;
            var addr: [16]u8 = undefined;
            var port: u16 = undefined;
            var flow_info: u32 = undefined;
            var scope_id: u32 = undefined;
            const result = Internal.Networking.resolve_next(
                self.dns_iterator_id,
                @ptrToInt(&addr_type),
                @ptrToInt(&addr[0]),
                @ptrToInt(&port),
                @ptrToInt(&flow_info),
                @ptrToInt(&scope_id),
            );
            if (result == 0) {
                return .{
                    .address = switch (addr_type) {
                        4 => .{
                            .address4 = Address4{
                                .address = addr[0..4].*,
                            },
                        },
                        6 => .{
                            .address6 = Address6{
                                .address = addr[0..16].*,
                                .flow_info = flow_info,
                                .scope_id = scope_id,
                            },
                        },
                        else => unreachable,
                    },
                    .port = port,
                };
            } else {
                return null;
            }
        }

        pub fn deinit(self: DnsIterator) void {
            Internal.Networking.drop_dns_iterator(self.dns_iterator_id);
        }
    };
    pub const Dns = struct {
        pub fn resolve(name: []const u8, timeout_duration: u64) !DnsIterator {
            var dns_iterator_id: u64 = undefined;
            const result = Internal.Networking.resolve(
                @ptrToInt(name.ptr),
                name.len,
                timeout_duration,
                @ptrToInt(&dns_iterator_id),
            );
            if (result == 0) {
                return .{ .dns_iterator_id = dns_iterator_id };
            } else {
                const error_id = dns_iterator_id;
                std.debug.print("resolve failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.ResolveFailed;
            }
        }
    };
    pub const Tcp = struct {
        pub fn bind4(address: [4]u8, port: u32) !Listener {
            var fd: u64 = undefined;
            const result = Internal.Networking.tcp_bind(
                4,
                @ptrToInt(&address[0]),
                port,
                0,
                0,
                @ptrToInt(&fd),
            );
            if (result == 0) {
                return .{ .listener_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("bind4 failed with error {}, result {}\n", .{ error_id, result });
                Internal.Error.drop(error_id);
                return error.BindFailed;
            }
        }
        pub fn connect4(address: [4]u8, port: u32, timeout_duration: u64) !Socket {
            var fd: u64 = undefined;
            const result = Internal.Networking.tcp_connect(
                4,
                @ptrToInt(&address[0]),
                port,
                0,
                0,
                timeout_duration,
                @ptrToInt(&fd),
            );
            if (result == 0) {
                return .{ .socket_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("connect4 failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.ConnectFailed;
            }
        }
        pub fn bind6(address: [16]u8, port: u32, flow_info: u32, scope_id: u32) !Listener {
            var fd: u64 = undefined;
            const result = Internal.Networking.tcp_bind(
                6,
                @ptrToInt(address.ptr),
                port,
                flow_info,
                scope_id,
                @ptrToInt(&fd),
            );
            if (result == 0) {
                return .{ .listener_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("bind6 failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.BindFailed;
            }
        }
        pub fn connect6(address: [16]u8, port: u32, flow_info: u32, scope_id: u32, timeout_duration: u64) !Socket {
            var fd: u64 = undefined;
            const result = Internal.Networking.tcp_connect(
                6,
                @ptrToInt(&address[0]),
                port,
                flow_info,
                scope_id,
                timeout_duration,
                @ptrToInt(&fd),
            );
            if (result == 0) {
                return .{ .socket_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("connect6 failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.ConnectFailed;
            }
        }
    };
    pub const Tls = struct {
        pub fn bind4(address: [4]u8, port: u32, certs: []const u8, key: []const u8) !TlsListener {
            var fd: u64 = undefined;
            const result = Internal.Networking.tls_bind(
                4,
                @ptrToInt(&address[0]),
                port,
                0,
                0,
                @ptrToInt(&fd),
                @ptrToInt(certs.ptr),
                certs.len,
                @ptrToInt(key.ptr),
                key.len,
            );
            if (result == 0) {
                return .{ .listener_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("bind4 failed with error {}, result {}\n", .{ error_id, result });
                Internal.Error.drop(error_id);
                return error.BindFailed;
            }
        }
        pub fn connect(address: []const u8, port: u32, timeout_duration: u64, certs: []const u8) !TlsSocket {
            var fd: u64 = undefined;
            const result = Internal.Networking.tls_connect(
                @ptrToInt(address.ptr),
                address.len,
                port,
                timeout_duration,
                @ptrToInt(&fd),
                @ptrToInt(certs.ptr),
                certs.len,
            );
            if (result == 0) {
                return .{ .socket_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("connect4 failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.ConnectFailed;
            }
        }
        pub fn bind6(address: [16]u8, port: u32, flow_info: u32, scope_id: u32, certs: []const u8, key: []const u8) !TlsListener {
            var fd: u64 = undefined;
            const result = Internal.Networking.tls_bind(
                6,
                @ptrToInt(address.ptr),
                port,
                flow_info,
                scope_id,
                @ptrToInt(&fd),
                @ptrToInt(certs.ptr),
                certs.len,
                @ptrToInt(key.ptr),
                key.len,
            );
            if (result == 0) {
                return .{ .listener_id = fd };
            } else {
                const error_id = fd;
                std.debug.print("bind6 failed with error {}\n", .{error_id});
                Internal.Error.drop(error_id);
                return error.BindFailed;
            }
        }
    };
};

pub const Registry = struct {
    pub fn put(name: []const u8, node: Node, process: Process) void {
        Internal.Registry.put(
            @ptrToInt(name.ptr),
            name.len,
            node.node_id,
            process.process_id,
        );
    }

    const GetResult = struct {
        node: Node,
        process: Process,
    };
    pub fn get(name: []const u8) ?GetResult {
        var node_id: u64 = undefined;
        var process_id: u64 = undefined;
        const result = Internal.Registry.get(
            @ptrToInt(name.ptr),
            name.len,
            @ptrToInt(&node_id),
            @ptrToInt(&process_id),
        );
        if (result == 0) {
            return .{
                .node = .{ .node_id = node_id },
                .process = .{ .process_id = process_id },
            };
        } else {
            return null;
        }
    }

    // Note: Must call put() if this does not return a result.
    pub fn get_or_put_later(name: []const u8) ?GetResult {
        var node_id: u64 = undefined;
        var process_id: u64 = undefined;
        const result = Internal.Registry.get_or_put_later(
            @ptrToInt(name.ptr),
            name.len,
            @ptrToInt(&node_id),
            @ptrToInt(&process_id),
        );
        if (result == 0) {
            return .{
                .node = .{ .node_id = node_id },
                .process = .{ .process_id = process_id },
            };
        } else {
            return null;
        }
    }

    pub fn remove(name: []const u8) void {
        Internal.Registry.remove(
            @ptrToInt(name.ptr),
            name.len,
        );
    }
};

pub const Timer = struct {
    timer_id: u64,

    pub fn send_after(process: Process, delay: u64) Timer {
        const timer_id = Internal.Timer.send_after(process.process_id, delay);
        return .{
            .timer_id = timer_id,
        };
    }

    // returns true if timer found, false if it is expired or canceled.
    pub fn cancel(self: Timer) bool {
        const result = Internal.Timer.cancel_timer(self.timer_id);
        return result == 1;
    }
};

pub const Version = struct {
    pub fn major() u32 {
        return Internal.Version.major();
    }

    pub fn minor() u32 {
        return Internal.Version.minor();
    }

    pub fn patch() u32 {
        return Internal.Version.patch();
    }
};

fn parameters_size(comptime ArgsType: type) usize {
    const fields_info = @typeInfo(ArgsType).Struct.fields;
    return fields_info.len * 17;
}

pub fn serialize_parameters(args: anytype) [parameters_size(@TypeOf(args))]u8 {
    const ArgsType = @TypeOf(args);
    var result: [parameters_size(ArgsType)]u8 = undefined;
    var buffer = std.io.fixedBufferStream(&result);
    const stream = buffer.writer();
    const fields_info = @typeInfo(ArgsType).Struct.fields;
    inline for (fields_info) |field| {
        const type_code: u8 = switch (field.type) {
            i32 => 0x7F,
            i64 => 0x7E,
            // TODO: support 0x7B v128
            else => @compileError("Only i32 and i64 are currently supported, found " ++ @typeName(field.type)),
        };
        stream.writeByte(type_code) catch unreachable;
        stream.writeIntLittle(i128, @field(args, field.name)) catch unreachable;
    }
    return result;
}

const Internal = struct {
    const Error = struct {
        pub extern "lunatic::error" fn string_size(error_id: u64) u32;
        pub extern "lunatic::error" fn to_string(error_id: u64, error_str_ptr: u32) void;
        pub extern "lunatic::error" fn drop(error_id: u64) void;
    };
    const Distributed = struct {
        pub extern "lunatic::distributed" fn get_nodes(nodes_ptr: u32, nodes_len: u32) u32;
        pub extern "lunatic::distributed" fn node_id() i64;
        pub extern "lunatic::distributed" fn module_id() i64;
        pub extern "lunatic::distributed" fn spawn(node_id: u64, config_id: i64, module_id: u64, func_strptr: u32, func_str_len: u32, params_ptr: u32, params_len: u32, id_ptr: u32) u32;
        pub extern "lunatic::distributed" fn send(node_id: u64, process_id: u64) u32;
        pub extern "lunatic::distributed" fn send_receive_skip_search(node_id: u64, process_id: u64, wait_on_tag: i64, timeout_duration: u64) u32;
        pub extern "lunatic::distributed" fn exec_lookup_nodes(query_ptr: u32, query_len: u32, query_id_ptr: u32, nodes_len_ptr: u32, error_ptr: u32) u32;
        pub extern "lunatic::distributed" fn copy_lookup_nodes_results(query_id: u64, nodes_ptr: u32, nodes_len: u32, error_ptr: u32) i32;
        pub extern "lunatic::distributed" fn nodes_count() u32;
    };
    const Message = struct {
        pub extern "lunatic::message" fn write_data(data_ptr: u32, data_len: u32) u32;
        pub extern "lunatic::message" fn read_data(data_ptr: u32, data_len: u32) u32;
        pub extern "lunatic::message" fn push_module(module_id: u64) u64;
        pub extern "lunatic::message" fn take_module(index: u64) u64;
        pub extern "lunatic::message" fn send(process_id: u64) u32;
        pub extern "lunatic::message" fn send_receive_skip_search(process_id: u64, wait_on_tag: i64, timeout_duration: u64) u32;
        pub extern "lunatic::message" fn receive(tag_ptr: u32, tag_len: u32, timeout_duration: u64) u32;
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
    };
    const Metrics = struct {
        pub extern "lunatic::metrics" fn counter(name_str_ptr: u32, name_str_len: u32, value: u64) void;
        pub extern "lunatic::metrics" fn increment_counter(name_str_ptr: u32, name_str_len: u32) void;
        pub extern "lunatic::metrics" fn gauge(name_str_ptr: u32, name_str_len: u32, value: f64) void;
        pub extern "lunatic::metrics" fn increment_gauge(name_str_ptr: u32, name_str_len: u32, value: f64) void;
        pub extern "lunatic::metrics" fn decrement_gauge(name_str_ptr: u32, name_str_len: u32, value: f64) void;
        pub extern "lunatic::metrics" fn histogram(name_str_ptr: u32, name_str_len: u32, value: f64) void;
    };
    const Process = struct {
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
        pub extern "lunatic::process" fn environment_id() u64;
        pub extern "lunatic::process" fn process_id() u64;
        pub extern "lunatic::process" fn sleep_ms(millis: u64) void;
    };
    const Networking = struct {
        pub extern "lunatic::networking" fn tcp_bind(addr_type: u32, addr_u8_ptr: u32, port: u32, flow_info: u32, scope_id: u32, id_u64_ptr: u32) u32;
        pub extern "lunatic::networking" fn tcp_local_addr(tcp_listener_id: u64, id_u64_ptr: u32) u32;
        pub extern "lunatic::networking" fn tcp_accept(listener_id: u64, id_u64_ptr: u32, socket_addr_id_ptr: u32) u32;
        pub extern "lunatic::networking" fn tcp_connect(addr_type: u32, addr_u8_ptr: u32, port: u32, flow_info: u32, scope_id: u32, timeout_duration: u64, id_u64_ptr: u32) u32;
        pub extern "lunatic::networking" fn tcp_peer_addr(tcp_stream_id: u64, id_u64_ptr: u32) u32;
        pub extern "lunatic::networking" fn drop_tcp_stream(tcp_stream_id: u64) void;
        pub extern "lunatic::networking" fn drop_tcp_listener(tcp_listener_id: u64) void;
        pub extern "lunatic::networking" fn clone_tcp_stream(tcp_stream_id: u64) u64;
        pub extern "lunatic::networking" fn tcp_peek(stream_id: u64, buffer_ptr: u32, buffer_len: u32, opaque_ptr: u32) u32;
        pub extern "lunatic::networking" fn tcp_read(stream_id: u64, buffer_ptr: u32, buffer_len: u32, opaque_ptr: u32) u32;
        pub extern "lunatic::networking" fn tcp_write_vectored(stream_id: u64, ciovec_array_ptr: u32, ciovec_array_len: u32, opaque_ptr: u32) u32;
        pub extern "lunatic::networking" fn set_read_timeout(stream_id: u64, duration: u64) void;
        pub extern "lunatic::networking" fn set_peek_timeout(stream_id: u64, duration: u64) void;
        pub extern "lunatic::networking" fn get_read_timeout(stream_id: u64) u64;
        pub extern "lunatic::networking" fn get_peek_timeout(stream_id: u64) u64;
        pub extern "lunatic::networking" fn tcp_flush(stream_id: u64, error_id_ptr: u32) u32;

        pub extern "lunatic::networking" fn tls_bind(addr_type: u32, addr_u8_ptr: u32, port: u32, flow_info: u32, scope_id: u32, id_u64_ptr: u32, certs_array_ptr: u32, certs_array_len: u32, keys_array_ptr: u32, keys_array_len: u32) u32;
        pub extern "lunatic::networking" fn tls_local_addr(tls_listener_id: u64, id_u64_ptr: u32) u32;
        pub extern "lunatic::networking" fn tls_accept(listener_id: u64, id_u64_ptr: u32, socket_addr_id_ptr: u32) u32;
        pub extern "lunatic::networking" fn tls_connect(addr_str_ptr: u32, addr_str_len: u32, port: u32, timeout_duration: u64, id_u64_ptr: u32, certs_array_ptr: u32, certs_array_len: u32) u32;
        pub extern "lunatic::networking" fn drop_tls_stream(tls_stream_id: u64) void;
        pub extern "lunatic::networking" fn drop_tls_listener(tls_listener_id: u64) void;
        pub extern "lunatic::networking" fn clone_tls_stream(tls_stream_id: u64) u64;
        pub extern "lunatic::networking" fn tls_read(stream_id: u64, buffer_ptr: u32, buffer_len: u32, opaque_ptr: u32) u32;
        pub extern "lunatic::networking" fn tls_write_vectored(stream_id: u64, ciovec_array_ptr: u32, ciovec_array_len: u32, opaque_ptr: u32) u32;
        pub extern "lunatic::networking" fn set_tls_read_timeout(stream_id: u64, duration: u64) void;
        pub extern "lunatic::networking" fn set_tls_write_timeout(stream_id: u64, duration: u64) void;
        pub extern "lunatic::networking" fn get_tls_read_timeout(stream_id: u64) u64;
        pub extern "lunatic::networking" fn get_tls_write_timeout(stream_id: u64) u64;
        pub extern "lunatic::networking" fn tls_flush(stream_id: u64, error_id_ptr: u32) u32;

        pub extern "lunatic::networking" fn resolve(name_str_ptr: u32, name_str_len: u32, timeout_duration: u64, id_u64_ptr: u32) u32;
        pub extern "lunatic::networking" fn drop_dns_iterator(dns_iter_id: u64) void;
        pub extern "lunatic::networking" fn resolve_next(dns_iter_id: u64, addr_type_u32_ptr: u32, addr_u8_ptr: u32, port_u16_ptr: u32, flow_info_u32_ptr: u32, scope_id_u32_ptr: u32) u32;

        // TODO: udp
    };
    const Registry = struct {
        pub extern "lunatic::registry" fn put(name_str_ptr: u32, name_str_len: u32, node_id: u64, process_id: u64) void;
        pub extern "lunatic::registry" fn get(name_str_ptr: u32, name_str_len: u32, node_id_ptr: u32, process_id_ptr: u32) u32;
        pub extern "lunatic::registry" fn get_or_put_later(name_str_ptr: u32, name_str_len: u32, node_id_ptr: u32, process_id_ptr: u32) u32;
        pub extern "lunatic::registry" fn remove(name_str_ptr: u32, name_str_len: u32) void;
    };
    const Timer = struct {
        pub extern "lunatic::timer" fn send_after(process_id: u64, delay: u64) u64;
        pub extern "lunatic::timer" fn cancel_timer(timer_id: u64) u32;
    };
    const Trap = struct {
        // TODO: expose
        pub extern "lunatic::trap" fn @"catch"(function: i32, pointer: i32) i32;
    };
    const Version = struct {
        pub extern "lunatic::version" fn major() u32;
        pub extern "lunatic::version" fn minor() u32;
        pub extern "lunatic::version" fn patch() u32;
    };
    const Wasi = struct {
        pub extern "lunatic::wasi" fn config_add_environment_variable(config_id: u64, key_ptr: u32, key_len: u32, value_ptr: u32, value_len: u32) void;
        pub extern "lunatic::wasi" fn config_add_command_line_argument(config_id: u64, argument_ptr: u32, argument_len: u32) void;
        pub extern "lunatic::wasi" fn config_preopen_dir(config_id: u64, dir_ptr: u32, dir_len: u32) void;
    };
};
