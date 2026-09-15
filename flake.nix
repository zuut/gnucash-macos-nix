{
  description = "Isolated GnuCash build environment for macOS";

  # Pinned nixpkgs-unstable (2026-09-04) so this env is reproducible and
  # independent of anything else on the machine.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/e5ead30d0824debba629dcf0720abeddee57b7d6";
  # The GnuCash checkout next to this directory; `nix flake update gnucash-src`
  # re-pins it to the current commit.
  inputs.gnucash-src = {
    url = "git+file:../gnucash?ref=stable";
    flake = false;
  };

  outputs = { self, nixpkgs, gnucash-src }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forEach = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        # webkitgtk is flagged broken on darwin in nixpkgs; we build it anyway.
        config.allowBroken = true;
        overlays = [
          (final: prev: {
            # GnuCash (and gtk-osx/jhbuild, which its macOS app is built
            # with) expects a quartz-only GTK: GTK's own default is broadway
            # off, but nixpkgs enables it, making pkg-config report
            # "broadway quartz" so GnuCash's platform detection fails and
            # gtk-mac-integration is skipped. GnuCash upstream declined to
            # support multi-backend GTK (PR #2301), so build GTK their way.
            gtk3 = prev.gtk3.override { broadwaySupport = false; };
          })
        ];
      }));
      # Package overrides shared by the installable gnucash package and the
      # dev shells, so both use the same guile, webkit and Finance::Quote.
      common = pkgs: rec {
        # nixpkgs' webkitgtk pulls in libgbm (mesa/libdrm) unconditionally,
        # which cannot exist on macOS. The rest of the expression still has
        # darwin scaffolding (ENABLE_QUARTZ_TARGET etc.), so drop libgbm and
        # try the build. USE_LIBDRM defaults ON in the GTK port even on
        # darwin, and glib's pkg-config file needs pcre2 in the env.
        # aqbanking/gwenhywfar are marked linux-only in nixpkgs, but build
        # fine on macOS elsewhere (e.g. Homebrew); lift the platform gate.
        gwenhywfar = pkgs.gwenhywfar.overrideAttrs (old: {
          # Its Qt5 dialog plugin fails to link on darwin; GnuCash only needs
          # the gtk3 GUI plugin.
          preConfigure = ''
            configureFlagsArray+=("--with-guis=gtk3")
          '';
          # Plugins contributed by other packages (libchipcard's crypt-token
          # plugins) cannot live in gwenhywfar's own store path. The official
          # macOS app solves this with --enable-local-install, which looks
          # for plugins relative to the executable's prefix; add that lookup
          # alongside the absolute one, so <prefix>/lib/gwenhywfar/plugins
          # of whatever runs gwenhywfar (the gnucash package, later the
          # app bundle) is searched too.
          postPatch = old.postPatch + ''
            sed -i '/GWEN_PathManager_DefinePath(GWEN_PM_LIBNAME, GWEN_PM_PLUGINDIR);/,/^#endif/{/^#endif/a\
    GWEN_PathManager_AddRelPath(GWEN_PM_LIBNAME, GWEN_PM_LIBNAME, GWEN_PM_PLUGINDIR, "lib/gwenhywfar/plugins", GWEN_PathManager_RelModeExe);
            }' src/gwenhywfar.c
            grep -q 'RelModeExe);' src/gwenhywfar.c
          '';
          meta = old.meta // { platforms = old.meta.platforms ++ nixpkgs.lib.platforms.darwin; };
        });
        aqbanking = (pkgs.aqbanking.override { inherit gwenhywfar; }).overrideAttrs (old: {
          meta = old.meta // { platforms = old.meta.platforms ++ nixpkgs.lib.platforms.darwin; };
        });
        # Chip-card (DDV/RDH/ZKA, chipTAN USB) support for HBCI online
        # banking, as the official macOS app ships. Not in nixpkgs. It links
        # macOS's PC/SC framework and installs crypt-token plugins for
        # gwenhywfar (found through the exe-relative lookup above).
        libchipcard = pkgs.stdenv.mkDerivation {
          pname = "libchipcard";
          version = "5.1.6";
          src = pkgs.fetchurl {
            url = "https://www.aquamaniac.de/rdm/attachments/download/382/libchipcard-5.1.6.tar.gz";
            hash = "sha256-bAf1J0F/dWIHT5kBLaTRHrTbr9M/SeZrRCzNbjuM/SA=";
          };
          nativeBuildInputs = with pkgs; [ pkg-config gettext ];
          buildInputs = with pkgs; [ gwenhywfar gnutls libgcrypt libgpg-error zlib ];
          postPatch = ''
            # PC/SC headers live in the SDK, not under /System (same fix as
            # gnucash-on-osx's libchipcard-sdk.patch)
            sed -i 's|/System/Library/Frameworks/PCSC.framework/Headers|${pkgs.apple-sdk.sdkroot}/System/Library/Frameworks/PCSC.framework/Headers|g' configure
            grep -q '${pkgs.apple-sdk.sdkroot}' configure
            # gnucash-on-osx's libchipcard-include.patch
            sed -i 's|^#include <gwenhywfar/args.h>|#include <ctype.h>\n#include <gwenhywfar/args.h>|' src/tools/usbtan-test/main.c
            # C++11 requires whitespace between a string literal and a macro
            sed -i 's|v"k_CHIPCARD_VERSION_STRING")|v" k_CHIPCARD_VERSION_STRING ")|' src/tools/cardcommander/cardcommander.cpp
            grep -q 'v" k_CHIPCARD_VERSION_STRING ")' src/tools/cardcommander/cardcommander.cpp
          '';
          # The plugins default to gwenhywfar's (read-only) plugin dir.
          installFlags = [ "gwenhywfar_plugins=$(out)/lib/gwenhywfar/plugins" ];
          meta.platforms = nixpkgs.lib.platforms.darwin;
        };

        webkitgtk = (pkgs.webkitgtk_4_1.override { libgbm = null; }).overrideAttrs (old: {
          # The webkitgtk release tarball strips the darwin/cf/cocoa platform
          # sources, so a macOS build needs the full git tree instead.
          # (GitHub can't generate archive tarballs for a repo this large, so
          # fetch over git; rev is the webkitgtk-2.52.6 tag.)
          src = pkgs.fetchgit {
            url = "https://github.com/WebKit/WebKit.git";
            rev = "b150840d659b7a77582041fadbf209647c80e690";
            hash = "sha256-7vjTXzPixSLyvKjySlg+vo1pI80YjA869q8ODGop0K4=";
          };
          buildInputs = old.buildInputs ++ [ pkgs.pcre2 pkgs.fontconfig ];
          # TZone malloc is darwin-default but the GTK port's generic classes
          # don't carry TZONE annotations (linux never enables it); disable it
          # so allocator macros behave as on linux.
          # EGL_NO_PLATFORM_SPECIFIC_TYPES: khronos generic native types
          # (void*) instead of Apple's int typedefs — the GTK code expects
          # pointer-shaped EGLNative* types.
          NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -DBUSE_TZONE=0 -DUSE_TZONE_MALLOC=0 -DEGL_NO_PLATFORM_SPECIFIC_TYPES=1";
          # The GTK port's ANGLE build assumes Linux (ANGLE_PLATFORM_LINUX,
          # EGL/dma-buf); swap in a Metal-backend platform file so WebGL
          # builds on darwin the way Apple's own port does.
          postPatch = (old.postPatch or "") + ''
            cp ${./PlatformGTK-darwin.cmake} Source/ThirdParty/ANGLE/PlatformGTK.cmake
            # GLESv2.cmake gates apple sources on is_apple, never set by
            # ANGLE's CMakeLists (only is_mac); set both.
            sed -i -e 's/set(is_mac TRUE)/set(is_mac TRUE)\n    set(is_apple TRUE)/' \
              Source/ThirdParty/ANGLE/CMakeLists.txt
            # EGL_MESA_image_dma_buf_export doesn't exist on macOS/ANGLE;
            # provide failing stubs so the dma-buf render target path links
            # (it is runtime-guarded and falls back to shared memory).
            cat >> Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/AcceleratedSurface.cpp <<'EOF'

            #if defined(__APPLE__)
            extern "C" EGLBoolean eglExportDMABUFImageQueryMESA(EGLDisplay, EGLImageKHR, int*, int*, EGLuint64KHR*) { return EGL_FALSE; }
            extern "C" EGLBoolean eglExportDMABUFImageMESA(EGLDisplay, EGLImageKHR, int*, EGLint*, EGLint*) { return EGL_FALSE; }
            #endif
            EOF
            # bmalloc's darwin-only sources (ProcessCheck.mm) are added by the
            # Mac/JSCOnly ports but not GTK; mirror PlatformJSCOnly.cmake.
            # The GTK port assumes EGL-via-libepoxy (linux). Route EGL through
            # ANGLE instead, exactly as the Mac and Windows ports do
            # (USE_ANGLE_EGL); the cmake branches for it already exist.
            sed -i -e 's/SET_AND_EXPOSE_TO_BUILD(USE_LIBEPOXY TRUE)/SET_AND_EXPOSE_TO_BUILD(USE_LIBEPOXY FALSE)\nset(USE_ANGLE_EGL ON)/' \
              Source/cmake/OptionsGTK.cmake
            # Upstream guard bug: m_compositorTextureID is declared under
            # USE(LIBEPOXY) but used under USE(COORDINATED_GRAPHICS) alone;
            # without libepoxy the texture object id itself is the value.
            sed -i -e 's/CoordinatedPlatformLayerBufferRGB::create(m_compositorTextureID,/CoordinatedPlatformLayerBufferRGB::create(m_compositorTexture,/' \
              Source/WebCore/platform/graphics/texmap/GraphicsContextGLTextureMapperANGLE.cpp
            # WebKitAvailability.h pulls in all of CoreFoundation on __APPLE__,
            # whose MacTypes 'Style' typedef collides with WebCore::Style in
            # unified builds; the include is unused in non-framework builds.
            sed -i -e 's|#include <CoreFoundation/CoreFoundation.h>||' \
              Source/JavaScriptCore/API/WebKitAvailability.h
            # The IPC layer orders its guards OS(DARWIN) before
            # USE(UNIX_DOMAIN_SOCKETS), half-selecting Mach-port IPC that the
            # GTK port never builds. Make the unix-socket path win on darwin.
            find Source/WebKit \( -name "*.h" -o -name "*.cpp" -o -name "*.serialization.in" \) -not -path "*/cocoa/*" -not -path "*/mac/*" -exec sed -i -E \
              -e 's/^#if OS\(DARWIN\)$/#if OS(DARWIN) \&\& !USE(UNIX_DOMAIN_SOCKETS)/' \
              -e 's/^#elif OS\(DARWIN\)$/#elif OS(DARWIN) \&\& !USE(UNIX_DOMAIN_SOCKETS)/' {} +
            find Source/WebCore -name "*.serialization.in" -exec sed -i -E \
              -e 's/^#if OS\(DARWIN\)$/#if OS(DARWIN) \&\& !USE(UNIX_DOMAIN_SOCKETS)/' \
              -e 's/^#elif OS\(DARWIN\)$/#elif OS(DARWIN) \&\& !USE(UNIX_DOMAIN_SOCKETS)/' {} +
            # Case-insensitive APFS: Platform/IPC/glib/ArgumentCodersGlib.h
            # shadows Shared/glib/ArgumentCodersGLib.h. Rename the IPC one.
            sed -i -e 's/ArgumentCodersGlib\.h/ArgumentCodersGlibIPC.h/g' Source/WebKit/Platform/IPC/ArgumentCoders.h
            # macOS defines SOCK_SEQPACKET but doesn't support it for AF_UNIX
            # (socketpair fails -> RELEASE_ASSERT trap at first WebView).
            # ConnectionUnix.cpp already falls back to DGRAM on darwin; do the
            # same at the two glib call sites.
            sed -i -e 's/createPlatformConnection(SOCK_SEQPACKET/createPlatformConnection(SOCK_DGRAM/' \
              Source/WebKit/Platform/IPC/glib/ConnectionGLib.cpp \
              Source/WebKit/UIProcess/Launcher/glib/ProcessLauncherGLib.cpp
            # The renderer transport gate requires linux-only EGL client
            # extensions before enabling even SharedMemory; ANGLE has neither.
            # Neutralize the early return so SHM transport is available.
            sed -i -e 's|if (!GLContext::isExtensionSupported(platformExtensions, "EGL_KHR_platform_gbm")|if (false \&\& !GLContext::isExtensionSupported(platformExtensions, "EGL_KHR_platform_gbm")|' \
              Source/WebKit/UIProcess/gtk/AcceleratedBackingStore.cpp
            # A Default-type EGL display (ANGLE lacks MESA surfaceless) leaves
            # the swap chain Invalid -> no frames ever reach the UI process.
            # Route Default displays to the SharedMemory buffer path.
            sed -i -e '/case PlatformDisplay::Type::Default:/{n;s/^        break;$/        m_type = Type::SharedMemory;\n        break;/;}' \
              Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/AcceleratedSurface.cpp
            # macOS unix datagram sockets default to a 2KB send buffer, but
            # IPC datagrams run up to 4KB: sendmsg fails EMSGSIZE and the
            # message is dropped (hung loads). Enlarge both ends.
            sed -i -e 's|    RELEASE_ASSERT(socketpair(AF_UNIX, socketType, 0, sockets.data()) != -1);|    RELEASE_ASSERT(socketpair(AF_UNIX, socketType, 0, sockets.data()) != -1);\n#if defined(__APPLE__)\n    for (int fd : sockets) {\n        int bufferSize = 262144;\n        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, \&bufferSize, sizeof(bufferSize));\n        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, \&bufferSize, sizeof(bufferSize));\n    }\n#endif|' \
              Source/WebKit/Platform/IPC/unix/IPCUtilitiesUnix.cpp
            # Darwin does not reliably signal G_IO_OUT on AF_UNIX datagram
            # sockets: a WOULD_BLOCK send waits forever on the socket monitor
            # (flaky hung loads). Retry on a short timer instead.
            python3 - <<'PYEOF'
            p = "Source/WebKit/Platform/IPC/glib/ConnectionGLib.cpp"
            lines = open(p).read().split("\n")
            idx = next(i for i, l in enumerate(lines)
                if "G_IO_ERROR_WOULD_BLOCK)) {" in l
                and i + 1 < len(lines) and "m_hasPendingOutputMessage = true;" in lines[i + 1])
            ind = " " * 8
            block = [
                "#if defined(__APPLE__)",
                ind + "m_hasPendingOutputMessage = true;",
                ind + "m_connectionQueue->runLoop().dispatchAfter(WTF::Seconds::fromMilliseconds(2), [this, protectedThis = Ref { *this }, message = WTF::move(outputMessage)]() mutable {",
                ind + "    m_hasPendingOutputMessage = false;",
                ind + "    if (m_isConnected) {",
                ind + "        sendOutputMessage(WTF::move(message));",
                ind + "        sendOutgoingMessages();",
                ind + "    }",
                ind + "});",
                ind + "return false;",
                "#endif",
            ]
            lines[idx + 1:idx + 1] = block
            open(p, "w").write("\n".join(lines))
            print("ConnectionGLib timer-retry patched at line", idx)
            PYEOF
            # DGRAM gives no EOF/hangup, so helper processes never notice the
            # UI process dying; watch for reparenting to launchd instead.
            sed -i \
              -e 's|^#include <stdlib.h>$|#include <stdlib.h>\n#include <thread>\n#include <unistd.h>|' \
              -e 's|^AuxiliaryProcessMainCommon::AuxiliaryProcessMainCommon()$|#if defined(__APPLE__)\n#include <dispatch/dispatch.h>\n#include <objc/message.h>\n#include <objc/runtime.h>\n\nstatic void makeProcessBackgroundOnly(void*)\n{\n    id app = ((id(*)(Class, SEL))objc_msgSend)(objc_getClass("NSApplication"), sel_registerName("sharedApplication"));\n    ((void(*)(id, SEL, long))objc_msgSend)(app, sel_registerName("setActivationPolicy:"), 1);\n}\n\nstatic void startParentDeathWatchdog()\n{\n    std::thread([] {\n        sleep(2);\n        dispatch_async_f(dispatch_get_main_queue(), nullptr, makeProcessBackgroundOnly);\n        while (getppid() != 1)\n            sleep(2);\n        _exit(0);\n    }).detach();\n}\n#endif\n\nAuxiliaryProcessMainCommon::AuxiliaryProcessMainCommon()|' \
              Source/WebKit/Shared/unix/AuxiliaryProcessMain.cpp
            sed -i -e 's|^\(    installBreakpadExceptionHandler();\)$|\1\n#endif\n#if defined(__APPLE__)\n    startParentDeathWatchdog();|' \
              Source/WebKit/Shared/unix/AuxiliaryProcessMain.cpp
            # Hide helper processes from the macOS task switcher (LSUIElement
            # embedded via linker section; they are background processes).
            cat >> Source/WebKit/CMakeLists.txt <<'EOF'

            if (APPLE)
                file(WRITE ''${CMAKE_CURRENT_BINARY_DIR}/BackgroundOnlyInfo.plist "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>LSUIElement</key><true/></dict></plist>\n")
                foreach (_proc WebProcess NetworkProcess)
                    target_link_options(''${_proc} PRIVATE "LINKER:-sectcreate,__TEXT,__info_plist,''${CMAKE_CURRENT_BINARY_DIR}/BackgroundOnlyInfo.plist")
                endforeach ()
            endif ()
            EOF
            # The webkit://gpu diagnostics page guards its EGL include behind
            # USE(LIBEPOXY) but uses EGL unconditionally; our shim serves it.
            sed -i -e 's|#include <epoxy/gl.h>|#include <epoxy/gl.h>\n#include <epoxy/egl.h>|' \
              Source/WebKit/UIProcess/API/glib/WebKitProtocolHandler.cpp
            # Non-epoxy fallback branches include bare GLES2 headers with no
            # EGL declarations; route them through the shim (EGL + GLES3).
            find Source/WebKit -name "*.cpp" -exec sed -i -e 's|#include <GLES2/gl2.h>|#include <epoxy/egl.h>|' {} +
            mv Source/WebKit/Platform/IPC/glib/ArgumentCodersGlib.h Source/WebKit/Platform/IPC/glib/ArgumentCodersGlibIPC.h
            # Two darwin WTF headers are missing from the staged-header list.
            sed -i -e 's|darwin/DispatchOSObject.h|darwin/DispatchOSObject.h\n        darwin/TypeCastsOSObject.h\n        darwin/XPCObjectPtr.h|' \
              Source/WTF/wtf/CMakeLists.txt
            cat > Source/bmalloc/PlatformGTK.cmake <<'EOF'
            if (APPLE)
                list(APPEND bmalloc_SOURCES
                    bmalloc/ProcessCheck.mm
                )

                list(APPEND bmalloc_LIBRARIES
                    "-framework Foundation"
                    objc
                )
            endif ()
            EOF
          '';
          # The GTK port's EGL layer includes <epoxy/egl.h> unconditionally,
          # but darwin's libepoxy has no EGL. Provide a shim that forwards to
          # ANGLE's EGL headers (the implementation we link via USE_ANGLE_EGL).
          preConfigure = (old.preConfigure or "") + ''
            mkdir -p "$NIX_BUILD_TOP/epoxy-shim/epoxy"
            {
              echo "#pragma once"
              echo "#include <EGL/egl.h>"
              echo "#include <EGL/eglext.h>"
              echo "#include <epoxy/gl.h>"
            } > "$NIX_BUILD_TOP/epoxy-shim/epoxy/egl.h"
            {
              echo "#pragma once"
              echo "#include <GLES3/gl3.h>"
              echo "#include <GLES2/gl2ext.h>"
              echo "#ifndef GL_BGRA"
              echo "#define GL_BGRA GL_BGRA_EXT"
              echo "#endif"
              echo "static inline int epoxy_is_desktop_gl(void) { return 0; }"
            } > "$NIX_BUILD_TOP/epoxy-shim/epoxy/gl.h"
            export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -I$NIX_BUILD_TOP/epoxy-shim -I$PWD/Source/ThirdParty/ANGLE/include"
          '';
          # Docs need introspection (disabled); keep the devdoc output valid.
          postInstall = (old.postInstall or "") + ''
            mkdir -p $devdoc/share
          '';
          cmakeFlags = old.cmakeFlags ++ [
            "-DUSE_LIBDRM=OFF"
            # sysprof is a linux profiler; its clock API doesn't compile on darwin
            "-DUSE_SYSPROF_CAPTURE=OFF"
            # Skia's GTK-port integration assumes EGL/libepoxy (linux); the
            # cairo renderer is the portable path the mac GTK stack has
            # always used. WebGL is unaffected (USE_ANGLE tracks ENABLE_WEBGL).
            "-DUSE_SKIA=OFF"
            # GStreamer's GL video path also hard-includes epoxy; video
            # playback still works through non-GL sinks.
            "-DUSE_GSTREAMER_GL=OFF"
            # g-ir-scanner trips over the darwin frankenport's flags; GnuCash
            # uses the C API, not introspection. (Later flag wins over the
            # nixpkgs default of ON.)
            "-DENABLE_INTROSPECTION=OFF"
          ];
        });

        # Loading gnucash's GUI modules (webkit included) into guile blows
        # boehm-gc's default root-set table ("Too many root sets"); raise
        # the compile-time limit.
        boehmgcBig = pkgs.boehmgc.overrideAttrs (old: {
          NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -DMAX_ROOT_SETS=65536 -DLARGE_CONFIG";
        });
        guileBig = pkgs.guile_3_0.override { boehmgc = boehmgcBig; };
        pythonEnv = pkgs.python3.withPackages (p: [ p.pygobject3 ]);
        # WebKit's render processes draw text via fontconfig; give them a
        # real config covering macOS system fonts plus a bundled fallback.
        fontsConf = pkgs.makeFontsConf {
          fontDirectories = [
            "/System/Library/Fonts"
            "/Library/Fonts"
            "${pkgs.dejavu_fonts}/share/fonts"
          ];
        };

        # nixpkgs' librsvg installs its darwin gdk-pixbuf loader referencing
        # @rpath/librsvg-2.2.dylib with no rpath, so gdk-pixbuf cannot dlopen
        # it and no SVG loads at all (GTK's own symbolic icons included). Point
        # it at the absolute store path, re-sign, and regenerate the cache.
        librsvgFixed = pkgs.librsvg.overrideAttrs (old: {
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.darwin.autoSignDarwinBinariesHook ];
          postFixup = (old.postFixup or "") + ''
            loader=$out/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader_svg.dylib
            install_name_tool -id "$loader" \
              -change @rpath/librsvg-2.2.dylib $out/lib/librsvg-2.2.dylib "$loader"
            signDarwinBinariesIn "$(dirname "$loader")"
            cache=$out/${pkgs.gdk-pixbuf.binaryDir}/loaders.cache
            ${pkgs.gdk-pixbuf.dev}/bin/gdk-pixbuf-query-loaders "$loader" > "$cache.svg"
            cat ${nixpkgs.lib.getLib pkgs.gdk-pixbuf}/${pkgs.gdk-pixbuf.binaryDir}/loaders.cache "$cache.svg" > "$cache"
            rm "$cache.svg"
          '';
        });

        # Help documentation. Upstream's derivation only produces the yelp
        # docbook set; on macOS GnuCash opens pre-built HTML instead, and the
        # docs' CMake enables the HTML *install* rules on Apple without adding
        # the html target to `all`. Build it with an offline DocBook toolchain
        # (the setup hooks export XML_CATALOG_FILES for xsltproc).
        gnucashDocs = pkgs.gnucash.passthru.docs.overrideAttrs (old: {
          nativeBuildInputs = old.nativeBuildInputs ++ (with pkgs; [
            libxslt
            docbook-xsl-nons
            docbook_xml_dtd_45
          ]);
          buildFlags = [ "all" "html" ];
        });

        # The installable app: nixpkgs' gnucash derivation (wrapGAppsHook,
        # Finance::Quote and python wrapping) built from the local checkout
        # with the darwin webkit/aqbanking/guile above. desktopToDarwinBundle
        # turns the installed gnucash.desktop + icons into
        # $out/Applications/GnuCash.app, the standard nixpkgs way.
        gnucash = (pkgs.gnucash.override {
          webkitgtk_4_1 = webkitgtk;
          inherit aqbanking gwenhywfar;
          guile = guileBig;
        }).overrideAttrs (old: {
          src = gnucash-src;
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.desktopToDarwinBundle ];
          # Online quotes run on the system perl and whatever Finance::Quote
          # the user keeps current (quote sources change constantly, so any
          # pinned copy goes stale), exactly like the official macOS app.
          # Only perl itself stays, for the build; the perl modules go.
          buildInputs = builtins.filter (p: !(nixpkgs.lib.hasPrefix "perl5." (p.name or ""))) old.buildInputs
            ++ (with pkgs; [
            gettext
            gtk-mac-integration
            librsvgFixed
            fontconfig
            adwaita-icon-theme
            adwaita-icon-theme-legacy
          ]);
          # macOS libc has no gettext; GnuCash finds libintl but never links it
          env = old.env // { NIX_LDFLAGS = "-lintl"; };
          # nixpkgs drops gnc-fq-update (pointless on NixOS); the app bundle
          # relies on the system perl for Finance::Quote, so ship the
          # updater like the official macOS app does.
          patches = builtins.filter (p: !(nixpkgs.lib.hasInfix "disable-gnc-fq-update" (baseNameOf p))) old.patches;
          postPatch = old.postPatch + ''
            # Flake inputs carry no .git, so CMake takes its tarball branch and
            # installs a pre-generated ChangeLog (normally made by `make dist`).
            [ -e ChangeLog ] || printf 'GnuCash built from git commit %s.\nSee the ChangeLog.<year> files and the git history for changes.\n' \
              "${gnucash-src.rev}" > ChangeLog
          '';
          postInstall = (old.postInstall or "") + ''
            # macOS GnuCash opens Help from <prefix>/share/doc/gnucash-docs.
            mkdir -p $out/share/doc
            ln -s ${gnucashDocs}/share/doc/gnucash-docs $out/share/doc/gnucash-docs

            # libchipcard's crypt-token plugins, where gwenhywfar's
            # exe-relative lookup (<prefix>/lib/gwenhywfar/plugins) finds them.
            mkdir -p $out/lib/gwenhywfar/plugins/ct
            ln -s ${libchipcard}/lib/gwenhywfar/plugins/ct/* $out/lib/gwenhywfar/plugins/ct/

            # With MAC_INTEGRATION, etc/gnucash/environment gets entries that
            # assume the self-contained Gnucash.app layout (everything under
            # one prefix) and gnucash *overrides* the environment with them at
            # startup. On Nix those paths don't exist, which breaks pixbuf
            # loaders (no SVG), SQL drivers, OFX DTDs and GTK print backends.
            # The wrapper already provides the correct values; drop the
            # bundle-layout overrides. XDG_CONFIG_HOME is kept so settings
            # live where the official macOS app keeps them.
            sed -i -E '/^(GTK_EXE_PREFIX|GIO_MODULE_DIR|GDK_PIXBUF_MODULE_FILE|FONTCONFIG_PATH|OFX_DTD_PATH|GNC_DBD_DIR|GTK_IM_MODULE_FILE|MARIADB_PLUGIN_DIR)=/d' \
              $out/etc/gnucash/environment
          '';
          # The suite runs from the dev shell; the darwin sandbox lacks a HOME.
          doCheck = false;
          # Guile 3 bytecode (.go) is ELF, and strip empties its
          # .guile.arities.strtab while the arity records still point into
          # it. Compiling anything that calls a GnuCash procedure then dies
          # in bytevector-u8-ref and Guile falls back to interpreting the
          # file. nixpkgs' guile sets dontStrip for the same reason
          # (guile/3.0.nix); strip the native binaries, not the bytecode.
          stripExclude = [ "*.go" ];
          # Same wrapper args as upstream minus its gnucash-docs dependency,
          # whose install step doesn't work on darwin (help docs only).
          preFixup = ''
            gappsWrapperArgs+=(
              --set GNC_DBD_DIR ${pkgs.libdbi-drivers}/lib/dbd
              --set GSETTINGS_SCHEMA_DIR ${pkgs.glib.makeSchemaPath "$out" "gnucash-${old.version}"}
              --set FONTCONFIG_FILE ${fontsConf}
              --set WEBKIT_DISABLE_COMPOSITING_MODE 1
              --prefix XDG_DATA_DIRS : ${pkgs.adwaita-icon-theme-legacy}/share
              --prefix XDG_DATA_DIRS : ${pkgs.shared-mime-info}/share
              # the embedded interpreter's sys.path doesn't include the
              # pygobject env the python plugin imports gi from
              --prefix PYTHONPATH : ${pythonEnv}/${pythonEnv.sitePackages}
            )
          '';
          # nixpkgs' postFixup also wraps finance-quote-wrapper with the nix
          # perl modules' PERL5LIB; redo the wrapping without that. The quote
          # scripts get the system perl here, after stdenv's patchShebangs
          # hook has run (it would otherwise point them back at nix's perl).
          postFixup = ''
            for prog in gnucash gnucash-cli; do
              wrapProgram $out/bin/$prog \
                --prefix PATH : ${pythonEnv}/bin \
                "''${gappsWrapperArgs[@]}"
            done
            chmod +x $out/share/gnucash/python/pycons/*.py
            patchShebangs $out/share/gnucash/python/pycons/*.py
            sed -i '1s|^#!.*perl.*$|#!/usr/bin/perl|' $out/bin/finance-quote-wrapper $out/bin/gnc-fq-update
            head -1 $out/bin/finance-quote-wrapper | grep -q '^#!/usr/bin/perl$'
          '';
        });

        # The redistributable app: the package's runtime closure merged into
        # one prefix inside GnuCash.app, Mach-O load commands rewritten to
        # bundle-relative paths, and GnuCash's own etc/gnucash/environment
        # mechanism pointing every library at the bundle (the same design
        # as the official gtk-mac-bundler build). Users need no Nix.
        gnucashApp = pkgs.runCommand "GnuCash-${gnucash.version}-app" {
          nativeBuildInputs = with pkgs; [
            python3
            darwin.cctools      # otool, install_name_tool
            glib.dev            # glib-compile-schemas, gio-querymodules
            gdk-pixbuf.dev      # gdk-pixbuf-query-loaders
            gtk3 gtk3.dev       # gtk-query-immodules-3.0, gtk-update-icon-cache
            shared-mime-info    # update-mime-database
            darwin.autoSignDarwinBinariesHook
          ];
          # hicolor's index.theme is only found through XDG_DATA_DIRS at
          # runtime, so it is not in gnucash's closure; GTK needs it.
          closure = pkgs.closureInfo { rootPaths = [ gnucash pkgs.hicolor-icon-theme ]; };
        } ''
          python3 ${./bundle-app.py} \
            --gnucash ${gnucash} \
            --closure $closure/store-paths \
            --app $out/Applications/GnuCash.app \
            --version ${gnucash.version} \
            --icns ${gnucash}/Applications/GnuCash.app/Contents/Resources/gnucash-icon.icns
          signDarwinBinariesIn $out/Applications/GnuCash.app
        '';
      };
    in
    {
      packages = forEach (pkgs:
        let c = common pkgs; in {
          inherit (c) webkitgtk aqbanking gwenhywfar libchipcard gnucash;
          gnucash-app = c.gnucashApp;
          default = c.gnucash;
        });

      devShells = forEach (pkgs:
        let
          inherit (common pkgs) guileBig pythonEnv fontsConf librsvgFixed;
          baseDeps = with pkgs; [
            # build tools (perl comes from the system: /usr/bin/perl is on
            # PATH, and online quotes use its Finance::Quote, see gnucash)
            cmake
            ninja
            pkg-config
            gettext
            swig
            # pygobject for the python plugin's gi import
            pythonEnv
            gobject-introspection
            gtest

            # required libraries (see README.dependencies / CMakeLists.txt)
            glib
            gtk3
            guileBig
            boost # built with ICU support in nixpkgs
            icu
            libxml2
            libxslt
            zlib

            # SQL backend
            libdbi
            libdbi-drivers

            # optional but available on darwin
            libofx
            libsecret
            gtk-mac-integration
          ] ++ (with self.packages.${pkgs.system}; [
            # online banking (built with darwin platform-gate lifted)
            gwenhywfar
            aqbanking
          ]) ++ (with pkgs; [
            # pango's pkg-config Requires.private needs this resolvable
            libthai

            # GUI runtime support
            gsettings-desktop-schemas
            adwaita-icon-theme
            # GNOME's retired full-color icons; restores the classic toolbar
            # look instead of Adwaita 50's flat/symbolic style
            adwaita-icon-theme-legacy
            hicolor-icon-theme
          ]);
          mkGnucashShell = extra: pkgs.mkShell {
            packages = baseDeps ++ extra;
            # macOS libc has no gettext; GnuCash's CMake finds libintl but
            # never links it (jhbuild injects -lintl the same way upstream).
            NIX_LDFLAGS = "-L${pkgs.gettext}/lib -lintl";
            shellHook = ''
              # libdbi's SQL drivers live in a separate nix output; point
              # GnuCash at them (mysql/pgsql/sqlite3).
              export GNC_DBD_DIR=${pkgs.libdbi-drivers}/lib/dbd
              # The ANGLE-Metal GL compositor currently produces black frames;
              # the software (cairo) rendering path works fully.
              export WEBKIT_DISABLE_COMPOSITING_MODE=1
              export FONTCONFIG_FILE=${fontsConf}
              export GDK_PIXBUF_MODULE_FILE=${librsvgFixed}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
              export XDG_DATA_DIRS=${pkgs.shared-mime-info}/share:${pkgs.adwaita-icon-theme-legacy}/share:${pkgs.adwaita-icon-theme}/share:${pkgs.hicolor-icon-theme}/share:$XDG_DATA_DIRS
              # GnuCash's embedded python plugin: make pygobject and the
              # gtk typelibs visible to the baked-in interpreter.
              export PYTHONPATH=${pythonEnv}/${pythonEnv.sitePackages}:$PYTHONPATH
              export GI_TYPELIB_PATH=${nixpkgs.lib.makeSearchPath "lib/girepository-1.0" (with pkgs; [ gobject-introspection gtk3 pango gdk-pixbuf at-spi2-core harfbuzz ])}:$GI_TYPELIB_PATH
              export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS
              echo "GnuCash dev shell (nixpkgs-pinned). Source: ../gnucash"
            '';
          };
        in
        {
          # Usable today: builds libgnucash & tests (configure with
          # -DWITH_GNUCASH=OFF until webkit is available).
          default = mkGnucashShell [ ];

          # Full GUI shell; requires the experimental webkitgtk build above.
          gui = mkGnucashShell [ self.packages.${pkgs.system}.webkitgtk ];

          # Validation shell: gnucash deps + webkit's dep closure + the
          # manually-built webkit from ../webkit-work on PKG_CONFIG_PATH.
          gui-manual = pkgs.mkShell {
            inputsFrom = [ (mkGnucashShell [ ]) self.packages.${pkgs.system}.webkitgtk ];
            NIX_LDFLAGS = "-L${pkgs.gettext}/lib -lintl";
            shellHook = ''
              export GNC_DBD_DIR=${pkgs.libdbi-drivers}/lib/dbd
              # The ANGLE-Metal GL compositor currently produces black frames;
              # the software (cairo) rendering path works fully.
              export WEBKIT_DISABLE_COMPOSITING_MODE=1
              export FONTCONFIG_FILE=${fontsConf}
              export GDK_PIXBUF_MODULE_FILE=${librsvgFixed}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
              export XDG_DATA_DIRS=${pkgs.shared-mime-info}/share:${pkgs.adwaita-icon-theme-legacy}/share:${pkgs.adwaita-icon-theme}/share:${pkgs.hicolor-icon-theme}/share:$XDG_DATA_DIRS
              export PKG_CONFIG_PATH=$PWD/webkit-work/out/lib/pkgconfig:$PKG_CONFIG_PATH
            '';
          };

          # Shell carrying webkitgtk's build deps, for iterating on the
          # webkit port in a writable manual build dir (ninja is incremental
          # there; the flake's nix build stays the source of truth).
          webkit = pkgs.mkShell {
            inputsFrom = [ self.packages.${pkgs.system}.webkitgtk ];
          };
        });
    };
}
