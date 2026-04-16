#!/usr/bin/env bash
# SM64 RT64 Path Tracing on Linux — One-Command Installer
#
# Usage: ./install.sh /path/to/baserom.us.z64
#
# Optional env vars:
#   BUILD_DIR=$HOME/build/sm64rt-linux  (where everything goes)
#   SKIP_RENDER96=1                     (skip Render96ex build)
#   SKIP_DEPS=1                         (skip pacman/yay install)

set -euo pipefail

# ─── CONFIG ────────────────────────────────────────────────────────────────────
ROM_PATH="${1:-}"
BUILD_DIR="${BUILD_DIR:-$HOME/build/sm64rt-linux}"
SKIP_RENDER96="${SKIP_RENDER96:-0}"
SKIP_DEPS="${SKIP_DEPS:-0}"

EXPECTED_ROM_SHA1="9bef1128717f958171a4afac3ed78ee2bb4e86ce"
SDL2_VERSION="2.30.10"
DXVK_VERSION="2.7.1"
WINE_PREFIX="$HOME/.wine-sm64rt"

# ─── COLORS ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLU}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GRN}✓${NC} $*"; }
warn() { echo -e "${YLW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }

# ─── PRE-FLIGHT ────────────────────────────────────────────────────────────────
check_rom() {
    if [[ -z "$ROM_PATH" ]]; then
        err "Usage: $0 /path/to/baserom.us.z64"
        echo ""
        echo "You need a legally-dumped US version of Super Mario 64 (N64)."
        echo "Expected SHA-1: $EXPECTED_ROM_SHA1"
        exit 1
    fi
    if [[ ! -f "$ROM_PATH" ]]; then
        err "ROM file not found: $ROM_PATH"; exit 1
    fi
    log "Verifying ROM SHA-1..."
    local actual=$(sha1sum "$ROM_PATH" | cut -d' ' -f1)
    if [[ "$actual" != "$EXPECTED_ROM_SHA1" ]]; then
        err "ROM SHA-1 mismatch."
        err "  Expected: $EXPECTED_ROM_SHA1"
        err "  Got:      $actual"
        err "  You need the US version (Rev 0)."
        exit 1
    fi
    ok "ROM verified ($EXPECTED_ROM_SHA1)"
}

detect_distro() {
    [[ -f /etc/os-release ]] && . /etc/os-release || { err "Cannot detect distro"; exit 1; }
    case " ${ID:-} ${ID_LIKE:-} " in
        *" arch "*|*" cachyos "*|*" manjaro "*|*" endeavouros "*) DISTRO="arch" ;;
        *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*) DISTRO="debian" ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) DISTRO="fedora" ;;
        *" opensuse "*|*" suse "*) DISTRO="suse" ;;
        *) DISTRO="unknown" ;;
    esac
    if [[ "$DISTRO" == "unknown" ]]; then
        err "Unsupported distro: ${ID:-?} (${ID_LIKE:-no ID_LIKE})"
        err "Supported: Arch family, Debian/Ubuntu family, Fedora/RHEL family, openSUSE family"
        exit 1
    fi
    ok "Detected distro: ${PRETTY_NAME:-$ID} ($DISTRO family)"

    if [[ "$DISTRO" == "arch" ]]; then
        if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
            err "AUR helper required. Install yay: sudo pacman -S yay"; exit 1
        fi
        AUR_HELPER=$(command -v yay || command -v paru)
    fi
}

check_gpu() {
    if ! lspci | grep -qiE "vga.*nvidia"; then
        warn "No NVIDIA GPU detected. RTX may not work properly."
    else
        local gpu=$(lspci | grep -iE "vga.*nvidia" | head -1 | sed 's/.*: //')
        ok "GPU: $gpu"
    fi
    if ! vulkaninfo --summary 2>/dev/null | grep -qi "ray_tracing\|RTX"; then
        if vulkaninfo 2>/dev/null | grep -q "VK_KHR_ray_tracing_pipeline"; then
            ok "Vulkan ray tracing extensions available"
        else
            warn "Vulkan ray tracing extensions not detected. Make sure NVIDIA drivers are installed."
        fi
    fi
}

