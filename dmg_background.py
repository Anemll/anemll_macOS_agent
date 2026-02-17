#!/usr/bin/env python3
"""Generate a DMG background image with an arrow pointing from app to Applications."""

import struct
import zlib
import os
import math

WIDTH = 660
HEIGHT = 400

# Icon positions must match create-dmg / package.sh settings
APP_ICON_X = 160
APPS_ICON_X = 500
ICON_Y = 190
ICON_SIZE = 100


def create_png(width, height, pixels):
    """Create a PNG file from raw RGBA pixel data."""
    def chunk(chunk_type, data):
        c = chunk_type + data
        crc = struct.pack('>I', zlib.crc32(c) & 0xffffffff)
        return struct.pack('>I', len(data)) + c + crc

    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))

    raw_data = b''
    for y in range(height):
        raw_data += b'\x00'  # filter byte
        for x in range(width):
            idx = (y * width + x) * 4
            raw_data += bytes(pixels[idx:idx+4])

    idat = chunk(b'IDAT', zlib.compress(raw_data, 9))
    iend = chunk(b'IEND', b'')

    return header + ihdr + idat + iend


def set_pixel(pixels, width, height, x, y, r, g, b, a):
    """Set a pixel with alpha blending."""
    if 0 <= x < width and 0 <= y < height:
        idx = (y * width + x) * 4
        old_a = pixels[idx + 3]
        if old_a == 0:
            pixels[idx] = r
            pixels[idx+1] = g
            pixels[idx+2] = b
            pixels[idx+3] = a
        else:
            fa = a / 255.0
            pixels[idx] = min(255, int(r * fa + pixels[idx] * (1 - fa)))
            pixels[idx+1] = min(255, int(g * fa + pixels[idx+1] * (1 - fa)))
            pixels[idx+2] = min(255, int(b * fa + pixels[idx+2] * (1 - fa)))
            pixels[idx+3] = min(255, old_a + a)


def draw_thick_line(pixels, width, height, x1, y1, x2, y2, thickness, r, g, b, a):
    """Draw a thick anti-aliased line."""
    dx = x2 - x1
    dy = y2 - y1
    length = math.sqrt(dx*dx + dy*dy)
    if length == 0:
        return

    # Normal vector
    nx = -dy / length
    ny = dx / length

    # Bounding box
    half_t = thickness / 2 + 1
    min_x = max(0, int(min(x1, x2) - half_t))
    max_x = min(width - 1, int(max(x1, x2) + half_t))
    min_y = max(0, int(min(y1, y2) - half_t))
    max_y = min(height - 1, int(max(y1, y2) + half_t))

    for py in range(min_y, max_y + 1):
        for px in range(min_x, max_x + 1):
            # Distance from point to line segment
            t = ((px - x1) * dx + (py - y1) * dy) / (length * length)
            t = max(0, min(1, t))
            closest_x = x1 + t * dx
            closest_y = y1 + t * dy
            dist = math.sqrt((px - closest_x)**2 + (py - closest_y)**2)

            if dist < thickness / 2:
                # Anti-alias at edges
                if dist > thickness / 2 - 1:
                    edge_a = int(a * (thickness / 2 - dist))
                else:
                    edge_a = a
                if edge_a > 0:
                    set_pixel(pixels, width, height, px, py, r, g, b, edge_a)


def draw_filled_circle(pixels, width, height, cx, cy, radius, r, g, b, a):
    """Draw a filled circle with anti-aliasing."""
    for py in range(max(0, int(cy - radius - 1)), min(height, int(cy + radius + 2))):
        for px in range(max(0, int(cx - radius - 1)), min(width, int(cx + radius + 2))):
            dist = math.sqrt((px - cx)**2 + (py - cy)**2)
            if dist < radius:
                if dist > radius - 1:
                    edge_a = int(a * (radius - dist))
                else:
                    edge_a = a
                if edge_a > 0:
                    set_pixel(pixels, width, height, px, py, r, g, b, edge_a)


def draw_chevron(pixels, width, height, cx, cy, half_h, thickness, r, g, b, a):
    """Draw a single chevron '>' shape centered at (cx, cy)."""
    # Chevron: two diagonal lines meeting at a point on the right
    # Top-left to center-right, then center-right to bottom-left
    indent = half_h * 0.6  # how far left the top/bottom extend
    top_x = cx - indent
    top_y = cy - half_h
    mid_x = cx + indent
    mid_y = cy
    bot_x = cx - indent
    bot_y = cy + half_h

    draw_thick_line(pixels, width, height,
                    top_x, top_y, mid_x, mid_y,
                    thickness, r, g, b, a)
    draw_thick_line(pixels, width, height,
                    mid_x, mid_y, bot_x, bot_y,
                    thickness, r, g, b, a)


def draw_arrow(pixels, width, height):
    """Draw a compact chevron arrow between app icon and Applications icon."""
    # Center point between the two icons
    cx = (APP_ICON_X + APPS_ICON_X) // 2
    cy = ICON_Y

    # Arrow color: semi-transparent white (like Firefox DMG style)
    ar, ag, ab = 200, 210, 230
    aa = 200

    # Draw two chevrons side by side for ">>" effect
    chevron_half_h = 28
    chevron_thickness = 8
    spacing = 22

    draw_chevron(pixels, width, height,
                 cx - spacing // 2, cy, chevron_half_h, chevron_thickness,
                 ar, ag, ab, aa)
    draw_chevron(pixels, width, height,
                 cx + spacing // 2, cy, chevron_half_h, chevron_thickness,
                 ar, ag, ab, aa)


def main():
    # Create transparent background
    # The DMG window background color is handled by macOS Finder
    # We use a subtle dark background that blends with macOS dark mode
    pixels = bytearray(WIDTH * HEIGHT * 4)

    # Gradient background - subtle dark gray
    for y in range(HEIGHT):
        for x in range(WIDTH):
            idx = (y * WIDTH + x) * 4
            # Subtle vertical gradient
            t = y / HEIGHT
            bg_r = int(42 + t * 6)
            bg_g = int(42 + t * 6)
            bg_b = int(45 + t * 6)
            pixels[idx] = bg_r
            pixels[idx+1] = bg_g
            pixels[idx+2] = bg_b
            pixels[idx+3] = 255

    # Draw arrow
    draw_arrow(pixels, WIDTH, HEIGHT)

    # Write PNG
    png_data = create_png(WIDTH, HEIGHT, pixels)
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dmg_background.png')
    with open(out_path, 'wb') as f:
        f.write(png_data)
    print(f"Created: {out_path} ({WIDTH}x{HEIGHT})")


if __name__ == '__main__':
    main()
