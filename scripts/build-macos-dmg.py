#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构建 macOS .app 应用包并打包为标准 Apple UDIF (.dmg) 磁盘映像
包含完整的 LanMediaController.app (Info.plist + MacOS 可执行启动器 + 后台服务与前端资源)
"""

import os
import struct
import uuid
import zlib
import plistlib
import datetime

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST_DIR = os.path.join(BASE_DIR, "dist")
os.makedirs(DIST_DIR, exist_ok=True)


def build_macos_app_files():
    with open(os.path.join(BASE_DIR, "desktop", "server.js"), "rb") as f:
        server_js = f.read()
    with open(os.path.join(BASE_DIR, "ui", "index.html"), "rb") as f:
        index_html = f.read()

    info_plist = plistlib.dumps({
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleDisplayName": "四端媒体控制器",
        "CFBundleExecutable": "LanMediaController",
        "CFBundleIdentifier": "com.local.lanmediacontroller",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "LanMediaController",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "11.0",
        "NSHighResolutionCapable": True,
        "NSLocalNetworkUsageDescription": "用于在局域网内发现并同步控制四端播放器",
        "NSAppleEventsUsageDescription": "用于控制 macOS 音乐播放器播放、暂停、上下章与进度跳转"
    })

    launcher_sh = ("""#!/bin/bash
DIR="$(cd "$(dirname "$0")/../Resources" && pwd)"
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Stop old instance on port 19889
OLD_PID=$(lsof -ti tcp:19889 2>/dev/null)
if [ -n "$OLD_PID" ]; then
  kill -9 $OLD_PID 2>/dev/null
fi

if command -v node >/dev/null 2>&1; then
  nohup node "$DIR/desktop/server.js" --open >/dev/null 2>&1 &
else
  osascript -e 'display dialog "请先安装 Node.js (https://nodejs.org) 以运行四端局域网媒体控制器后台服务。" buttons {"好"} default button 1 with title "四端媒体控制器"'