# ─── STEP 1: SYSTEM DEPENDENCIES (multi-distro) ────────────────────────────────
install_deps() {
    [[ "$SKIP_DEPS" == "1" ]] && { warn "Skipping dependency install"; return; }
    log "Installing system dependencies for $DISTRO family (sudo required)..."
    case "$DISTRO" in
        arch)
            sudo pacman -S --needed --noconfirm \
                base-devel git python make curl \
                mingw-w64-gcc mingw-w64-binutils mingw-w64-crt mingw-w64-headers mingw-w64-winpthreads \
                wine winetricks meson ninja glslang p7zip
            "$AUR_HELPER" -S --needed --noconfirm mingw-w64-glew
            ;;
        debian)
            sudo apt-get update
            sudo apt-get install -y \
                build-essential git python3 make curl \
                gcc-mingw-w64 g++-mingw-w64 binutils-mingw-w64 mingw-w64-tools \
                wine winetricks meson ninja-build glslang-tools p7zip-full \
                libglew-dev
            install_glew_mingw_from_source
            ;;
        fedora)
            sudo dnf install -y \
                @development-tools git python3 make curl \
                mingw64-gcc mingw64-gcc-c++ mingw64-binutils mingw64-crt mingw64-headers mingw64-winpthreads \
                mingw64-glew \
                wine winetricks meson ninja-build glslang p7zip
            ;;
        suse)
            sudo zypper install -y -t pattern devel_basis
            sudo zypper install -y \
                git python3 make curl \
                mingw64-cross-gcc-c++ mingw64-cross-binutils mingw64-cross-pkgconf \
                mingw64-glew-devel \
                wine winetricks meson ninja glslang-devel p7zip-full
            ;;
    esac
    ok "Dependencies installed"
}

install_glew_mingw_from_source() {
    if [[ -f /usr/x86_64-w64-mingw32/lib/libglew32.a ]] || [[ -f /usr/local/x86_64-w64-mingw32/lib/libglew32.a ]]; then
        ok "GLEW for MinGW already present"
        return
    fi
    log "Building GLEW for MinGW from source (Debian/Ubuntu lacks the package)..."
    local GLEW_VER="2.2.0"
    cd /tmp
    [[ ! -f "glew-$GLEW_VER.tgz" ]] && curl -sL -o "glew-$GLEW_VER.tgz" \
        "https://github.com/nigels-com/glew/releases/download/glew-$GLEW_VER/glew-$GLEW_VER.tgz"
    [[ ! -d "glew-$GLEW_VER" ]] && tar xzf "glew-$GLEW_VER.tgz"
    cd "glew-$GLEW_VER"
    SYSTEM=linux-mingw64 make -j$(nproc)
    sudo SYSTEM=linux-mingw64 GLEW_DEST=/usr/x86_64-w64-mingw32 make install
    ok "GLEW for MinGW installed to /usr/x86_64-w64-mingw32"
}

# ─── STEP 2: SDL2 MINGW ────────────────────────────────────────────────────────
setup_sdl2() {
    local SDL_DIR="$BUILD_DIR/sdl2-mingw/SDL2-$SDL2_VERSION"
    if [[ -d "$SDL_DIR" ]] && [[ -f "$SDL_DIR/x86_64-w64-mingw32/bin/sdl2-config" ]]; then
        ok "SDL2 MinGW already installed"
        return
    fi
    log "Downloading SDL2 $SDL2_VERSION MinGW devel..."
    mkdir -p "$BUILD_DIR/sdl2-mingw" && cd "$BUILD_DIR/sdl2-mingw"
    curl -sL -o sdl.tar.gz \
        "https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_VERSION/SDL2-devel-$SDL2_VERSION-mingw.tar.gz"
    tar xzf sdl.tar.gz && rm sdl.tar.gz

    log "Patching sdl2-config to use correct paths..."
    local cfg="$SDL_DIR/x86_64-w64-mingw32/bin/sdl2-config"
    sed -i 's|libdir=.*|libdir=${prefix}/lib|' "$cfg"
    sed -i 's|echo -I/tmp/.*include/SDL2.*-Dmain=SDL_main|echo -I${prefix}/include -I${prefix}/include/SDL2 -Dmain=SDL_main|' "$cfg"
    sed -i 's|echo -L/tmp/.*lib  -lmingw32|echo -L${libdir}  -lmingw32|' "$cfg"
    sed -i 's|echo -L/tmp/.*lib \$sdl_static_libs|echo -L${libdir} \$sdl_static_libs|' "$cfg"
    ok "SDL2 MinGW ready at $SDL_DIR"
}

