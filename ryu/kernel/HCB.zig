const IRQL = @import("IRQL.zig");
const HAL = @import("hal");

pub const HCB = struct {
    activeKstack: u64 = 0,
    activeUstack: u64 = 0,
    hartID: i32 = 0,
    currentIRQL: IRQL.IRQLs = .IRQL_LOW,
    archData: HAL.Arch.ArchHCBData = HAL.Arch.ArchHCBData{},
    pendingSoftInts: u16 = 0,
    dpcActive: bool = false,
    dpcHead: ?*IRQL.DPC = null,
    dpcTail: ?*IRQL.DPC = null,
};
