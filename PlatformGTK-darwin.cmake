# Replacement for ANGLE's PlatformGTK.cmake when building the GTK port on
# macOS. Upstream hardcodes ANGLE_PLATFORM_LINUX and the EGL/dma-buf GL
# backend, neither of which exists on darwin. Use the Metal backend instead.
#
# Notes discovered the hard way:
#  - .mm sources are silently ignored unless compiled explicitly; enabling
#    OBJCXX from this subdirectory breaks CMake's generate step, so instead
#    each .mm is marked LANGUAGE CXX with -x objective-c++ (bmalloc's trick).
#  - The MSL translator list is angle_translator_lib_msl_sources (the name
#    referenced by the stale PlatformMac.cmake does not exist).
#  - GLESv2.cmake gates apple sources on is_apple, which ANGLE's
#    CMakeLists.txt never sets (we patch that in the flake's postPatch).
find_library(COREGRAPHICS_LIBRARY CoreGraphics)
find_library(FOUNDATION_LIBRARY Foundation)
find_library(IOKIT_LIBRARY IOKit)
find_library(IOSURFACE_LIBRARY IOSurface)
find_library(METAL_LIBRARY Metal)
find_library(QUARTZ_LIBRARY Quartz)
find_package(ZLIB REQUIRED)

list(APPEND ANGLE_DEFINITIONS EGL_NO_PLATFORM_SPECIFIC_TYPES)

if (USE_OPENGL)
    # Enable GLSL compiler output.
    list(APPEND ANGLE_DEFINITIONS ANGLE_ENABLE_GLSL)
endif ()

if (USE_ANGLE_EGL OR ENABLE_WEBGL)
    list(APPEND ANGLE_SOURCES
        ${metal_backend_sources}

        ${angle_translator_glsl_apple_sources}
        ${angle_translator_lib_msl_sources}

        ${libangle_gpu_info_util_mac_sources}
        ${libangle_gpu_info_util_sources}
        ${libangle_mac_sources}
    )

    list(APPEND ANGLE_DEFINITIONS
        ANGLE_ENABLE_METAL
    )

    list(APPEND ANGLEGLESv2_LIBRARIES
        objc
        ${COREGRAPHICS_LIBRARY}
        ${FOUNDATION_LIBRARY}
        ${IOKIT_LIBRARY}
        ${IOSURFACE_LIBRARY}
        ${METAL_LIBRARY}
        ${QUARTZ_LIBRARY}
    )

    # Compile Objective-C++ sources without enabling OBJCXX (see header note).
    foreach (_angle_src IN LISTS ANGLE_SOURCES)
        if (_angle_src MATCHES "\\.mm$")
            set_source_files_properties(${_angle_src} PROPERTIES
                LANGUAGE CXX
                COMPILE_FLAGS "-x objective-c++"
            )
        endif ()
    endforeach ()
endif ()
