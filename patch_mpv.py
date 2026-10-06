#!/usr/bin/env python3
"""
Patches mpv 0.36.0 source to add SDL2 GPU context (context_sdl.c).
Run from /build after mpv git clone.
"""
import os
import sys
import subprocess

MPV = 'mpv'

# ── 1. Patch video/out/gpu/context.c ─────────────────────────────────────────
ctx_path = os.path.join(MPV, 'video/out/gpu/context.c')
if not os.path.exists(ctx_path):
    sys.exit(f'ERROR: {ctx_path} not found')

src = open(ctx_path).read()
if 'ra_ctx_sdl' in src:
    print(f'[SKIP] {ctx_path} already patched')
else:
    MARKER = 'static const struct ra_ctx_fns *contexts[] = {'
    if MARKER not in src:
        sys.exit(f'ERROR: could not find contexts[] in {ctx_path}')
    src = src.replace(
        MARKER,
        'extern const struct ra_ctx_fns ra_ctx_sdl;\n' + MARKER
    )
    src = src.replace(
        MARKER + '\n',
        MARKER + '\n    &ra_ctx_sdl,\n'
    )
    open(ctx_path, 'w').write(src)
    print(f'[OK] Patched {ctx_path}')

# ── 2. Diagnostics: show meson.build structure ────────────────────────────────
print('=== meson.build files in mpv/ ===')
meson_files = []
for root, dirs, files in os.walk(MPV):
    # Skip hidden dirs and build dirs
    dirs[:] = [d for d in dirs if not d.startswith('.') and d not in ('builddir', 'build', 'subprojects')]
    if 'meson.build' in files:
        fpath = os.path.join(root, 'meson.build')
        meson_files.append(fpath)
        print(' ', fpath)

print(f'Total: {len(meson_files)} meson.build files')

# Show video/out/opengl structure
import glob as globmod
print('=== video/out/opengl/ ===')
ogl_dir = os.path.join(MPV, 'video/out/opengl')
if os.path.isdir(ogl_dir):
    for f in sorted(os.listdir(ogl_dir)):
        print(' ', f)
else:
    print('  (directory not found)')

# ── 3. Find meson.build that compiles opengl context files ────────────────────
# Priority: prefer files we KNOW are compiled (egl_helpers is compiled when have_egl=True,
# which is the case in our build). Avoid context_drm_egl which is inside if have_egl_drm (False).
# By inserting after egl_helpers, we stay in the active if-block.
ACTIVE_MARKERS = [
    'egl_helpers',           # compiled: have_egl=True
    'opengl/common',         # compiled: have_gl=True
    'opengl/ra_gl',          # compiled: have_gl=True
    'opengl/utils',          # compiled: have_gl=True
    'opengl/formats',        # compiled: have_gl=True
]
FALLBACK_MARKERS = [
    'context_android', 'context_drm_egl', 'context_x11', 'context_rpi',
    'context_x11_egl', 'context_vt', 'context_wayland',
]
ALL_MARKERS = ACTIVE_MARKERS + FALLBACK_MARKERS

target_meson = None
for fpath in meson_files:
    content = open(fpath).read()
    if any(m in content for m in ALL_MARKERS):
        print(f'[INFO] Found context markers in {fpath}')
        target_meson = fpath
        break

# ── 4. Fallback strategies if no marker found ─────────────────────────────────
if target_meson is None:
    print('[WARN] No context file markers found in any meson.build')
    print('[WARN] Trying directory-based approach...')

    # Strategy A: if video/out/opengl/meson.build exists, append to it
    ogl_meson = os.path.join(MPV, 'video/out/opengl/meson.build')
    if os.path.exists(ogl_meson):
        target_meson = ogl_meson
        print(f'[INFO] Using {ogl_meson} (exists, no context markers)')
    else:
        # Strategy B: create video/out/opengl/meson.build and add subdir() to parent
        parent_meson = os.path.join(MPV, 'video/out/meson.build')
        if os.path.exists(parent_meson):
            parent_content = open(parent_meson).read()
            if "subdir('opengl')" not in parent_content:
                print(f'[INFO] Adding subdir(opengl) to {parent_meson}')
                with open(parent_meson, 'a') as f:
                    f.write("\nsubdir('opengl')\n")
            # Create the opengl meson.build
            open(ogl_meson, 'w').write("# context_sdl.c added by patch_mpv.py\nsources += files('context_sdl.c')\n")
            print(f'[OK] Created {ogl_meson}')
            sys.exit(0)
        else:
            # Strategy C: add to the root meson.build
            root_meson = os.path.join(MPV, 'meson.build')
            print(f'[WARN] Falling back to root meson.build: {root_meson}')
            print('Root meson.build tail:')
            root_src = open(root_meson).read()
            print(root_src[-2000:])
            # Add at end - this is a last resort
            with open(root_meson, 'a') as f:
                f.write("\n# context_sdl.c added by patch_mpv.py\nsources += files('video/out/opengl/context_sdl.c')\n")
            print(f'[OK] Appended to root meson.build')
            sys.exit(0)

