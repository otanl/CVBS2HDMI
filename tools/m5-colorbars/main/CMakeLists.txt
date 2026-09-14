idf_component_register(SRCS "main.cpp"
                       INCLUDE_DIRS ".")

# Let the composite output level be set from the command line, so it can be
# swept against a measurement instead of guessed:
#   idf.py build -DM5_OUTPUT_LEVEL=192
if(DEFINED M5_OUTPUT_LEVEL)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE M5_OUTPUT_LEVEL=${M5_OUTPUT_LEVEL})
endif()