# ─── STEP 3: PATCHED VKD3D-PROTON ──────────────────────────────────────────────
build_vkd3d_proton() {
    local VKD_DIR="$BUILD_DIR/vkd3d-proton"
    local VKD_OUT="$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x64"
    if [[ -f "$VKD_OUT/d3d12.dll" ]] && [[ -f "$VKD_OUT/d3d12core.dll" ]]; then
        ok "Patched vkd3d-proton already built"
        return
    fi
    log "Cloning vkd3d-proton with our DXR fix..."
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    if [[ ! -d "$VKD_DIR" ]]; then
        git clone https://github.com/danielbanariba/vkd3d-proton.git
    fi
    cd "$VKD_DIR"
    git fetch origin
    git checkout fix/dxr-implicit-root-signature
    git submodule update --init --recursive
    log "Building vkd3d-proton (this takes ~5 min)..."
    rm -rf build.64 build.32
    ./package-release.sh master "$BUILD_DIR/vkd3d-output" --no-package
    ok "vkd3d-proton built with DXR fix"
}

# ─── STEP 4: BUILD sm64rt ──────────────────────────────────────────────────────
build_sm64rt() {
    local SRC="$BUILD_DIR/sm64rt"
    if [[ -f "$SRC/build/us_pc/sm64.us.f3dex2e.exe" ]]; then
        ok "sm64rt already built"
        return
    fi
    log "Cloning sm64rt..."
    cd "$BUILD_DIR"
    [[ ! -d "$SRC" ]] && git clone https://github.com/DarioSamo/sm64rt.git
    cp "$ROM_PATH" "$SRC/baserom.us.z64"
    cd "$SRC"

    log "Applying cross-compile fixes..."
    sed -i 's|#include <Windows\.h>|#include <windows.h>|' include/rt64/rt64.h src/pc/gfx/gfx_rt64_context.h
    grep -q '#include <stdio\.h>' src/pc/audio/audio_sdl2.c || \
        sed -i '/#include <SDL2\/SDL\.h>/a #include <stdio.h>' src/pc/audio/audio_sdl2.c
    sed -i 's|-fno-strict-aliasing -fwrapv$|-fno-strict-aliasing -fwrapv -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration|' Makefile

    log "Cross-compiling sm64rt for Windows (this takes ~3 min)..."
    make -j$(nproc) VERSION=us RENDER_API=RT64 EXTERNAL_DATA=1 WINDOWS_BUILD=1 \
        CROSS=x86_64-w64-mingw32- \
        CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ LD=x86_64-w64-mingw32-g++ \
        AS=x86_64-w64-mingw32-as OBJCOPY=x86_64-w64-mingw32-objcopy OBJDUMP=x86_64-w64-mingw32-objdump \
        TARGET_ARCH=i386pe TARGET_BITS=64 NO_BZERO_BCOPY=1 \
        SDLCONFIG="$BUILD_DIR/sdl2-mingw/SDL2-$SDL2_VERSION/x86_64-w64-mingw32/bin/sdl2-config"
    cp "$BUILD_DIR/sdl2-mingw/SDL2-$SDL2_VERSION/x86_64-w64-mingw32/bin/SDL2.dll" build/us_pc/
    ok "sm64rt built: $SRC/build/us_pc/sm64.us.f3dex2e.exe"
}