# ── 5. Add context_sdl.c to found meson.build ────────────────────────────────
print(f'[INFO] Patching {target_meson}')
content = open(target_meson).read()

# Print relevant lines for diagnostics
print('--- relevant lines ---')
for line in content.splitlines():
    if any(m in line for m in ALL_MARKERS + ['context_sdl', 'opengl']):
        print(' ', line)
print('---')

if 'context_sdl.c' in content:
    print(f'[SKIP] {target_meson} already has context_sdl.c')
    sys.exit(0)

# Find the best insertion point:
# 1. Prefer last ACTIVE_MARKERS line (inside an if-block that's True for our build)
# 2. Fall back to last of ANY marker (may be in a False block — last resort)
lines = content.splitlines()
last_active_idx = -1
last_any_idx = -1
for i, line in enumerate(lines):
    if any(m in line for m in ACTIVE_MARKERS):
        last_active_idx = i
    if any(m in line for m in ALL_MARKERS):
        last_any_idx = i

last_ctx_idx = last_active_idx if last_active_idx >= 0 else last_any_idx
print(f'[INFO] Active marker line: {last_active_idx}, any marker line: {last_any_idx}, chosen: {last_ctx_idx}')
if last_ctx_idx >= 0:
    print(f'[INFO] Anchor line: {lines[last_ctx_idx].strip()}')

if last_ctx_idx >= 0:
    insert_line = lines[last_ctx_idx]
    indent = len(insert_line) - len(insert_line.lstrip())
    # Determine what path to use based on where the meson.build is
    # If it's in video/out/opengl/, just use 'context_sdl.c'
    # If it's in video/out/, use 'opengl/context_sdl.c'
    # If it's elsewhere, use the full relative path
    meson_dir = os.path.dirname(target_meson)
    ogl_dir_abs = os.path.abspath(os.path.join(MPV, 'video/out/opengl'))
    meson_dir_abs = os.path.abspath(meson_dir)
    if meson_dir_abs == ogl_dir_abs:
        sdl_path = 'context_sdl.c'
    elif ogl_dir_abs.startswith(meson_dir_abs):
        rel = os.path.relpath(ogl_dir_abs, meson_dir_abs)
        sdl_path = os.path.join(rel, 'context_sdl.c')
    else:
        # Compute relative path from meson.build dir to context_sdl.c
        ctx_file = os.path.abspath(os.path.join(MPV, 'video/out/opengl/context_sdl.c'))
        sdl_path = os.path.relpath(ctx_file, meson_dir_abs)

    new_line = ' ' * indent + f"sources += files('{sdl_path}')"
    lines.insert(last_ctx_idx + 1, new_line)
    open(target_meson, 'w').write('\n'.join(lines) + '\n')
    print(f'[OK] Inserted {sdl_path} in {target_meson} after line {last_ctx_idx}')
else:
    # Just append
    with open(target_meson, 'a') as f:
        meson_dir_abs = os.path.abspath(os.path.dirname(target_meson))
        ogl_dir_abs = os.path.abspath(os.path.join(MPV, 'video/out/opengl'))
        if meson_dir_abs == ogl_dir_abs:
            sdl_path = 'context_sdl.c'
        else:
            ctx_file = os.path.abspath(os.path.join(MPV, 'video/out/opengl/context_sdl.c'))
            sdl_path = os.path.relpath(ctx_file, meson_dir_abs)
        f.write(f"\n# context_sdl.c added by patch_mpv.py\nsources += files('{sdl_path}')\n")
    print(f'[OK] Appended context_sdl.c to {target_meson}')

print('Patch complete.')
