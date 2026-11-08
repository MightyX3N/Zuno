#!/usr/bin/env python3
"""Give a Windows .exe Zuno's icon and name (version info), without any Windows tools.

  python3 scripts/set-exe-resources.py IN.exe OUT.exe ICON.ico "File description" "Product name" VERSION

Windows shows the version info's FileDescription as the app name in notifications and Task
Manager, and the first icon group as the file's icon in Explorer.

How: the existing resource tree is read, the icons and the version info are replaced, and the
new tree is written to a new section at the end of the image; the resource directory entry
points to it (the old section stays, unused). Run it on love.exe BEFORE appending the game
archive: the archive must stay at the very end of the file.
"""
import struct, sys

RT_ICON, RT_GROUP_ICON, RT_VERSION = 3, 14, 16


def align(n, a):
    return (n + a - 1) // a * a


class PE:
    def __init__(self, data):
        self.d = bytearray(data)
        d = self.d
        self.pe = struct.unpack_from('<I', d, 0x3C)[0]
        assert d[self.pe:self.pe + 4] == b'PE\0\0', 'not a PE file'
        self.nsec_off = self.pe + 6
        self.nsec = struct.unpack_from('<H', d, self.nsec_off)[0]
        optsz = struct.unpack_from('<H', d, self.pe + 20)[0]
        self.opt = self.pe + 24
        assert struct.unpack_from('<H', d, self.opt)[0] == 0x20B, 'only 64-bit images'
        self.salign, self.falign = struct.unpack_from('<II', d, self.opt + 32)
        self.sizehdr = struct.unpack_from('<I', d, self.opt + 60)[0]
        self.dd = self.opt + 112
        self.sh = self.opt + optsz
        self.sections = []
        for i in range(self.nsec):
            name, vs, va, rs, rp = struct.unpack_from('<8sIIII', d, self.sh + i * 40)
            self.sections.append((name, vs, va, rs, rp))
        sec_rva, sec_size = struct.unpack_from('<II', d, self.dd + 4 * 8)
        assert sec_size == 0, 'signed files are not supported'

    def rva_to_off(self, rva):
        for name, vs, va, rs, rp in self.sections:
            if va <= rva < va + max(vs, rs):
                return rva - va + rp
        raise ValueError('rva outside sections')

    def read_resources(self):
        rva, size = struct.unpack_from('<II', self.d, self.dd + 2 * 8)
        base = self.rva_to_off(rva)
        d = self.d

        def name_of(entry_name):
            if entry_name & 0x80000000:
                off = base + (entry_name & 0x7FFFFFFF)
                n = struct.unpack_from('<H', d, off)[0]
                return d[off + 2:off + 2 + n * 2].decode('utf-16-le')
            return entry_name

        def walk(off, depth):
            named, ids = struct.unpack_from('<HH', d, base + off + 12)
            out = {}
            for i in range(named + ids):
                nm, target = struct.unpack_from('<II', d, base + off + 16 + i * 8)
                key = name_of(nm)
                if target & 0x80000000:
                    out[key] = walk(target & 0x7FFFFFFF, depth + 1)
                else:
                    drva, dsize, cp, _ = struct.unpack_from('<IIII', d, base + target)
                    o = self.rva_to_off(drva)
                    out[key] = (bytes(d[o:o + dsize]), cp)
            return out
        return walk(0, 0)

    def add_resource_section(self, tree):
        d = self.d
        # the new section goes after the last one
        last_end_va = max(va + align(max(vs, rs), self.salign) for _, vs, va, rs, _ in self.sections)
        new_va = last_end_va
        blob = build_tree(tree, new_va)
        raw_size = align(len(blob), self.falign)
        raw_ptr = align(len(d), self.falign)
        hdr_off = self.sh + self.nsec * 40
        first_raw = min(rp for _, _, _, rs, rp in self.sections if rs)
        assert hdr_off + 40 <= min(self.sizehdr, first_raw), 'no room for another section header'
        d.extend(b'\0' * (raw_ptr - len(d)))
        d.extend(blob + b'\0' * (raw_size - len(blob)))
        struct.pack_into('<8sIIIIIIHHI', d, hdr_off, b'.zrsrc\0\0', len(blob), new_va, raw_size, raw_ptr,
                         0, 0, 0, 0, 0x40000040)  # initialized data, readable
        struct.pack_into('<H', d, self.nsec_off, self.nsec + 1)
        struct.pack_into('<I', d, self.opt + 56, new_va + align(len(blob), self.salign))  # SizeOfImage
        struct.pack_into('<II', d, self.dd + 2 * 8, new_va, len(blob))
        struct.pack_into('<I', d, self.opt + 64, 0)  # checksum (not needed for .exe)


