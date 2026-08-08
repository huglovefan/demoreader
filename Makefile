dmd ?= dmd -mcpu=native -defaultlib=libphobos2.so
LDC ?= ldc2 -mcpu=native
GDC ?= gdc -march=native

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
 # ...
 LDCFLAGS += -O3 -flto=full
 LDCFLAGS += --frame-pointer=none
 LDCFLAGS += --fvisibility=hidden
 # ...
 GDCFLAGS += -O3 -flto=auto
 GDCFLAGS += -fallow-store-data-races
 GDCFLAGS += -fdevirtualize-at-ltrans
 GDCFLAGS += -fipa-pta
 GDCFLAGS += -fno-semantic-interposition
 GDCFLAGS += -fno-weak-templates
 GDCFLAGS += -fomit-frame-pointer
 GDCFLAGS += -fvisibility=hidden
 GDCFLAGS += -static-libphobos
endif
ifneq (,$(release))
 DMDFLAGS += -release
 LDCFLAGS += --release
 GDCFLAGS += -frelease
endif

ifeq (1,$(pgo))
 LDCFLAGS += -fprofile-generate
 GDCFLAGS += -fprofile-generate
endif
ifeq (2,$(pgo))
 # ldc note: first, run: llvm-profdata merge default_*.profraw -o default.profdata
 # ldc note2: this seems to be broken for me (breaks D module resolution?)
 LDCFLAGS += -fprofile-use
 GDCFLAGS += -fprofile-use
endif

-include user.mk
DMDFLAGS += $(mydflags) $(mydmdflags)
LDCFLAGS += $(mydflags) $(myldcflags)
GDCFLAGS += $(mydflags) $(mygdcflags)

demoreader: src/*.d src/*/*.d
	$(dmd) $(DMDFLAGS) -i -mv=demoreader=src src/main.d -of=$@
	rm -f $@.o
test:
	$(dmd) $(DMDFLAGS) -i -mv=demoreader=src -debug -unittest -run src/main.d
watch:
	ls src/*.d src/*/*.d | entr -cs 'make -s $(watchtgt)'

ldc:
	$(LDC) $(LDCFLAGS) -i --mv=demoreader=src src/main.d --of=demoreader
	rm -f demoreader.o

gdc:
	$(GDC) $(GDCFLAGS) src/*.d src/*/*.d -o demoreader -lsnappy

export WINEDEBUG = -all
wine:
	wine dmd -m64 $(DMDFLAGS) -i -mv=demoreader=src src/main.d -of=demoreader.exe

.PHONY: cleanpgo
cleanpgo:
	find -name '*.gcda' -exec rm -v {} +
	rm -fv default*.prof*
