dmd ?= dmd -mcpu=native -defaultlib=libphobos2.so
LDC ?= ldc2 -mcpu=native
GDC ?= gdc -march=native -fuse-ld=mold

DMDFLAGS += -g
LDCFLAGS += -g
GDCFLAGS += -Wall -g

ifneq (,$(debug))
 DMDFLAGS += -debug
 LDCFLAGS += --d-debug --link-defaultlib-debug
 GDCFLAGS += -fdebug
endif
ifneq (,$(opt))
 DMDFLAGS += -O
 LDCFLAGS += -O3 -flto=thin
 GDCFLAGS += -O3 -flto=auto -fipa-pta -fdevirtualize-at-ltrans
 # ...
 GDCFLAGS += -fallow-store-data-races
 GDCFLAGS += -fgcse-sm
 GDCFLAGS += -fgcse-las
 GDCFLAGS += -fira-loop-pressure
 GDCFLAGS += -fno-semantic-interposition
 GDCFLAGS += -fvisibility=hidden
 GDCFLAGS += -fno-plt
 # -funfuck-math
 GDCFLAGS += -ffp-contract=off
 GDCFLAGS += -frounding-math
 GDCFLAGS += -fsignaling-nans
endif
ifneq (,$(release))
 DMDFLAGS += -release
 LDCFLAGS += --release
 GDCFLAGS += -frelease
endif

ifeq (1,$(pgo))
 GDCFLAGS += -fprofile-generate
endif
ifeq (2,$(pgo))
 GDCFLAGS += -fprofile-use
endif

DMDFLAGS += $(mydflags)
LDCFLAGS += $(mydflags)

demoreader: src/*.d src/*/*.d
	$(dmd) $(DMDFLAGS) -i -mv=demoreader=src src/main.d -of=$@
test:
	$(dmd) $(DMDFLAGS) -i -mv=demoreader=src -debug -unittest -run src/main.d
watch:
	ls src/*.d src/*/*.d | entr -cs 'make -s $(watchtgt)'

ldc:
	$(LDC) $(LDCFLAGS) src/*.d src/*/*.d --of=demoreader

gdc:
	$(GDC) $(GDCFLAGS) src/*.d src/*/*.d -o demoreader -lsnappy

export WINEDEBUG = -all
wine:
	wine dmd -m64 $(DMDFLAGS) -i -mv=demoreader=src src/main.d -of=demoreader.exe
