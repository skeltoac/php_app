SOURCEDIR  := src
INCLUDEDIR := include
TARGETDIR  := ebin

INCLUDEFLAGS := $(patsubst %,-I %, $(INCLUDEDIR))

MODULES  := $(patsubst $(SOURCEDIR)/%.erl,%,$(wildcard $(SOURCEDIR)/*.erl))
APPS     := $(patsubst $(SOURCEDIR)/%.app,%,$(wildcard $(SOURCEDIR)/*.app))

INCLUDES := $(wildcard $(INCLUDEDIR)/*.hrl)
TARGETS  := $(patsubst %,$(TARGETDIR)/%.beam,$(MODULES))
APPFILES := $(patsubst %,$(TARGETDIR)/%.app,$(APPS))

all : $(TARGETDIR) $(APPFILES) $(TARGETS)

$(TARGETDIR) :
	@echo "Creating target directory $(TARGETDIR)"
	@mkdir -p $(TARGETDIR)

$(TARGETS) : $(TARGETDIR)/%.beam: $(SOURCEDIR)/%.erl $(INCLUDES)
	@echo "Compiling module $*"
	@erlc $(INCLUDEFLAGS) -o $(TARGETDIR) $<

$(APPFILES) : $(TARGETDIR)/%.app: $(SOURCEDIR)/%.app
	@echo "Copying application $*"
	@cp $< $@

clean :
	@if [ -d $(TARGETDIR) ]; then \
		echo "Deleting ebin and app files from $(TARGETDIR)..."; \
		rm -f $(TARGETS) $(APPFILES); \
		rmdir $(TARGETDIR); \
	 else \
		echo "Nothing to clean."; \
	 fi
	@rm -f erl_crash.dump
