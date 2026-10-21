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

// _FrameLayout.init(width:height:alignment:)
// swiftcc: x0/w1 = width and its nil flag, x2/w3 = height and its nil flag, x4/x5 = alignment,
// x8 = indirect result. cinepub_frame_zoom may change the saved width/height and nil flags,
// then the original runs.
    .p2align 2
    .globl _cinepub_frame_layout
_cinepub_frame_layout:
    stp     x29, x30, [sp, #-96]!
    mov     x29, sp
    stp     x0, x1, [sp, #16]
    stp     x2, x3, [sp, #32]
    stp     x4, x5, [sp, #48]
    stp     x6, x7, [sp, #64]
    stp     x8, x20, [sp, #80]
    add     x0, sp, #16
    add     x1, sp, #24
    add     x2, sp, #32
    add     x3, sp, #40
    mov     x4, x30
    bl      _cinepub_frame_zoom
    ldp     x0, x1, [sp, #16]
    ldp     x2, x3, [sp, #32]
    ldp     x4, x5, [sp, #48]
    ldp     x6, x7, [sp, #64]
    ldp     x8, x20, [sp, #80]
    ldp     x29, x30, [sp], #96
    b       "_$s7SwiftUI12_FrameLayoutV5width6height9alignmentAC12CoreGraphics7CGFloatVSg_AjA9AlignmentVtcfC"

// Font replacements: remember who asked for the font (x16 is scratch), then run the Swift replacement.
.macro font_tramp name
    .p2align 2
    .globl _cinepub_font_\name\()_tramp
_cinepub_font_\name\()_tramp:
    adrp    x16, _cinepub_font_caller@PAGE
    str     x30, [x16, _cinepub_font_caller@PAGEOFF]
    b       _cinepub_font_\name
.endm

    font_tramp system
    font_tramp system_optional
    font_tramp largeTitle
    font_tramp title
    font_tramp title2
    font_tramp title3
    font_tramp headline
    font_tramp body
    font_tramp callout
    font_tramp subheadline
    font_tramp footnote
    font_tramp caption
    font_tramp caption2
