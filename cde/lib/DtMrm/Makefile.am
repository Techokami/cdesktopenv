MAINTAINERCLEANFILES = Makefile.in

lib_LTLIBRARIES = libDtMrm.la

AM_CPPFLAGS = \
	-I$(top_srcdir)/include \
	-I$(top_srcdir)/include/DtI \
	-I$(top_srcdir)/lib/DtTerm/Term \
	-I$(top_srcdir)/lib/DtTerm/TermPrim \
	-I$(top_srcdir)/lib/DtHelp

libDtMrm_la_CFLAGS = @DT_INCDIR@ @DTI_INCDIR@

libDtMrm_la_SOURCES = DtMrm.c

# in order to try to keep lib versions the same across platforms, (2.1.0)
if BSD
libDtMrm_la_LDFLAGS = -version-info 2:1:0
else
libDtMrm_la_LDFLAGS = -version-info 3:0:1
endif

