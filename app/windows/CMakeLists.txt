# Project-level configuration.
cmake_minimum_required(VERSION 3.14)

# Select the newest installed Windows SDK that actually contains the UM
# import libraries. Some machines retain a partially installed SDK directory
# which CMake otherwise selects and then fails with missing kernel32.lib.
if(CMAKE_HOST_WIN32)
  file(GLOB _tt_kernel32_libs
    "C:/Program Files (x86)/Windows Kits/10/Lib/*/um/x64/kernel32.lib")
  if(_tt_kernel32_libs)
    list(SORT _tt_kernel32_libs COMPARE NATURAL ORDER DESCENDING)
    list(GET _tt_kernel32_libs 0 _tt_kernel32)
    get_filename_component(_tt_sdk_x64 "${_tt_kernel32}" DIRECTORY)
    get_filename_component(_tt_sdk_um "${_tt_sdk_x64}" DIRECTORY)
    get_filename_component(_tt_sdk_version "${_tt_sdk_um}" DIRECTORY)
    get_filename_component(_tt_sdk_version "${_tt_sdk_version}" NAME)
    set(CMAKE_SYSTEM_VERSION "${_tt_sdk_version}" CACHE STRING
      "Windows SDK selected by available kernel32.lib" FORCE)
    message(STATUS "TimeTrace Windows SDK: ${CMAKE_SYSTEM_VERSION}")
  endif()
endif()

# Avoid a fragile executable link probe on developer machines with endpoint
# protection; the real targets still perform their normal linker checks.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# This machine's cl.exe emits localized /showIncludes output (Chinese locale),
# which corrupts CMake's RC dependency scanning (CMAKE_NINJA_CMCLDEPS_RC).
# Compile the .rc resource directly with rc.exe instead.
set(CMAKE_NINJA_CMCLDEPS_RC 0)

project(timetrace_app LANGUAGES CXX)

# ── Build the Rust bridge (timetrace_bridge.dll) ──
set(TT_RUST_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
if(DEFINED ENV{CARGO_TARGET_DIR} AND NOT "$ENV{CARGO_TARGET_DIR}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{CARGO_TARGET_DIR}" TT_RUST_TARGET_DIR)
else()
  set(TT_RUST_TARGET_DIR "${TT_RUST_ROOT}/target")
endif()
set(TT_BRIDGE_DLL "${TT_RUST_TARGET_DIR}/release/timetrace_bridge.dll")
file(GLOB_RECURSE TT_RUST_BRIDGE_SOURCES CONFIGURE_DEPENDS
  "${TT_RUST_ROOT}/bridge/src/*.rs"
  "${TT_RUST_ROOT}/crates/core/src/*.rs"
)

add_custom_command(
  OUTPUT "${TT_BRIDGE_DLL}"
  COMMAND ${CMAKE_COMMAND} -E env "CARGO_TARGET_DIR=${TT_RUST_TARGET_DIR}"
          cargo build -p timetrace-bridge --release
  WORKING_DIRECTORY "${TT_RUST_ROOT}"
  DEPENDS
    ${TT_RUST_BRIDGE_SOURCES}
    "${TT_RUST_ROOT}/Cargo.toml"
    "${TT_RUST_ROOT}/Cargo.lock"
    "${TT_RUST_ROOT}/bridge/Cargo.toml"
    "${TT_RUST_ROOT}/crates/core/Cargo.toml"
  COMMENT "Building timetrace_bridge.dll (Rust)"
)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "timetrace_app")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  # On MSVC, CMake pre-initializes CMAKE_BUILD_TYPE to "Debug"
  # (Platform/Windows-MSVC.cmake), so the stock Flutter guard
  # "if(NOT CMAKE_BUILD_TYPE ...)" never fires and a plain
  # flutter build windows --release would silently build a Debug runner.
  # Force Release for single-config (Ninja) generators.
  set(CMAKE_BUILD_TYPE "Release" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  # /wd4100 without quotes — Ninja passes flags verbatim
  if(MSVC)
    target_compile_options(${TARGET} PRIVATE /W4 /WX /wd4100 /EHsc)
  else()
    target_compile_options(${TARGET} PRIVATE -Wall -Wextra -Wno-unused-parameter)
  endif()
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Install the Rust bridge DLL next to the executable (built via cargo)
add_custom_target(copy_timetrace_bridge ALL
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${TT_BRIDGE_DLL}" "${BUILD_BUNDLE_DIR}"
  DEPENDS "${TT_BRIDGE_DLL}"
  COMMENT "Copying timetrace_bridge.dll"
)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
