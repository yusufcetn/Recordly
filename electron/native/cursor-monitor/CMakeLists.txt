cmake_minimum_required(VERSION 3.20)
project(cursor-monitor LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(cursor-monitor src/main.cpp)

# Windows 10 1703+ for per-monitor DPI awareness v2 and the DPI conversion APIs.
target_compile_definitions(cursor-monitor PRIVATE
    _WIN32_WINNT=0x0A00
    WINVER=0x0A00
    UNICODE
    _UNICODE
    NOMINMAX
)

target_link_libraries(cursor-monitor PRIVATE user32 ole32 oleaut32 oleacc uuid)
