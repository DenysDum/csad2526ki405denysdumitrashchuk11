cmake_minimum_required(VERSION 3.8)

project(HelloWorld LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(HelloWorld main.cpp)