fi
""").encode("utf-8")

    readme_txt = (
        "四端局域网媒体控制器 (macOS 版)\n"
        "==============================\n\n"
        "使用方法：\n"
        "1. 将 LanMediaController.app 拖入 Applications (应用程序) 文件夹。\n"
        "2. 双击打开 LanMediaController.app，系统将自动在后台启动局域网控制服务并弹出控制页面。\n"
        "3. 输入设备名，点击「独立开房间」生成 4 位数匹配码，或输入其他设备的 4 位数匹配码加入房间。\n"
    ).encode("utf-8")

    return {
        "LanMediaController.app/Contents/Info.plist": (info_plist, 0o100644),
        "LanMediaController.app/Contents/MacOS/LanMediaController": (launcher_sh, 0o100755),
        "LanMediaController.app/Contents/Resources/desktop/server.js": (server_js, 0o100644),
        "LanMediaController.app/Contents/Resources/ui/index.html": (index_html, 0o100644),
        "README.txt": (readme_txt, 0o100644),
    }


def make_both_endian16(val):
    return struct.pack("<H", val) + struct.pack(">H", val)


def make_both_endian32(val):
    return struct.pack("<I", val) + struct.pack(">I", val)


def pad_sector(data, sector_size=2048):
    rem = len(data) % sector_size
    if rem == 0:
        return data
    return data + b"\x00" * (sector_size - rem)


def make_rockridge_px_nm(name, mode, is_dir):
    # Rock Ridge PX (POSIX file mode) + NM (Alternate Name)
    nlinks = 2 if is_dir else 1
    px = (
        b"PX"
        + struct.pack("BB", 44, 1)
        + make_both_endian32(mode)
        + make_both_endian32(nlinks)
        + make_both_endian32(0)
        + make_both_endian32(0)
        + make_both_endian32(1)
    )
    if name in (".", ".."):
        return px
    name_bytes = name.encode("utf-8")
    nm = b"NM" + struct.pack("BBB", 5 + len(name_bytes), 1, 0) + name_bytes
    return px + nm


def make_dir_record(iso_name_bytes, extent_lba, data_len, is_dir, rr_extra=b""):
    now = datetime.datetime.utcnow()
    date_bytes = struct.pack(
        "BBBBBBb",
        now.year - 1900,
        now.month,
        now.day,
        now.hour,
        now.minute,
        now.second,
        0,
    )
    flags = 0x02 if is_dir else 0x00
    name_len = len(iso_name_bytes)
    pad_len = 1 if (name_len % 2 == 0) else 0
    rec_len = 33 + name_len + pad_len + len(rr_extra)
    if rec_len % 2 == 1:
        rr_extra += b"\x00"
        rec_len += 1

    header = (
        struct.pack("BB", rec_len, 0)
        + make_both_endian32(extent_lba)
        + make_both_endian32(data_len)
        + date_bytes
        + struct.pack("BBB", flags, 0, 0)
        + make_both_endian16(1)
        + struct.pack("B", name_len)
        + iso_name_bytes
        + (b"\x00" * pad_len)
        + rr_extra
    )
    return header


def build_iso_with_rockridge(files_map):
    """
    构建支持 RockRidge (保留大小写文件名与 0755 可执行权限) 的 ISO9660 卷镜像
    """
    dirs = {"": {"subdirs": set(), "files": []}}
    for rel_path, (content, mode) in files_map.items():
        parts = rel_path.split("/")
        cur = ""
        for p in parts[:-1]:
            nxt = f"{cur}/{p}" if cur else p
            dirs[cur]["subdirs"].add(p)
            if nxt not in dirs:
                dirs[nxt] = {"subdirs": set(), "files": []}
            cur = nxt
        dirs[cur]["files"].append((parts[-1], content, mode))

    dir_order = sorted(dirs.keys(), key=lambda x: (x.count("/"), x))
    base_dir_lba = 20
    dir_lbas = {d: base_dir_lba + i for i, d in enumerate(dir_order)}
    next_file_lba = base_dir_lba + len(dir_order)

    file_alloc = {}
    for d in dir_order:
        for fname, content, mode in dirs[d]["files"]:
            sectors = max(1, (len(content) + 2047) // 2048)
            file_alloc[(d, fname)] = (next_file_lba, len(content), content, mode)
            next_file_lba += sectors

    total_iso_blocks = next_file_lba
    dir_sectors = {}

    for d in dir_order:
        my_lba = dir_lbas[d]
        parent_path = "/".join(d.split("/")[:-1]) if "/" in d else ""
        parent_lba = dir_lbas[parent_path]

        sp_entry = b"SP\x07\x01\xbe\xef\x00" if d == "" else b""
        dot_rr = sp_entry + make_rockridge_px_nm(".", 0o040755, True)
        dotdot_rr = make_rockridge_px_nm("..", 0o040755, True)

        records = [
            make_dir_record(b"\x00", my_lba, 2048, True, dot_rr),
            make_dir_record(b"\x01", parent_lba, 2048, True, dotdot_rr),
        ]

        for idx, sub in enumerate(sorted(dirs[d]["subdirs"])):
            sub_path = f"{d}/{sub}" if d else sub
            sub_lba = dir_lbas[sub_path]
            iso_name = f"DIR_{idx:02d}".encode("ascii")
            rr = make_rockridge_px_nm(sub, 0o040755, True)
            records.append(make_dir_record(iso_name, sub_lba, 2048, True, rr))

        for idx, (fname, content, mode) in enumerate(dirs[d]["files"]):
            flba, flen, _, fmode = file_alloc[(d, fname)]
            iso_name = f"FILE_{idx:02d}.DAT;1".encode("ascii")
            rr = make_rockridge_px_nm(fname, fmode, False)
            records.append(make_dir_record(iso_name, flba, flen, False, rr))

        sector_buf = b""
        for rec in records:
            if (len(sector_buf) % 2048) + len(rec) > 2048:
                sector_buf = pad_sector(sector_buf, 2048)
            sector_buf += rec
        dir_sectors[d] = pad_sector(sector_buf, 2048)

    # 构建完整 ISO 镜像
    image = bytearray(total_iso_blocks * 2048)

    # LBA 16: Primary Volume Descriptor
    pvd = bytearray(2048)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[8:40] = b"MACOS                           "
    pvd[40:72] = b"LanMediaController              "
    pvd[80:88] = make_both_endian32(total_iso_blocks)
    pvd[120:124] = make_both_endian16(1)
    pvd[124:128] = make_both_endian16(1)
    pvd[128:132] = make_both_endian16(2048)
    root_rec = make_dir_record(b"\x00", dir_lbas[""], 2048, True)
    pvd[156 : 156 + len(root_rec)] = root_rec
    pvd[881] = 1
    image[16 * 2048 : 17 * 2048] = pvd

    # LBA 17: Volume Descriptor Set Terminator
    vdst = bytearray(2048)
    vdst[0] = 255
    vdst[1:6] = b"CD001"
    vdst[6] = 1
    image[17 * 2048 : 18 * 2048] = vdst

    # 写入目录区
    for d, lba in dir_lbas.items():
        data = dir_sectors[d]
        image[lba * 2048 : lba * 2048 + len(data)] = data

    # 写入文件数据区
    for (d, fname), (flba, flen, content, _) in file_alloc.items():
        padded = pad_sector(content, 2048)
        image[flba * 2048 : flba * 2048 + len(padded)] = padded

    return bytes(image)


def wrap_in_udif_dmg(raw_image_bytes, out_dmg_path):
    """
    将原始扇区镜像封装为标准 Apple UDIF (.dmg, ZLIB 压缩 + blkx Mish 表 + 512 字节 koly 尾部)
    """
    total_sectors = len(raw_image_bytes) // 512
    chunk_sectors = 128  # 64KB per chunk
    chunk_bytes = chunk_sectors * 512

    compressed_chunks = []
    runs = []
    comp_offset = 0

    for sector_idx in range(0, total_sectors, chunk_sectors):
        count = min(chunk_sectors, total_sectors - sector_idx)
        raw_slice = raw_image_bytes[sector_idx * 512 : (sector_idx + count) * 512]
        zdata = zlib.compress(raw_slice, 9)
        compressed_chunks.append(zdata)
        runs.append((0x80000005, 0, sector_idx, count, comp_offset, len(zdata)))
        comp_offset += len(zdata)

    # 结束标记 run
    runs.append((0xFFFFFFFF, 0, total_sectors, 0, comp_offset, 0))

    data_fork = b"".join(compressed_chunks)
    data_crc = zlib.crc32(data_fork) & 0xFFFFFFFF

    # 构造 Mish 块描述头 (204 bytes + N * 40 bytes)
    mish_header = bytearray(204)
    struct.pack_into(">4sIQQQIII", mish_header, 0, b"mish", 1, 0, total_sectors, 0, 128, 0xFFFFFFFF, 0)
    # Checksum struct at offset 64
    struct.pack_into(">III", mish_header, 64, 2, 32, data_crc)
    struct.pack_into(">I", mish_header, 192, len(runs))

    run_bytes = bytearray()
    for rtype, rres, sstart, scount, coff, clen in runs:
        run_bytes += struct.pack(">IIQQQQ", rtype, rres, sstart, scount, coff, clen)

    mish_blob = bytes(mish_header) + bytes(run_bytes)
    master_crc = zlib.crc32(struct.pack(">I", data_crc)) & 0xFFFFFFFF

    plist_dict = {
        "resource-fork": {
            "blkx": [
                {
                    "Attributes": "0x0050",
                    "CFName": "LanMediaController (ISO9660 : 0)",
                    "Data": mish_blob,
                    "ID": "-1",
                    "Name": "LanMediaController (ISO9660 : 0)",
                }
            ]
        }
    }
    xml_bytes = plistlib.dumps(plist_dict, fmt=plistlib.FMT_XML)
    xml_offset = len(data_fork)
    xml_length = len(xml_bytes)

    # 构造 512 字节 koly 尾部
    koly = bytearray(512)
    struct.pack_into(
        ">4sIIIQQQQQII",
        koly,
        0,
        b"koly",
        4,          # version
        512,        # header size
        1,          # flags (flattened read-only)
        0,          # runningDataForkOffset
        0,          # dataForkOffset
        xml_offset, # dataForkLength
        0,          # rsrcForkOffset
        0,          # rsrcForkLength
        1,          # segmentNumber
        1,          # segmentCount
    )
    koly[64:80] = uuid.uuid4().bytes
    # dataForkChecksum at offset 80 (type=2, bit_size=32, crc32)
    struct.pack_into(">III", koly, 80, 2, 32, data_crc)
    # xmlOffset & xmlLength at offset 216
    struct.pack_into(">QQ", koly, 216, xml_offset, xml_length)
    # masterChecksum at offset 352
    struct.pack_into(">III", koly, 352, 2, 32, master_crc)
    # imageVariant & sectorCount at offset 488
    struct.pack_into(">IQ", koly, 488, 1, total_sectors)

    with open(out_dmg_path, "wb") as f:
        f.write(data_fork)
        f.write(xml_bytes)
        f.write(koly)


if __name__ == "__main__":
    app_files = build_macos_app_files()
    iso_bytes = build_iso_with_rockridge(app_files)
    out_path = os.path.join(DIST_DIR, "LanMediaController-macOS.dmg")
    wrap_in_udif_dmg(iso_bytes, out_path)
    print(f"Built macOS DMG: {out_path} ({os.path.getsize(out_path)} bytes)")
