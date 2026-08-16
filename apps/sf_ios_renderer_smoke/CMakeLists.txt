if(NOT IOS)
    message(FATAL_ERROR "sf_ios_renderer_smoke requires an iOS toolchain")
endif()

if(NOT TARGET psycross_static)
    message(FATAL_ERROR "sf_ios_renderer_smoke requires the PsyCross target")
endif()

if(NOT DEFINED SF_IOS_RENDERER_SMOKE_BUNDLE_IDENTIFIER)
    set(SF_IOS_RENDERER_SMOKE_BUNDLE_IDENTIFIER
        "com.syphonfilter.port.renderer-smoke")
endif()

set(SF_IOS_RENDERER_SMOKE_EXECUTABLE "SFRendererSmoke")
configure_file(
    Info.plist.in
    "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    @ONLY
)

add_executable(sf_ios_renderer_smoke MACOSX_BUNDLE main.mm)
target_compile_features(sf_ios_renderer_smoke PRIVATE cxx_std_17)
target_compile_definitions(sf_ios_renderer_smoke PRIVATE
    GLES_SILENCE_DEPRECATION
)
target_compile_options(sf_ios_renderer_smoke PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
)
target_link_libraries(sf_ios_renderer_smoke PRIVATE psycross_static)

set_target_properties(sf_ios_renderer_smoke PROPERTIES
    OUTPUT_NAME "${SF_IOS_RENDERER_SMOKE_EXECUTABLE}"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
        "${SF_IOS_RENDERER_SMOKE_BUNDLE_IDENTIFIER}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
)

if(NOT SF_IOS_CODE_SIGNING)
    set_target_properties(sf_ios_renderer_smoke PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
    )
endif()

if(COMMAND sf_set_project_warnings)
    sf_set_project_warnings(sf_ios_renderer_smoke)
endif()
