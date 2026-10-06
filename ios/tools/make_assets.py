#!/usr/bin/env python3
"""Génère les images PNG de l'application à partir des formes décrites ici.

    python3 tools/make_assets.py

Pourquoi un script plutôt que des fichiers binaires versionnés : l'icône et le
splash sont dessinés une seule fois, dans du code lisible et modifiable. Le
résultat est déterministe — relancer le script ne change rien.

Deux contraintes techniques, à connaître avant de modifier ce fichier :

  1. L'icône iOS doit être un PNG **plein**, 1024 x 1024, sans canal alpha.
     iOS applique sa propre pastille et masque les coins : arrondir les angles
     ici n'aurait aucun effet, et un fond transparent devient noir.
  2. L'écran de démarrage de Godot n'accepte **que du PNG** (voir
     `main.cpp: setup_boot_logo`). Un SVG y est refusé et remplacé par le logo
     Godot par défaut.

Aucune dépendance : uniquement la bibliothèque standard (zlib, struct).
"""

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# --- Palette, alignee sur core_engine/UITheme.gd ----------------------------
BG_INNER = (0x2A, 0x23, 0x50)
BG_MID = (0x15, 0x0F, 0x2C)
BG_OUTER = (0x07, 0x06, 0x0F)
HALO = (0x7B, 0x6C, 0xF6)
FACET_L_TOP = (0x9C, 0x8D, 0xFF)
FACET_L_BOT = (0x5A, 0x4B, 0xD6)
FACET_R_TOP = (0xFF, 0xD1, 0x66)
FACET_R_BOT = (0xC9, 0x76, 0x2A)
FACET_LL_TOP = (0x6F, 0x60, 0xE6)
FACET_LL_BOT = (0x2E, 0x25, 0x60)
FACET_LR_TOP = (0xB8, 0x81, 0x3A)
FACET_LR_BOT = (0x4A, 0x2F, 0x14)
GOLD = (0xFF, 0xD1, 0x66)
VIOLET = (0x9C, 0x8D, 0xFF)
WHITE = (0xFF, 0xFF, 0xFF)
EDGE = (0x07, 0x06, 0x0F)

SUPERSAMPLE = 2  # 2x2 par pixel : anticontournement correct, rendu en quelques secondes.


