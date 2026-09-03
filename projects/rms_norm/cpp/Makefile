ROOTDIR := ../../..
COMMON_CPP_DIR := $(ROOTDIR)/lib/cpp

CXX ?= g++
CPPFLAGS += -I$(COMMON_CPP_DIR)
CXXFLAGS ?= -Wall -Wextra -Wpedantic
LDLIBS += -pthread

PROJECT_SOURCES := $(wildcard *.cpp)
PROJECT_HEADERS := $(wildcard *.h)
COMMON_SOURCES := $(COMMON_CPP_DIR)/ttyifc.cpp
COMMON_HEADERS := $(COMMON_CPP_DIR)/ttyifc.h
TARGET := obj/main

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(PROJECT_SOURCES) $(PROJECT_HEADERS) $(COMMON_SOURCES) $(COMMON_HEADERS)
	mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -DSYNTH -o $@ $(PROJECT_SOURCES) $(COMMON_SOURCES) $(LDLIBS)

clean:
	rm -rf obj
