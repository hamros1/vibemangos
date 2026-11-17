# Builds thirdparty/build/libdmnav.a: Recast and Detour (recastnavigation 1.6.0, zlib licence) and
# dmangos's C interface to them (dmnav/dmnav.cpp). dub runs this before every build; it only
# compiles what changed.

CXX ?= g++
CXXFLAGS ?= -O2 -fPIC -fno-exceptions -fno-rtti -DDT_POLYREF64 -Wno-class-memaccess
INCLUDES = -Irecastnavigation/Recast/Include -Irecastnavigation/Detour/Include

SOURCES = $(wildcard recastnavigation/Recast/Source/*.cpp) $(wildcard recastnavigation/Detour/Source/*.cpp) dmnav/dmnav.cpp
OBJECTS = $(patsubst %.cpp,build/obj/%.o,$(SOURCES))

build/libdmnav.a: $(OBJECTS)
	@mkdir -p build
	ar rcs $@ $^

build/obj/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

clean:
	rm -rf build

.PHONY: clean
