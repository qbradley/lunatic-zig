const std = @import("std");
const lunatic = @import("lunatic-zig");
const Process = lunatic.Process;
const Message = lunatic.Message;

pub fn whoami() void {
    const proc = Process.process_id();
    const env = Process.environment_id();
    std.debug.print("I am process {} in environment {}\n", .{ proc, env });
}

const todo = enum { panic, print, sleep, whoami };

pub export fn child2() void {
    std.debug.print("Waiting for messages\n", .{});
    while (true) {
        switch (Message.receive_all(1000)) {
            .DataMessage => {
                const data_size = Message.data_size();
                std.debug.print("Message of size {}\n", .{data_size});
                const stream = lunatic.MessageReader{};
                const raw_data = stream.reader().readIntLittle(u32) catch unreachable;
                switch (@intToEnum(todo, raw_data)) {
                    .panic => @panic("I died"),
                    .print => std.debug.print("Printing from a child\n", .{}),
                    .sleep => Process.sleep_ms(1000),
                    .whoami => whoami(),
                }
            },
            .SignalMessage => {
                std.debug.print("Signal Message\n", .{});
            },
            .Timeout => {
                std.debug.print("Timeout\n", .{});
            },
        }
    }
    std.debug.print("Done waiting for messages\n", .{});
}

fn sendTodo(process: Process, action: todo) void {
    var stream = Message.create_message_stream(0, @sizeOf(u32));
    stream.writer().writeIntLittle(u32, @enumToInt(action)) catch unreachable;
    stream.send(process) catch unreachable;
}

pub export fn child1(p1: i32) void {
    std.debug.print("Child1 parameter 1 is {}\n", .{p1});

    whoami();

    const id2 = Process.spawn("child2", .{}, .{ .link = 5 }) catch unreachable;

    sendTodo(id2, .whoami);
    sendTodo(id2, .print);
    sendTodo(id2, .sleep);
    sendTodo(id2, .print);
    sendTodo(id2, .panic);

    const proc = Process.process_id();
    std.debug.print("process {} sleeping for 5 seconds\n", .{proc});
    Process.sleep_ms(5000);
    std.debug.print("process {} done sleeping\n", .{proc});
}

pub fn main() !void {
    std.debug.print(
        "Lunatic version {}.{}.{}\n",
        .{
            lunatic.Version.major(),
            lunatic.Version.minor(),
            lunatic.Version.patch(),
        },
    );

    var config = try Process.create_config();
    defer config.deinit();

    config.set_can_spawn_processes(true);

    const id = try Process.spawn("child1", .{@as(i32, 42)}, .{
        .config = config,
    });
    std.debug.print("child is {}\n", .{id.process_id});

    whoami();

    Process.sleep_ms(2000);
    //std.debug.print("Process {} exists {}\n", .{ id.process_id, id.exists() });
    //id.kill();
    //std.debug.print("Process {} exists {}\n", .{ id.process_id, id.exists() });
    Process.sleep_ms(8000);
    //std.debug.print("Process {} exists {}\n", .{ id.process_id, id.exists() });
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
