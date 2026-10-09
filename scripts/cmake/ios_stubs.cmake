# Included after every project() call via CMAKE_PROJECT_INCLUDE when cross-compiling audio.cpp for iOS.
# audio.cpp's vendored sentencepiece calls ios-cmake's set_xcode_property() for CMAKE_SYSTEM_NAME=iOS,
# which only exists in that toolchain file. We build with Ninja/Makefiles (no Xcode generator), so a no-op is correct.
if(NOT COMMAND set_xcode_property)
  function(set_xcode_property)
  endfunction()
endif()
