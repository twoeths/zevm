pub const common = @import("common/root.zig");
pub const vm = @import("vm/root.zig");
pub const Stack = vm.Stack;

test {
    _ = @import("common/root.zig");
    _ = @import("vm/root.zig");
}
