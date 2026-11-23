#!/usr/bin/env python3
"""Generate project Android WebView dari template. Input via env: APP_NAME, WEB_URL, JOB_ID."""
import os, re, shutil, struct, subprocess, zlib

name = re.sub(r"[\x00-\x1f]", "", os.environ.get("APP_NAME", "App")).strip()[:30] or "App"
url = os.environ["WEB_URL"].strip()
job = re.sub(r"[^a-z0-9]", "", os.environ.get("JOB_ID", "x").lower()) or "x"
slug = re.sub(r"[^a-z0-9]", "", name.lower())[:20] or "app"
pkg = f"com.webapk.a{slug}{job}"

def android_str(s):
    s = s.replace("\\", "\\\\")
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    s = s.replace("'", "\\'").replace('"', '\\"')
    if s[:1] in ("@", "?"):
        s = "\\" + s
    return s

if os.path.exists("webproj"):
    shutil.rmtree("webproj")
shutil.copytree("webapp-template", "webproj")

p = "webproj/app/build.gradle"
t = open(p).read().replace("__PACKAGE__", pkg)
open(p, "w").write(t)

open("webproj/app/src/main/res/values/strings.xml", "w", encoding="utf-8").write(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
    f'    <string name="app_name">{android_str(name)}</string>\n'
    f'    <string name="web_url" formatted="false">{android_str(url)}</string>\n'
    "</resources>\n"
)

def solid_png(path, size, rgb=(79, 70, 229)):
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(tp, d):
        return struct.pack(">I", len(d)) + tp + d + struct.pack(">I", zlib.crc32(tp + d) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    open(path, "wb").write(png)

sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
tool = shutil.which("magick") or shutil.which("convert")
have_icon = os.path.exists("icon.bin") and tool
for d, s in sizes.items():
    out_dir = f"webproj/app/src/main/res/mipmap-{d}"
    os.makedirs(out_dir, exist_ok=True)
    out = f"{out_dir}/ic_launcher.png"
    ok = False
    if have_icon:
        cmd = [tool, "icon.bin[0]", "-background", "none", "-resize", f"{s}x{s}^", "-gravity", "center",
               "-extent", f"{s}x{s}", f"PNG32:{out}"]
        ok = subprocess.run(cmd, capture_output=True).returncode == 0 and os.path.exists(out)
    if not ok:
        solid_png(out, s)
print("package:", pkg, "| icon:", "custom" if have_icon else "default")
