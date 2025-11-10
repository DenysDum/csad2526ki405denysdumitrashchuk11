@echo off
REM Step 1: Create build directory if it doesn't exist
if not exist build mkdir build

REM Step 2: Change to build directory
cd build

REM Step 3: Configure the project
cmake ..

REM Step 4: Build the project in Debug configuration
cmake --build . --config Debug

REM Step 5: No need to set executable permission on Windows

REM Step 6: Run tests in Debug config, show output only if tests fail
ctest --output-on-failure -C Debug

REM Return to previous directory
cd ..

Pause