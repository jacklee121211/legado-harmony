cmake_minimum_required(VERSION 3.5.0)
project(ttsdec)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

add_library(ttsdec SHARED tts_decoder.cpp)

target_include_directories(ttsdec PUBLIC ${NATIVERENDER_ROOT_PATH})

target_link_libraries(ttsdec PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_acodec.so)
