cmake_minimum_required(VERSION 3.16)

project(mamba_ssm_reference LANGUAGES C CXX)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(LLAMA_CPP_SSM_DIR "/home/cplcck/llama.cpp-ssm" CACHE PATH "Path to the llama.cpp-ssm checkout")

if(NOT EXISTS "${LLAMA_CPP_SSM_DIR}/ggml/CMakeLists.txt")
    message(FATAL_ERROR "GGML source not found under LLAMA_CPP_SSM_DIR=${LLAMA_CPP_SSM_DIR}")
endif()

set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_CPU ON CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)

add_subdirectory(
    "${LLAMA_CPP_SSM_DIR}/ggml"
    "${CMAKE_BINARY_DIR}/ggml"
    EXCLUDE_FROM_ALL
)

add_executable(ssm_reference
    reference/ssm_reference.cpp
    reference/test_cases.cpp
)
target_compile_features(ssm_reference PRIVATE cxx_std_17)
target_link_libraries(ssm_reference PRIVATE ggml::ggml)
