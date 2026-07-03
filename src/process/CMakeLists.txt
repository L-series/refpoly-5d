cmake_minimum_required(VERSION 3.20)
project(refpoly5d_process CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Standalone parquet post-processing tools (no PALP dependency):
#   concat_parquet  — concatenate a part-*.parquet dataset into one file
#                     (schema-agnostic: works for reflexive and non-reflexive)
#   merge_computed  — join unique_polytopes.parquet with separately-computed
#                     Hodge shards, replacing the corrupt int16 h11/h12/h13 with
#                     clean int32 columns (reflexive workflow only)
find_package(Arrow   REQUIRED)
find_package(Parquet REQUIRED)

foreach(tool concat_parquet merge_computed)
  add_executable(${tool} ${tool}.cpp)
  target_compile_options(${tool} PRIVATE -O2)
  target_link_libraries(${tool} PRIVATE Arrow::arrow_shared Parquet::parquet_shared)
endforeach()

install(TARGETS concat_parquet merge_computed RUNTIME DESTINATION bin)
