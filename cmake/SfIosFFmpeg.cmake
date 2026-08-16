if(NOT IOS)
    message(FATAL_ERROR "SfIosFFmpeg.cmake is iOS-only")
endif()
if(NOT SF_IOS_DEPS_PREFIX)
    message(FATAL_ERROR "SfIosFFmpeg.cmake requires SF_IOS_DEPS_PREFIX")
endif()
if(NOT TARGET Threads::Threads)
    message(FATAL_ERROR "Find Threads before importing the iOS FFmpeg closure")
endif()

find_library(SF_IOS_FFMPEG_COREFOUNDATION CoreFoundation REQUIRED)
find_library(SF_IOS_FFMPEG_COREVIDEO CoreVideo REQUIRED)
find_library(SF_IOS_FFMPEG_COREMEDIA CoreMedia REQUIRED)

function(sf_import_ios_ffmpeg_component component)
    set(archive "${SF_IOS_DEPS_PREFIX}/lib/lib${component}.a")
    if(NOT EXISTS "${archive}")
        message(FATAL_ERROR "Missing iOS FFmpeg archive: ${archive}")
    endif()
    if(NOT TARGET FFmpeg::${component})
        add_library(FFmpeg::${component} STATIC IMPORTED GLOBAL)
        set_target_properties(FFmpeg::${component} PROPERTIES
            IMPORTED_LOCATION "${archive}"
            INTERFACE_INCLUDE_DIRECTORIES "${SF_IOS_DEPS_PREFIX}/include")
    endif()
endfunction()

foreach(component avformat avcodec swresample swscale avutil)
    sf_import_ios_ffmpeg_component(${component})
endforeach()

# Match the installed pkg-config closure. Keeping these relationships on the
# imported archives preserves the proven one-pass static link order.
set_property(TARGET FFmpeg::avutil PROPERTY INTERFACE_LINK_LIBRARIES
    "${SF_IOS_FFMPEG_COREFOUNDATION};${SF_IOS_FFMPEG_COREVIDEO};${SF_IOS_FFMPEG_COREMEDIA};Threads::Threads;m")
set_property(TARGET FFmpeg::avcodec PROPERTY INTERFACE_LINK_LIBRARIES
    "FFmpeg::avutil;Threads::Threads;m")
set_property(TARGET FFmpeg::avformat PROPERTY INTERFACE_LINK_LIBRARIES
    "FFmpeg::avcodec;FFmpeg::avutil;m")
set_property(TARGET FFmpeg::swresample PROPERTY INTERFACE_LINK_LIBRARIES
    "FFmpeg::avutil;m")
set_property(TARGET FFmpeg::swscale PROPERTY INTERFACE_LINK_LIBRARIES
    "FFmpeg::avutil;m")

set(SF_IOS_FFMPEG_LIBRARIES
    FFmpeg::avformat
    FFmpeg::avcodec
    FFmpeg::swresample
    FFmpeg::swscale
    FFmpeg::avutil)
