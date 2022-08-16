
CAFLAGS := --target apple2enh --list-bytes 0
LDFLAGS := --config apple2-asm.cfg

OUTDIR := out

TARGETS := $(OUTDIR)/cdremote.BIN

.PHONY: clean all
all: $(OUTDIR) $(TARGETS)

$(OUTDIR):
	mkdir -p $(OUTDIR)

HEADERS := $(wildcard *.inc)

clean:
	rm -f $(OUTDIR)/*.o
	rm -f $(OUTDIR)/*.list
	rm -f $(TARGETS)

$(OUTDIR)/%.o: %.s $(HEADERS)
	ca65 $(CAFLAGS) $(DEFINES) --listing $(basename $@).list -o $@ $<

$(OUTDIR)/%.BIN: $(OUTDIR)/%.o
	ld65 $(LDFLAGS) -o $@ $<
