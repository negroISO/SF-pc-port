find_library(SF_UIKIT_FRAMEWORK UIKit REQUIRED)
find_library(SF_UNIFORM_TYPE_IDENTIFIERS_FRAMEWORK UniformTypeIdentifiers REQUIRED)
find_library(SF_GAME_CONTROLLER_FRAMEWORK GameController REQUIRED)

add_executable(sf_ios MACOSX_BUNDLE
    AppDelegate.mm
    SFDiscLibrary.mm
    SFGameControllerBridge.mm
    SFRootViewController.mm
)
target_compile_features(sf_ios PRIVATE cxx_std_20)
target_compile_options(sf_ios PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
)
target_link_libraries(sf_ios PRIVATE
    sf::game
    "${SF_UIKIT_FRAMEWORK}"
    "${SF_UNIFORM_TYPE_IDENTIFIERS_FRAMEWORK}"
    "${SF_GAME_CONTROLLER_FRAMEWORK}"
)

set_target_properties(sf_ios PROPERTIES
    OUTPUT_NAME "SyphonFilter"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS NO
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${SF_IOS_BUNDLE_IDENTIFIER}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
)

if(NOT SF_IOS_CODE_SIGNING)
    set_target_properties(sf_ios PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
    )
endif()

sf_set_project_warnings(sf_ios)
