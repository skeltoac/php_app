INCLUDEDIR=src
TARGETDIR=ebin
SRCDIR=src

INCLUDEFLAGS=$(patsubst %,-I%, ${INCLUDEDIR})

MODULES = php_app php php_eval php_sup php_util
INCLUDES = 
TARGETS = $(patsubst %,${TARGETDIR}/%.beam,${MODULES})
HEADERS = $(patsubst %,${INCLUDEDIR}/%.hrl,${INCLUDES})

all: ${TARGETS}

$(TARGETS): ${TARGETDIR}/%.beam: ${SRCDIR}/%.erl ${HEADERS}
	mkdir -p ebin
	erlc ${INCLUDEFLAGS} -o ${TARGETDIR} $<
	cp ${SRCDIR}/*.app $(TARGETDIR)

clean:
	rm -f ${TARGETDIR}/*.beam
