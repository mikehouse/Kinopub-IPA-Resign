// View.environment<T: AnyObject & Observable>(_ object: T?) -> some View
// swiftcc: x0 = object, x1 = Self metadata, x2 = T metadata, x3/x4 = witness tables,
// x20 = self, x8 = indirect result. Record (object, T) and tail-call the original.
    .text
    .p2align 2
    .globl _cinepub_view_env
_cinepub_view_env:
    stp     x29, x30, [sp, #-96]!
    mov     x29, sp
    stp     x0, x1, [sp, #16]
    stp     x2, x3, [sp, #32]
    stp     x4, x5, [sp, #48]
    stp     x6, x7, [sp, #64]
    stp     x8, x20, [sp, #80]
    mov     x1, x2
    bl      _cinepub_record
    ldp     x0, x1, [sp, #16]
    ldp     x2, x3, [sp, #32]
    ldp     x4, x5, [sp, #48]
    ldp     x6, x7, [sp, #64]
    ldp     x8, x20, [sp, #80]
    ldp     x29, x30, [sp], #96
    b       "_$s7SwiftUI4ViewPAAE11environmentyQrqd__SgRld__C11Observation10ObservableRd__lF"
