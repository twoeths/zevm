pub const common = @import("common");
pub const vm = @import("vm/root.zig");
pub const Stack = vm.Stack;
pub const Contract = vm.Contract;
pub const Memory = vm.Memory;
pub const ScopeContext = vm.ScopeContext;

test {
    _ = @import("common");
    _ = @import("vm/root.zig");
}
