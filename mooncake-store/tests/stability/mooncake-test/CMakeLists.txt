cmake_minimum_required(VERSION 3.16)
project(mooncake_test CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../..")
get_filename_component(REPO_ROOT "${REPO_ROOT}" ABSOLUTE)

if (PROJECT_IS_TOP_LEVEL)
  message(FATAL_ERROR
    "Please build mooncake_test from repository root CMake. "
    "Example: cmake -S . -B build -DWITH_STORE=ON -DWITH_TE=ON -DBUILD_STORE_STABILITY_TESTS=ON")
endif()

if (NOT TARGET mooncake_store)
  message(FATAL_ERROR "mooncake_store target not found. Configure with -DWITH_STORE=ON")
endif()

if (NOT TARGET transfer_engine)
  message(FATAL_ERROR "transfer_engine target not found. Configure with -DWITH_TE=ON")
endif()

# logging
find_package(GLOG REQUIRED)

# Header-only dependencies: use system packages when available, otherwise fetch
# the pinned upstream sources during configuration. This keeps the repository
# free of copied third_party headers.
include(FetchContent)

find_package(CLI11 2.1 QUIET)
if (NOT TARGET CLI11::CLI11)
  FetchContent_Declare(
    CLI11
    GIT_REPOSITORY https://github.com/CLIUtils/CLI11.git
    GIT_TAG v2.6.1
    GIT_SHALLOW TRUE)
  FetchContent_MakeAvailable(CLI11)
endif()

find_package(nlohmann_json 3.10 QUIET)
if (NOT TARGET nlohmann_json::nlohmann_json)
  FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.12.0
    GIT_SHALLOW TRUE)
  FetchContent_MakeAvailable(nlohmann_json)
endif()

# t-digest library for percentile calculations
add_library(tdigest_c src/tdigest-c/tdigest.c)
target_include_directories(tdigest_c PUBLIC "${CMAKE_CURRENT_LIST_DIR}/src/tdigest-c")

# Main executable
add_executable(mooncake_test
    src/main.cpp
    src/kv_store_client.cpp
    src/http_kv_service.cpp
    src/zerocopy_buffer_manager.cpp
)

# Get git author for embedding in binary
execute_process(
    COMMAND git log -1 "--format=%an <%ae>"
    WORKING_DIRECTORY ${REPO_ROOT}
    OUTPUT_VARIABLE MOONCAKE_TEST_AUTHOR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

target_compile_options(mooncake_test PRIVATE -Wall -Wextra -Wno-unused-parameter)

# Define git author macro
target_compile_definitions(mooncake_test PRIVATE MOONCAKE_TEST_AUTHOR="${MOONCAKE_TEST_AUTHOR}")

# mooncake-store headers use global include_directories for cachelib paths,
# which does not apply to this subdirectory; mirror those paths so #include
# "Slab.h" from types.h resolves when compiling mooncake_test sources.
target_include_directories(mooncake_test PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
    "${REPO_ROOT}/mooncake-store/include"
    "${REPO_ROOT}/mooncake-store/include/cachelib_memory_allocator/include"
    "${REPO_ROOT}/mooncake-store/include/cachelib_memory_allocator/fake_include"
    "${REPO_ROOT}/mooncake-store/include/cachelib_memory_allocator"
)

target_link_libraries(mooncake_test PRIVATE
    mooncake_store
    transfer_engine
    asio_shared
    tdigest_c
    glog::glog
    yalantinglibs::yalantinglibs
    CLI11::CLI11
    nlohmann_json::nlohmann_json
)
