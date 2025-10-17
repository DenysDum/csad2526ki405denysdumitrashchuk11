#!/bin/bash
set -e

# Step 1: Create build directory if it doesn't exist
mkdir -p build

# Step 2: Change to build directory
cd build

# Step 3: Configure the project
cmake ..

# Step 4: Build the project
cmake --build . --config Debug

# Step 5: Ensure script is executable (applies to itself)
chmod +x ../ci.sh

# Step 6: Run tests in Debug config, show output only if tests fail
ctest --output-on-failure -C Debug