class Canvas:
    """Tampon RGB enResolution, avec remplissage de polygones par balayage."""

    def __init__(self, width, height):
        self.w = width
        self.h = height
        self.px = bytearray(width * height * 3)

    def _blend(self, x, y, color, alpha=1.0):
        if alpha <= 0.0 or x < 0 or y < 0 or x >= self.w or y >= self.h:
            return
        i = (y * self.w + x) * 3
        if alpha >= 1.0:
            self.px[i] = color[0]
            self.px[i + 1] = color[1]
            self.px[i + 2] = color[2]
            return
        for k in range(3):
            self.px[i + k] = int(self.px[i + k] * (1.0 - alpha) + color[k] * alpha)

    def background(self, cx, cy, inner_r):
        """Fond en dégradé radial, écrit pixel par pixel."""
        max_d = math.hypot(max(cx, self.w - cx), max(cy, self.h - cy))
        for y in range(self.h):
            base = y * self.w * 3
            for x in range(self.w):
                d = math.hypot(x - cx, y - cy) / max_d
                if d < 0.55:
                    t = d / 0.55
                    c = [int(BG_INNER[k] * (1 - t) + BG_MID[k] * t) for k in range(3)]
                else:
                    t = min(1.0, (d - 0.55) / 0.45)
                    c = [int(BG_MID[k] * (1 - t) + BG_OUTER[k] * t) for k in range(3)]
                i = base + x * 3
                self.px[i] = c[0]
                self.px[i + 1] = c[1]
                self.px[i + 2] = c[2]

    def halo(self, cx, cy, radius, strength=0.55):
        """Lueur diffuse derriere le cristal."""
        r2 = radius * radius
        for y in range(max(0, int(cy - radius)), min(self.h, int(cy + radius) + 1)):
            dy2 = (y - cy) ** 2
            for x in range(max(0, int(cx - radius)), min(self.w, int(cx + radius) + 1)):
                d2 = (x - cx) ** 2 + dy2
                if d2 > r2:
                    continue
                t = d2 / r2
                alpha = strength * (1.0 - t) ** 1.6
                self._blend(x, y, HALO, alpha)

    def polygon(self, points, color_at):
        """Remplit un polygone convexe. color_at(u, v) -> (r, g, b)."""
        ys = [p[1] for p in points]
        y0 = max(0, int(math.floor(min(ys))))
        y1 = min(self.h - 1, int(math.ceil(max(ys))))
        n = len(points)
        for y in range(y0, y1 + 1):
            sy = y + 0.5
            xs = []
            for i in range(n):
                ax, ay = points[i]
                bx, by = points[(i + 1) % n]
                if (ay <= sy < by) or (by <= sy < ay):
                    t = (sy - ay) / (by - ay)
                    xs.append(ax + (bx - ax) * t)
            if len(xs) < 2:
                continue
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                xa, xb = xs[k], xs[k + 1]
                x0 = max(0, int(math.floor(xa)))
                x1 = min(self.w - 1, int(math.ceil(xb)))
                for x in range(x0, x1 + 1):
                    if xa - 0.5 <= x + 0.5 <= xb + 0.5:
                        self._blend(x, y, color_at(x + 0.5, sy))

    def polyline(self, points, color, width, alpha=1.0):
        """Trace un segment epais (distance a la droite)."""
        half = width / 2.0
        for i in range(len(points) - 1):
            ax, ay = points[i]
            bx, by = points[i + 1]
            x0 = max(0, int(min(ax, bx) - half - 1))
            x1 = min(self.w - 1, int(max(ax, bx) + half + 1))
            y0 = max(0, int(min(ay, by) - half - 1))
            y1 = min(self.h - 1, int(max(ay, by) + half + 1))
            dx, dy = bx - ax, by - ay
            length2 = dx * dx + dy * dy
            for y in range(y0, y1 + 1):
                for x in range(x0, x1 + 1):
                    px_, py_ = x + 0.5, y + 0.5
                    t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((px_ - ax) * dx + (py_ - ay) * dy) / length2))
                    d = math.hypot(px_ - (ax + dx * t), py_ - (ay + dy * t))
                    if d <= half:
                        self._blend(x, y, color, alpha * min(1.0, half + 0.5 - d))
                    elif d <= half + 1.0:
                        self._blend(x, y, color, alpha * (half + 1.0 - d))

    def disc(self, cx, cy, radius, color, alpha=1.0):
        r2 = radius * radius
        for y in range(max(0, int(cy - radius - 1)), min(self.h, int(cy + radius) + 2)):
            for x in range(max(0, int(cx - radius - 1)), min(self.w, int(cx + radius + 2))):
                d2 = (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2
                if d2 <= r2:
                    self._blend(x, y, color, alpha)
                elif d2 <= (radius + 1.0) ** 2:
                    self._blend(x, y, color, alpha * (radius + 1.0 - math.sqrt(d2)))

    def star4(self, cx, cy, arm, waist, color, alpha=1.0):
        """Eclat a quatre branches (utilise pour les etincelles)."""
        self.polygon(
            [(cx, cy - arm), (cx + waist, cy - waist), (cx + arm, cy),
             (cx + waist, cy + waist), (cx, cy + arm), (cx - waist, cy + waist),
             (cx - arm, cy), (cx - waist, cy - waist)],
            lambda u, v: color,
        )
        if alpha < 1.0:
            pass  # etincelles pleines : l'alpha n'est pas necessaire ici

    def to_png(self, path):
        """Ecrit un PNG RGB (canal alpha absent) — format exige par iOS."""
        raw = bytearray()
        stride = self.w * 3
        for y in range(self.h):
            raw.append(0)  # filtre "None" : aucun gain de compression, code lisible
            raw += self.px[y * stride:(y + 1) * stride]

        def chunk(tag, data):
            body = tag + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

        png = b"\x89PNG\r\n\x1a\n"
        png += chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        png += chunk(b"IEND", b"")
        path.write_bytes(png)
        return len(png)


def _mix(c0, c1, t):
    t = max(0.0, min(1.0, t))
    return (int(c0[0] * (1 - t) + c1[0] * t),
            int(c0[1] * (1 - t) + c1[1] * t),
            int(c0[2] * (1 - t) + c1[2] * t))


def draw_crystal(cv, cx, cy, s, edges=True):
    """Cristal facetté, centre sur (cx, cy), hauteur de reference 2*s.

    Geometrie identique a icon.svg : hexagone etire, ceinture a y = cy.
    """
    def P(x, y):
        return (cx + x * s, cy + y * s)

    apex, waist = P(0, -1.60), P(0, 0)
    ul, ur = P(-1.10, -0.70), P(1.10, -0.70)
    ll, lr = P(-1.10, 0.48), P(1.10, 0.48)
    culet = P(0, 2.10)

    # Facette haute gauche : violet, du plus clair (haut) au plus fonce.
    cv.polygon([apex, ul, ll, waist],
               lambda u, v, t0=-1.60, t1=0.48: _mix(FACET_L_TOP, FACET_L_BOT,
                                                    (v - t0 * s) / ((t1 - t0) * s)))
    # Facette haute droite : or.
    cv.polygon([apex, ur, lr, waist],
               lambda u, v, t0=-1.60, t1=0.48: _mix(FACET_R_TOP, FACET_R_BOT,
                                                    (v - t0 * s) / ((t1 - t0) * s)))
    # Facettes basses.
    cv.polygon([ll, waist, culet],
               lambda u, v, t0=0.0, t1=1.0: _mix(FACET_LL_TOP, FACET_LL_BOT,
                                                    (v - cy) / (2.10 * s)))
    cv.polygon([lr, waist, culet],
               lambda u, v, t0=0.0, t1=1.0: _mix(FACET_LR_TOP, FACET_LR_BOT,
                                                    (v - cy) / (2.10 * s)))

    # Reflet speculaire sur la face haute gauche.
    cv.polygon([P(0, -1.48), P(-0.97, -0.66), P(-0.91, -0.39), P(0, -1.00)],
               lambda u, v: WHITE)

    if edges:
        w = max(1.0, 0.035 * s)
        cv.polyline([apex, waist], EDGE, w, 0.55)
        cv.polyline([ul, waist, ur], EDGE, w, 0.55)
        cv.polyline([ll, waist, lr], EDGE, w, 0.55)
        cv.polyline([apex, ul, ll, culet, lr, ur], EDGE, w * 1.3, 0.75)

    cv.disc(cx, cy - 1.62 * s, max(1.0, 0.075 * s), (0xFF, 0xF6, 0xDD), 0.9)


def build_icon():
    n = 1024 * SUPERSAMPLE
    cv = Canvas(n, n)
    cv.background(n / 2, n * 0.38, n * 0.78)
    cv.halo(n / 2, n / 2, n * 0.42, 0.55)
    draw_crystal(cv, n / 2, n / 2 - n * 0.02, n * 0.245)

    s = n * 0.245
    cv.star4(n * 0.23, n * 0.23, 0.055 * n, 0.017 * n, GOLD)
    cv.star4(n * 0.795, n * 0.60, 0.042 * n, 0.013 * n, GOLD)
    cv.star4(n * 0.725, n * 0.175, 0.036 * n, 0.011 * n, VIOLET, 0.9)
    cv.disc(n * 0.26, n * 0.655, 0.013 * n, VIOLET, 0.9)
    for fx, fy, fr in ((0.382, 0.147, 0.007), (0.633, 0.143, 0.005), (0.816, 0.435, 0.006)):
        cv.disc(n * fx, n * fy, max(1.0, fr * n), WHITE, 0.5)
    return cv


def build_splash():
    n = 1280 * SUPERSAMPLE
    cv = Canvas(n, int(n * 720 / 1280))
    h = cv.h
    cv.background(n / 2, h * 0.44, h * 0.95)
    cv.halo(n / 2, h * 0.46, h * 0.46, 0.5)
    draw_crystal(cv, n / 2, h * 0.46, h * 0.30)
    return cv


def downsample(cv, factor):
    """Reduit d'un facteur entier en moyennant les blocs (anticontournement)."""
    w, h = cv.w // factor, cv.h // factor
    out = Canvas(w, h)
    area = factor * factor
    for y in range(h):
        for x in range(w):
            acc = [0, 0, 0]
            for dy in range(factor):
                base = ((y * factor + dy) * cv.w + x * factor) * 3
                for dx in range(factor):
                    i = base + dx * 3
                    acc[0] += cv.px[i]
                    acc[1] += cv.px[i + 1]
                    acc[2] += cv.px[i + 2]
            o = (y * w + x) * 3
            out.px[o] = acc[0] // area
            out.px[o + 1] = acc[1] // area
            out.px[o + 2] = acc[2] // area
    return out


def main():
    icon = downsample(build_icon(), SUPERSAMPLE)
    size = icon.to_png(ROOT / "icon.png")
    print("icon.png        %dx%d  %6.1f Ko" % (icon.w, icon.h, size / 1024))

    splash = downsample(build_splash(), SUPERSAMPLE)
    size = splash.to_png(ROOT / "assets" / "splash.png")
    print("splash.png      %dx%d  %6.1f Ko" % (splash.w, splash.h, size / 1024))


if __name__ == "__main__":
    main()
