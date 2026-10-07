# Host-side tests for the pure modules (no ESP-IDF needed):
#   cmake -S tests -B build-host && cmake --build build-host && ctest --test-dir build-host --output-on-failure
cmake_minimum_required(VERSION 3.16)
project(spatialcard_host_tests C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra -Werror)

set(MAIN_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../main)

add_library(cjson STATIC vendor/cJSON/cJSON.c)
target_include_directories(cjson PUBLIC vendor/cJSON)

add_library(card_pure STATIC
    ${MAIN_DIR}/link/proto.c
    ${MAIN_DIR}/link/line_buf.c
    ${MAIN_DIR}/store/stats_rules.c
    ${MAIN_DIR}/power/power_policy.c)
target_include_directories(card_pure PUBLIC ${MAIN_DIR})
target_link_libraries(card_pure PUBLIC cjson)

enable_testing()
foreach(t test_proto test_line_buf test_stats_rules test_power_policy)
    add_executable(${t} ${t}.c)
    target_link_libraries(${t} card_pure)
    add_test(NAME ${t} COMMAND ${t})
endforeach()
