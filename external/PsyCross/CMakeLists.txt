set(PSYCROSS_SRCS_C
	src/util/timer.c
	src/psx/ABS.C
	src/psx/INLINE_C.C
	src/psx/LIBAPI.C
	src/psx/LIBCD.C
	src/psx/LIBETC.C
	src/psx/LIBGPU.C
	src/psx/LIBGTE.C
	src/psx/LIBMCRD.C
	src/psx/LIBPAD.C
	src/psx/LIBSN.C
	src/psx/LIBSPU.C
)

# iOS exports OpenGL ES directly from the OpenGLES framework.  GLAD remains
# the desktop OpenGL loader, but must not be built into the iOS archive.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
	list(APPEND PSYCROSS_SRCS_C src/render/glad.c)
endif()

set(PSYCROSS_SRCS_CPP
	src/audio/PsyX_SPUAL.cpp
	src/gpu/PsyX_GPU.cpp
	src/gte/half_float.cpp
	src/gte/PsyX_GTE.cpp
	src/pad/PsyX_pad.cpp
	src/render/PsyX_render.cpp
	src/util/crash_handler.cpp
	src/PsyX_main.cpp
)

set_source_files_properties(${PSYCROSS_SRCS_C} PROPERTIES LANGUAGE C)
set_source_files_properties(${PSYCROSS_SRCS_CPP} PROPERTIES LANGUAGE CXX)
#set_source_files_properties( "src/gte/PsyX_GTE.cpp" PROPERTIES LANGUAGE C)

add_library(psycross_static STATIC ${PSYCROSS_SRCS_C} ${PSYCROSS_SRCS_CPP})
set_target_properties(psycross_static PROPERTIES OUTPUT_NAME "psycross")
target_include_directories(psycross_static PUBLIC "include" "include/psx")

if(NOT TARGET SDL2::SDL2 AND NOT TARGET SDL2::SDL2-static)
	find_package(SDL2 REQUIRED)
endif()

if(TARGET SDL2::SDL2)
	target_link_libraries(psycross_static PUBLIC SDL2::SDL2)
elseif(TARGET SDL2::SDL2-static)
	target_link_libraries(psycross_static PUBLIC SDL2::SDL2-static)
elseif(SDL2_LIBRARIES)
	target_link_libraries(psycross_static PUBLIC ${SDL2_LIBRARIES})
	target_include_directories(psycross_static PRIVATE ${SDL2_INCLUDE_DIRS})
else()
	message(FATAL_ERROR "PsyCross requires an SDL2 imported target or legacy SDL2 variables")
endif()

if(NOT TARGET OpenAL::OpenAL AND NOT TARGET OpenAL)
	find_package(OpenAL REQUIRED)
endif()

if(TARGET OpenAL::OpenAL)
	target_link_libraries(psycross_static PUBLIC OpenAL::OpenAL)
elseif(TARGET OpenAL)
	target_link_libraries(psycross_static PUBLIC OpenAL)
elseif(OPENAL_LIBRARY)
	target_link_libraries(psycross_static PUBLIC ${OPENAL_LIBRARY})
	target_include_directories(psycross_static PRIVATE ${OPENAL_INCLUDE_DIR})
else()
	message(FATAL_ERROR "PsyCross requires an OpenAL imported target or legacy OpenAL variables")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
	find_library(PSYCROSS_OPENGLES_FRAMEWORK OpenGLES REQUIRED)
	target_link_libraries(psycross_static PUBLIC ${PSYCROSS_OPENGLES_FRAMEWORK})
	# GLES is the intentional bring-up bridge; a native Metal backend remains the
	# production path, so suppress Apple's per-call deprecation flood here only.
	target_compile_definitions(psycross_static PRIVATE GLES_SILENCE_DEPRECATION)
endif()
