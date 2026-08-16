if(NOT IOS)
    message(FATAL_ERROR "sf_ios_game requires an iOS toolchain")
endif()

if(NOT TARGET sf::psycross_backend OR NOT TARGET SDL2::SDL2)
    message(FATAL_ERROR "sf_ios_game requires the full PsyCross iOS backend")
endif()

find_library(SF_GAME_FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(SF_GAME_UIKIT_FRAMEWORK UIKit REQUIRED)
find_library(SF_GAME_GAMECONTROLLER_FRAMEWORK GameController REQUIRED)

set(SF_IOS_GAME_EXECUTABLE "SyphonFilterGame")
configure_file(
    Info.plist.in
    "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    @ONLY)

add_executable(sf_ios_game MACOSX_BUNDLE
    main.mm
    uikit_main.c)
target_compile_features(sf_ios_game PRIVATE cxx_std_20)
target_compile_definitions(sf_ios_game PRIVATE
    GLES_SILENCE_DEPRECATION)
target_compile_options(sf_ios_game PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
target_link_libraries(sf_ios_game PRIVATE
    sf::psycross_backend
    SDL2::SDL2
    "${SF_GAME_FOUNDATION_FRAMEWORK}"
    "${SF_GAME_UIKIT_FRAMEWORK}"
    "${SF_GAME_GAMECONTROLLER_FRAMEWORK}")

set_target_properties(sf_ios_game PROPERTIES
    OUTPUT_NAME "${SF_IOS_GAME_EXECUTABLE}"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
        "${SF_IOS_GAME_BUNDLE_IDENTIFIER}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1")

if(NOT SF_IOS_CODE_SIGNING)
    set_target_properties(sf_ios_game PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)
endif()

sf_set_project_warnings(sf_ios_game)
