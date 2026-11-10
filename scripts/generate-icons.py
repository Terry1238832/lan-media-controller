#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成四端局域网媒体控制器高清应用图标：
- PNG (512x512, 256x256, 128x128, 64x64, 32x32)
- Windows .ico (assets/app.ico)
- macOS .icns (assets/AppIcon.icns)
- Android res/drawable/ic_launcher.png
"""

import os
import math
import struct
import zlib

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS_DIR = os.path.join(BASE_DIR, "assets")
ANDROID_DRAWABLE_DIR = os.path.join(BASE_DIR, "android", "app", "src", "main", "res", "drawable")
os.makedirs(ASSETS_DIR, exist_ok=True)
os.makedirs(ANDROID_DRAWABLE_DIR, exist_ok=True)


def encode_png(width, height, rgba_bytes):
    def make_chunk(chunk_type, data):
        chunk = struct.pack(">I", len(data)) + chunk_type + data
        crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
        return chunk + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    raw_rows = bytearray()
    stride = width * 4
    for y in range(height):
        raw_rows.append(0)  # Filter type 0 (None)
        raw_rows.extend(rgba_bytes[y * stride : (y + 1) * stride])

    idat = zlib.compress(bytes(raw_rows), 9)
    return (
        b"\x89PNG\r\n\x1a\n"
        + make_chunk(b"IHDR", ihdr)
        + make_chunk(b"IDAT", idat)
        + make_chunk(b"IEND", b"")
    )


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def blend(bg, fg, alpha):
    a = clamp(alpha)
    return (
        int(bg[0] * (1.0 - a) + fg[0] * a),
        int(bg[1] * (1.0 - a) + fg[1] * a),
        int(bg[2] * (1.0 - a) + fg[2] * a),
    )


def point_in_triangle_sdf(px, py, ax, ay, bx, by, cx, cy):
    # 计算点到三角形的平滑有符号距离
    def edge_dist(x1, y1, x2, y2):
        dx, dy = x2 - x1, y2 - y1
        l2 = dx * dx + dy * dy
        t = clamp(((px - x1) * dx + (py - y1) * dy) / l2)
        proj_x = x1 + t * dx
        proj_y = y1 + t * dy
        return math.hypot(px - proj_x, py - proj_y)

    d = min(edge_dist(ax, ay, bx, by), edge_dist(bx, by, cx, cy), edge_dist(cx, cy, ax, ay))
    c1 = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    c2 = (cx - bx) * (py - by) - (cy - by) * (px - bx)
    c3 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx)
    inside = (c1 >= 0 and c2 >= 0 and c3 >= 0) or (c1 <= 0 and c2 <= 0 and c3 <= 0)
    return -d if inside else d


def render_icon_rgba(size):
    buf = bytearray(size * size * 4)
    aa = 1.5 / size

    for y in range(size):
        ny = (y + 0.5) / size * 2.0 - 1.0  # -1 .. 1
        for x in range(size):
            nx = (x + 0.5) / size * 2.0 - 1.0  # -1 .. 1

            # 1. 圆角矩形背景 (Squircle SDF)
            rx = max(0.0, abs(nx) - 0.52)
            ry = max(0.0, abs(ny) - 0.52)
            corner_dist = math.hypot(rx, ry) - 0.38
            bg_alpha = clamp(0.5 - corner_dist / (aa * 1.5))

            if bg_alpha <= 0.0:
                continue

            # 渐变深邃蓝紫底色
            t_grad = clamp((nx + ny + 2.0) / 4.0)
            col = blend((15, 23, 42), (30, 58, 138), t_grad)

            # 内部柔和光晕
            r_center = math.hypot(nx, ny - 0.1)
            glow = clamp(1.0 - r_center / 0.85) ** 2
            col = blend(col, (59, 130, 246), glow * 0.35)

            # 2. 顶部局域网 Wi-Fi 信号弧线 (两条发光圆弧)
            wc_x, wc_y = 0.0, -0.10
            wdx, wdy = nx - wc_x, ny - wc_y
            w_rad = math.hypot(wdx, wdy)
            w_ang = math.atan2(wdy, wdx)  # -pi/2 是正上方
            ang_diff = abs(w_ang - (-math.pi / 2.0))

            for arc_r, max_ang in ((0.44, 0.72), (0.60, 0.78)):
                if ang_diff < max_ang:
                    d_arc = abs(w_rad - arc_r) - 0.042
                else:
                    ex = wc_x + arc_r * math.cos(-math.pi / 2.0 + math.copysign(max_ang, w_ang + math.pi / 2.0))
                    ey = wc_y + arc_r * math.sin(-math.pi / 2.0 + math.copysign(max_ang, w_ang + math.pi / 2.0))
                    d_arc = math.hypot(nx - ex, ny - ey) - 0.042
                arc_a = clamp(0.5 - d_arc / aa)
                if arc_a > 0:
                    col = blend(col, (52, 211, 153), arc_a * 0.95)

            # 3. 中心圆形播放按钮底座
            cy_play = 0.14
            d_circle = math.hypot(nx, ny - cy_play) - 0.34
            circle_a = clamp(0.5 - d_circle / aa)
            if circle_a > 0:
                btn_grad = clamp((ny - (cy_play - 0.34)) / 0.68)
                btn_col = blend((59, 130, 246), (37, 99, 235), btn_grad)
                col = blend(col, btn_col, circle_a)

            # 4. 白色圆角播放三角形
            tri_sdf = point_in_triangle_sdf(
                nx, ny,
                -0.10, cy_play - 0.16,
                -0.10, cy_play + 0.16,
                0.18, cy_play
            ) - 0.025
            tri_a = clamp(0.5 - tri_sdf / aa)
            if tri_a > 0:
                col = blend(col, (255, 255, 255), tri_a)

            # 边框高光
            border_a = clamp(1.0 - abs(corner_dist) / (aa * 1.8)) * 0.25
            col = blend(col, (148, 163, 184), border_a)

            idx = (y * size + x) * 4
            buf[idx] = col[0]
            buf[idx + 1] = col[1]
            buf[idx + 2] = col[2]
            buf[idx + 3] = int(bg_alpha * 255)

    return bytes(buf)


def build_ico(png_map, out_ico_path):
    sizes = [16, 32, 48, 256]
    entries = []
    data_blobs = []
    offset = 6 + len(sizes) * 16

    for s in sizes:
        png_data = png_map[s]
        w_byte = 0 if s == 256 else s
        h_byte = 0 if s == 256 else s
        entry = struct.pack("<BBBBHHII", w_byte, h_byte, 0, 0, 1, 32, len(png_data), offset)
        entries.append(entry)
        data_blobs.append(png_data)
        offset += len(png_data)

    with open(out_ico_path, "wb") as f:
        f.write(struct.pack("<HHH", 0, 1, len(sizes)))
        for e in entries:
            f.write(e)
        for b in data_blobs:
            f.write(b)


def build_icns(png_map, out_icns_path):
    # Apple ICNS format with PNG chunks: ic07 (128x128), ic08 (256x256), ic09 (512x512)
    chunks = []
    for ostype, s in ((b"ic07", 128), (b"ic08", 256), (b"ic09", 512)):
        pdata = png_map[s]
        chunks.append(ostype + struct.pack(">I", 8 + len(pdata)) + pdata)

    body = b"".join(chunks)
    with open(out_icns_path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + len(body)) + body)


if __name__ == "__main__":
    png_map = {}
    for sz in (16, 32, 48, 64, 128, 192, 256, 512):
        rgba = render_icon_rgba(sz)
        png_map[sz] = encode_png(sz, sz, rgba)

    with open(os.path.join(ASSETS_DIR, "icon-512.png"), "wb") as f:
        f.write(png_map[512])
    with open(os.path.join(ASSETS_DIR, "icon-192.png"), "wb") as f:
        f.write(png_map[192])
    with open(os.path.join(ASSETS_DIR, "icon-64.png"), "wb") as f:
        f.write(png_map[64])
    with open(os.path.join(ANDROID_DRAWABLE_DIR, "ic_launcher.png"), "wb") as f:
        f.write(png_map[192])

    ico_path = os.path.join(ASSETS_DIR, "app.ico")
    build_ico(png_map, ico_path)

    icns_path = os.path.join(ASSETS_DIR, "AppIcon.icns")
    build_icns(png_map, icns_path)

    print("Generated icons successfully:", ico_path, icns_path)
