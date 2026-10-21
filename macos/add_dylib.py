# Append an LC_LOAD_DYLIB to a thin arm64 Mach-O (signature must be removed first).
# usage: python3 -I add_dylib.py <binary> <install-name>
import struct
import sys

LC_LOAD_DYLIB = 0xC
LC_CODE_SIGNATURE = 0x1D

path, name = sys.argv[1], sys.argv[2].encode() + b'\0'
data = bytearray(open(path, 'rb').read())
magic, _, _, _, ncmds, sizeofcmds = struct.unpack_from('<IiiIII', data, 0)
assert magic == 0xFEEDFACF, 'not a thin 64-bit Mach-O'

off, first_section = 32, len(data)
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', data, off)
    assert cmd != LC_CODE_SIGNATURE, 'remove the code signature first'
    if cmd == LC_LOAD_DYLIB and data[off + 24:off + 24 + len(name)] == name:
        sys.exit('already present')
    if cmd == 0x19:  # LC_SEGMENT_64: find where section data starts
        for k in range(struct.unpack_from('<I', data, off + 64)[0]):
            sect_off = struct.unpack_from('<I', data, off + 72 + k * 80 + 48)[0]
            if sect_off:
                first_section = min(first_section, sect_off)
    off += cmdsize

cmdsize = (24 + len(name) + 7) & ~7
end = 32 + sizeofcmds
assert end + cmdsize <= first_section, 'no room in header'
assert not any(data[end:end + cmdsize]), 'header padding is not empty'
cmd = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000) + name
data[end:end + cmdsize] = cmd.ljust(cmdsize, b'\0')
struct.pack_into('<II', data, 16, ncmds + 1, sizeofcmds + cmdsize)
open(path, 'wb').write(data)
print('added', name.decode().rstrip('\0'))
