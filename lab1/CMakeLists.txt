cmake_minimum_required(VERSION 3.8)

project(HelloWorld LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(HelloWorld main.cpp)
target_include_directories(HelloWorld PRIVATE ${CMAKE_SOURCE_DIR})

# GoogleTest support
include(FetchContent)
FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/refs/heads/main.zip
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

enable_testing()

add_executable(unit_tests tests/unit_tests.cpp math_operations.cpp)
target_include_directories(unit_tests PRIVATE ${CMAKE_SOURCE_DIR})
target_link_libraries(unit_tests gtest_main)

include(GoogleTest)
gtest_discover_tests(unit_tests)

# Register unit_tests.cpp as a test for ctest
add_test(NAME unit_tests COMMAND unit_tests)

# Instructions for building and running
message(STATUS "To build the main executable, run: cmake --build . --target HelloWorld")
message(STATUS "To build the test executable, run: cmake --build . --target unit_tests")
message(STATUS "To run all tests, execute: ctest --output-on-failure")