def build_tree(tree, section_rva):
    """Serialize {type: {name: {lang: (bytes, codepage)}}} into a .rsrc blob."""
    dirs, strings, entries, datas = bytearray(), bytearray(), [], []
    # layout: all directories (breadth first), then name strings, then data entries, then data
    nodes = []

    def sort_key(k):
        return (0, k) if isinstance(k, str) else (1, k)

    def collect(node):
        idx = len(nodes)
        nodes.append(node)
        return idx
    order = [tree]
    i = 0
    while i < len(order):
        node = order[i]
        for k in sorted(node, key=sort_key):
            if isinstance(node[k], dict):
                order.append(node[k])
        i += 1
    dir_off, off = {}, 0
    for node in order:
        dir_off[id(node)] = off
        off += 16 + 8 * len(node)
    dirs_size = off
    name_off, names = {}, bytearray()
    for node in order:
        for k in node:
            if isinstance(k, str) and k not in name_off:
                name_off[k] = dirs_size + len(names)
                enc = k.encode('utf-16-le')
                names += struct.pack('<H', len(k)) + enc
    while len(names) % 4:
        names.append(0)
    leaves = []
    for node in order:
        for k in sorted(node, key=sort_key):
            if not isinstance(node[k], dict):
                leaves.append((id(node), k, node[k]))
    entry_base = dirs_size + len(names)
    data_base = entry_base + 16 * len(leaves)
    data_blob, leaf_off = bytearray(), {}
    for n, (nid, k, (data, cp)) in enumerate(leaves):
        leaf_off[(nid, k)] = entry_base + 16 * n
    entries_blob = bytearray()
    for nid, k, (data, cp) in leaves:
        rva = section_rva + data_base + len(data_blob)
        entries_blob += struct.pack('<IIII', rva, len(data), cp, 0)
        data_blob += data
        while len(data_blob) % 8:
            data_blob.append(0)
    for node in order:
        keys = sorted(node, key=sort_key)
        named = sum(1 for k in keys if isinstance(k, str))
        dirs += struct.pack('<IIHHHH', 0, 0, 4, 0, named, len(keys) - named)
        for k in keys:
            nm = (0x80000000 | name_off[k]) if isinstance(k, str) else k
            if isinstance(node[k], dict):
                target = 0x80000000 | dir_off[id(node[k])]
            else:
                target = leaf_off[(id(node), k)]
            dirs += struct.pack('<II', nm, target)
    return bytes(dirs + names + entries_blob + data_blob)


def ico_resources(ico):
    """.ico file -> (list of RT_ICON images, RT_GROUP_ICON bytes)."""
    _, typ, count = struct.unpack_from('<HHH', ico, 0)
    assert typ == 1, 'not an .ico'
    images, group = [], bytearray(struct.pack('<HHH', 0, 1, count))
    for i in range(count):
        w, h, colors, _, planes, bpp, size, offset = struct.unpack_from('<BBBBHHII', ico, 6 + i * 16)
        images.append(ico[offset:offset + size])
        group += struct.pack('<BBBBHHIH', w, h, colors, 0, planes, bpp, size, i + 1)
    return images, bytes(group)


def version_info(desc, product, version, filename):
    nums = [int(x) for x in (version.split('-')[0].split('.') + ['0'] * 4)[:4]]
    ms, ls = (nums[0] << 16) | nums[1], (nums[2] << 16) | nums[3]

    def block(key, value=b'', children=b'', text=False):
        k = (key + '\0').encode('utf-16-le')
        head_len = 6 + len(k)
        pad1 = (4 - head_len % 4) % 4
        if text:
            vlen = len(value) // 2
        else:
            vlen = len(value)
        body = k + b'\0' * pad1 + value
        pad2 = (4 - (6 + len(body)) % 4) % 4 if children else 0
        total = 6 + len(body) + pad2 + len(children)
        return struct.pack('<HHH', total, vlen, 1 if text else 0) + body + b'\0' * pad2 + children

    def pad4(b):
        return b + b'\0' * ((4 - len(b) % 4) % 4)

    strings = {
        'CompanyName': 'DoveCross', 'FileDescription': desc, 'FileVersion': version,
        'InternalName': filename.rsplit('.', 1)[0], 'LegalCopyright': 'Zuno contributors',
        'OriginalFilename': filename, 'ProductName': product, 'ProductVersion': version,
    }
    table = b''.join(pad4(block(k, (v + '\0').encode('utf-16-le'), text=True)) for k, v in strings.items())
    sfi = block('StringFileInfo', children=block('040904b0', children=table, text=True), text=True)
    var = block('VarFileInfo', children=block('Translation', struct.pack('<HH', 0x0409, 0x04B0)), text=True)
    fixed = struct.pack('<IIIIIIIIIIIII', 0xFEEF04BD, 0x00010000, ms, ls, ms, ls, 0x3F, 0, 0x40004, 1, 0, 0, 0)
    return block('VS_VERSION_INFO', fixed, pad4(sfi) + var)


def main():
    src, dst, ico_path, desc, product, version = sys.argv[1:7]
    filename = dst.replace('\\', '/').rsplit('/', 1)[-1]
    pe = PE(open(src, 'rb').read())
    tree = pe.read_resources()
    images, group = ico_resources(open(ico_path, 'rb').read())
    tree[RT_ICON] = {i + 1: {1033: (img, 0)} for i, img in enumerate(images)}
    tree[RT_GROUP_ICON] = {1: {1033: (group, 0)}}
    tree[RT_VERSION] = {1: {1033: (version_info(desc, product, version, filename), 0)}}
    pe.add_resource_section(tree)
    open(dst, 'wb').write(pe.d)


if __name__ == '__main__':
    main()
