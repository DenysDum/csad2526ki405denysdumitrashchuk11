1.
Prompt:
@workspace create a "Hello World" program in main.cpp

Answer:
#include <iostream>

int main() {
    std::cout << "Hello World" << std::endl;
    return 0;
}
Explanation:
•	Includes the <iostream> header for output.
•	Defines the main function as the program entry point.
•	Uses std::cout to print "Hello World" followed by a newline.
•	Returns 0 to indicate successful execution.
This code is compatible with C++14 and can be compiled in Visual Studio 2022.

2.
Prompt:
@workspace create a CMakeLists.txt file to build main.cpp

Answer:
cmake_minimum_required(VERSION 3.10)

project(HelloWorld LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(HelloWorld main.cpp)

Explanation:
•	Sets the minimum required CMake version to 3.8 (suitable for C++14 and Visual Studio 2022).
•	Names the project HelloWorld and specifies C++ as the language.
•	Enforces the use of the C++14 standard.
•	Adds an executable target using main.cpp.
This configuration is ready for building your "Hello World" program.