# ─── STEP 5: BUILD Render96ex RT64 (optional) ──────────────────────────────────
build_render96() {
    [[ "$SKIP_RENDER96" == "1" ]] && { warn "Skipping Render96ex"; return; }
    local SRC="$BUILD_DIR/render96-rt/Render96ex"
    if [[ -f "$SRC/build/us_pc/sm64.us.f3dex2e.exe" ]]; then
        ok "Render96ex RT64 already built"
        return
    fi
    log "Cloning Render96ex RT64 branch..."
    mkdir -p "$BUILD_DIR/render96-rt" && cd "$BUILD_DIR/render96-rt"
    [[ ! -d "Render96ex" ]] && git clone --branch tester_rt64alpha https://github.com/Render96/Render96ex.git
    cp "$ROM_PATH" "$SRC/baserom.us.z64"

    log "Downloading Render96 assets (model pack, HD textures, DynOS)..."
    mkdir -p assets && cd assets
    [[ ! -d "ModelPack" ]] && git clone --depth 1 --branch models_vanilla https://github.com/Render96/ModelPack.git
    [[ ! -d "RENDER96-HD-TEXTURE-PACK" ]] && git clone --depth 1 https://github.com/pokeheadroom/RENDER96-HD-TEXTURE-PACK.git
    [[ ! -f "dynos.7z" ]] && curl -sL -o dynos.7z \
        "https://github.com/Render96/ModelPack/releases/download/3.25/Render96_DynOs_v3.25.7z"

    cd "$SRC"
    cp -rn "$BUILD_DIR/render96-rt/assets/ModelPack/Render96/." actors/

    log "Applying cross-compile fixes..."
    for f in include/rt64/rt64.h src/pc/gfx/gfx_rt64_context.h; do
        sed -i 's|#include <Windows\.h>|#include <windows.h>|' "$f"
    done
    grep -q '#include <stdio\.h>' src/pc/audio/audio_sdl.c || \
        sed -i '/#include <SDL2\/SDL\.h>/a #include <stdio.h>' src/pc/audio/audio_sdl.c
    sed -i 's|-fno-strict-aliasing -fwrapv -fpermissive$|-fno-strict-aliasing -fwrapv -fpermissive -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration|' Makefile

    log "Building native tools..."
    rm -f tools/*.exe
    CC=gcc CXX=g++ make -C tools -j$(nproc) >/dev/null 2>&1 || true

    log "Extracting ROM assets..."
    python3 extract_assets.py us >/dev/null

    log "Cross-compiling Render96ex RT64 (this takes ~10 min)..."
    make -j$(nproc) VERSION=us RENDER_API=RT64 EXTERNAL_DATA=1 TEXTURE_FIX=1 \
        WINDOWS_BUILD=1 NOEXTRACT=1 \
        CROSS=x86_64-w64-mingw32- \
        CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ LD=x86_64-w64-mingw32-g++ \
        AS=x86_64-w64-mingw32-as OBJCOPY=x86_64-w64-mingw32-objcopy OBJDUMP=x86_64-w64-mingw32-objdump \
        TARGET_ARCH=i386pe TARGET_BITS=64 NO_BZERO_BCOPY=1 \
        SDLCONFIG="$BUILD_DIR/sdl2-mingw/SDL2-$SDL2_VERSION/x86_64-w64-mingw32/bin/sdl2-config"

    cp "$BUILD_DIR/sdl2-mingw/SDL2-$SDL2_VERSION/x86_64-w64-mingw32/bin/SDL2.dll" build/us_pc/
    cp -r "$BUILD_DIR/render96-rt/assets/RENDER96-HD-TEXTURE-PACK/gfx" build/us_pc/res/
    7z x -obuild/us_pc/dynos/packs/ "$BUILD_DIR/render96-rt/assets/dynos.7z" -y >/dev/null
    ok "Render96ex RT64 built: $SRC/build/us_pc/sm64.us.f3dex2e.exe"
}

# ─── STEP 6: WINE PREFIX SETUP ─────────────────────────────────────────────────
setup_wine_prefix() {
    local marker="$WINE_PREFIX/.sm64rt-installed"
    if [[ -f "$marker" ]]; then
        ok "Wine prefix already configured"
        # Always update vkd3d-proton DLLs in case patch was rebuilt
        cp "$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x64/d3d12.dll" "$WINE_PREFIX/drive_c/windows/system32/"
        cp "$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x64/d3d12core.dll" "$WINE_PREFIX/drive_c/windows/system32/"
        cp "$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x86/d3d12.dll" "$WINE_PREFIX/drive_c/windows/syswow64/"
        cp "$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x86/d3d12core.dll" "$WINE_PREFIX/drive_c/windows/syswow64/"
        return
    fi

    log "Initializing Wine prefix at $WINE_PREFIX..."
    WINEPREFIX="$WINE_PREFIX" WINEDLLOVERRIDES="mscoree=" wineboot -u 2>&1 | tail -5

    log "Installing patched vkd3d-proton DLLs..."
    cp "$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x64/d3d12.dll" "$WINE_PREFIX/drive_c/windows/system32/"
    cp "$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x64/d3d12core.dll" "$WINE_PREFIX/drive_c/windows/system32/"
    cp "$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x86/d3d12.dll" "$WINE_PREFIX/drive_c/windows/syswow64/"
    cp "$BUILD_DIR/vkd3d-output/vkd3d-proton-master/x86/d3d12core.dll" "$WINE_PREFIX/drive_c/windows/syswow64/"

    log "Downloading and installing DXVK $DXVK_VERSION..."
    mkdir -p "$BUILD_DIR/dxvk-install" && cd "$BUILD_DIR/dxvk-install"
    [[ ! -f "dxvk.tar.gz" ]] && curl -sL -o dxvk.tar.gz \
        "https://github.com/doitsujin/dxvk/releases/download/v$DXVK_VERSION/dxvk-$DXVK_VERSION.tar.gz"
    tar xzf dxvk.tar.gz
    cp "dxvk-$DXVK_VERSION/x64/dxgi.dll" "$WINE_PREFIX/drive_c/windows/system32/"
    cp "dxvk-$DXVK_VERSION/x32/dxgi.dll" "$WINE_PREFIX/drive_c/windows/syswow64/"

    log "Setting DLL overrides..."
    WINEPREFIX="$WINE_PREFIX" wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v dxgi /d native,builtin /f >/dev/null 2>&1

    log "Installing VC++ runtime via winetricks (takes ~2 min)..."
    WINEPREFIX="$WINE_PREFIX" winetricks -q vcrun2019 vcrun2022 d3dcompiler_47 >/dev/null 2>&1 || true

    touch "$marker"
    ok "Wine prefix ready at $WINE_PREFIX"
}

# ─── STEP 7: 8BITDO CONTROLLER DB ──────────────────────────────────────────────
setup_gamepad_db() {
    local DB_DIR="$BUILD_DIR/gamepad"
    local DB_FILE="$DB_DIR/gamecontrollerdb.txt"
    mkdir -p "$DB_DIR"
    if [[ ! -f "$DB_FILE" ]]; then
        log "Downloading SDL community gamepad database..."
        curl -sL -o "$DB_FILE" \
            "https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/master/gamecontrollerdb.txt"
    fi
    if ! grep -q "8BitDo Ultimate Wireless 2.4G" "$DB_FILE"; then
        log "Adding 8BitDo Ultimate Wireless 2.4G mapping..."
        echo "03000000c82d00000931000000000000,8BitDo Ultimate Wireless 2.4G,a:b0,b:b1,back:b10,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b6,leftstick:b13,lefttrigger:a5,leftx:a0,lefty:a1,rightshoulder:b7,rightstick:b14,righttrigger:a4,rightx:a2,righty:a3,start:b11,x:b3,y:b4,platform:Windows," >> "$DB_FILE"
    fi
    # Render96ex needs the DB inside its res/ tree
    if [[ -d "$BUILD_DIR/render96-rt/Render96ex/build/us_pc/res" ]]; then
        mkdir -p "$BUILD_DIR/render96-rt/Render96ex/build/us_pc/res/db"
        cp "$DB_FILE" "$BUILD_DIR/render96-rt/Render96ex/build/us_pc/res/db/gamecontrollerdb.txt"
    fi
    ok "Gamepad DB installed ($(wc -l < "$DB_FILE") mappings)"
}

# ─── STEP 8: LAUNCHERS ─────────────────────────────────────────────────────────
create_launchers() {
    log "Creating launcher scripts..."
    cat > "$BUILD_DIR/run-sm64rt.sh" << EOF
#!/usr/bin/env bash
export WINEPREFIX="$WINE_PREFIX"
export VKD3D_CONFIG=dxr
export WINEDLLOVERRIDES="dxgi=n,b"
export DXVK_HUD=fps
export SDL_GAMECONTROLLERCONFIG_FILE="$BUILD_DIR/gamepad/gamecontrollerdb.txt"
export SDL_JOYSTICK_HIDAPI=1
export SDL_JOYSTICK_HIDAPI_8BITDO=1
export SDL_JOYSTICK_HIDAPI_XBOX=1
export SDL_JOYSTICK_RAWINPUT=0
cd "$BUILD_DIR/sm64rt/build/us_pc"
exec wine sm64.us.f3dex2e.exe "\$@"
EOF
    chmod +x "$BUILD_DIR/run-sm64rt.sh"

    if [[ "$SKIP_RENDER96" != "1" ]]; then
        cat > "$BUILD_DIR/run-render96-rtx.sh" << EOF
#!/usr/bin/env bash
export WINEPREFIX="$WINE_PREFIX"
export VKD3D_CONFIG=dxr
export WINEDLLOVERRIDES="dxgi=n,b"
export DXVK_HUD=fps
export SDL_GAMECONTROLLERCONFIG_FILE="$BUILD_DIR/gamepad/gamecontrollerdb.txt"
export SDL_JOYSTICK_HIDAPI=1
export SDL_JOYSTICK_HIDAPI_8BITDO=1
export SDL_JOYSTICK_HIDAPI_XBOX=1
export SDL_JOYSTICK_RAWINPUT=0
cd "$BUILD_DIR/render96-rt/Render96ex/build/us_pc"
exec wine sm64.us.f3dex2e.exe "\$@"
EOF
        chmod +x "$BUILD_DIR/run-render96-rtx.sh"
    fi
    ok "Launchers created"
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║   SM64 RT64 Path Tracing on Linux — One-Command Installer           ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo ""

    check_rom
    detect_distro
    check_gpu
    install_deps
    setup_sdl2
    build_vkd3d_proton
    build_sm64rt
    build_render96
    setup_wine_prefix
    setup_gamepad_db
    create_launchers

    echo ""
    echo -e "${GRN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GRN}║                       ✓  INSTALLATION COMPLETE                       ║${NC}"
    echo -e "${GRN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Launch sm64rt (vanilla textures + path tracing):"
    echo -e "  ${BLU}$BUILD_DIR/run-sm64rt.sh${NC}"
    echo ""
    if [[ "$SKIP_RENDER96" != "1" ]]; then
        echo "Launch Render96ex RT64 (HD textures + path tracing):"
        echo -e "  ${BLU}$BUILD_DIR/run-render96-rtx.sh${NC}"
        echo ""
    fi
    echo -e "${YLW}Tip:${NC} Unplug/replug your 8BitDo dongle before each launch if controller doesn't respond."
    echo -e "${YLW}Tip:${NC} First launch compiles DXR shaders (~30-60s of black screen). Be patient."
    echo ""
}

main "$@"
