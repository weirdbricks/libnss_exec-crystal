# Makefile for libnss_exec — Crystal implementation
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# License: MIT

# ── Tools ────────────────────────────────────────────────────────────────
CRYSTAL  := crystal
SHARDS   := shards
INSTALL  := install
RM       := rm -f

# ── Installation paths ───────────────────────────────────────────────────
PREFIX   := /usr
# Detect multiarch lib directory (Debian/Ubuntu use lib/x86_64-linux-gnu).
LIBDIR   ?= $(shell pkg-config --variable=libdir libc 2>/dev/null || echo $(PREFIX)/lib)
SBINDIR  := $(PREFIX)/sbin
DESTDIR  :=

# ── Library details ──────────────────────────────────────────────────────
LIB_NAME    := libnss_exec
LIB_VERSION := 2
LIB_FILE    := $(LIB_NAME).so.$(LIB_VERSION)

# ── Source files ─────────────────────────────────────────────────────────
SRC_DIR  := src
SOURCES  := $(wildcard $(SRC_DIR)/*.cr)
SPEC_DIR := spec
SPECS    := $(wildcard $(SPEC_DIR)/*_spec.cr)

# ── Compiler flags ───────────────────────────────────────────────────────
CRYSTAL_FLAGS := --release --no-debug
LINK_FLAGS    := -shared -Wl,-soname,$(LIB_FILE)

# ── Phony targets ────────────────────────────────────────────────────────
.PHONY: all build clean install uninstall \
        test spec lint format check \
        deps help

# ── Default ──────────────────────────────────────────────────────────────
all: build

# ── Build the shared library ─────────────────────────────────────────────
build: $(LIB_FILE)

$(LIB_FILE): $(SOURCES)
	@echo "==> Building $(LIB_FILE) ..."
	$(CRYSTAL) build $(CRYSTAL_FLAGS) \
		--link-flags "$(LINK_FLAGS)" \
		-o $(LIB_FILE) \
		$(SRC_DIR)/nss_passwd.cr $(SRC_DIR)/nss_group.cr $(SRC_DIR)/nss_shadow.cr
	@echo "==> $(LIB_FILE) built successfully."

# ── Install dependencies (Ameba, etc.) ───────────────────────────────────
deps:
	@echo "==> Installing shard dependencies ..."
	$(SHARDS) install

# ── Install the library ──────────────────────────────────────────────────
install: $(LIB_FILE)
	@echo "==> Installing $(LIB_FILE) to $(DESTDIR)$(LIBDIR) ..."
	$(INSTALL) -D -m 0755 $(LIB_FILE) $(DESTDIR)$(LIBDIR)/$(LIB_FILE)
	@if [ -z "$(DESTDIR)" ] && command -v ldconfig >/dev/null 2>&1; then \
		echo "==> Running ldconfig ..."; \
		ldconfig; \
	fi
	@echo ""
	@echo "Installation complete. Next steps:"
	@echo "  1. Create /sbin/nss_exec  (see examples/nss_exec.sh)"
	@echo "  2. chmod +x /sbin/nss_exec"
	@echo "  3. Add 'exec' to /etc/nsswitch.conf (AFTER files)"
	@echo "  4. Test: getent passwd testuser"

# ── Uninstall ────────────────────────────────────────────────────────────
uninstall:
	@echo "==> Removing $(DESTDIR)$(LIBDIR)/$(LIB_FILE) ..."
	$(RM) $(DESTDIR)$(LIBDIR)/$(LIB_FILE)
	@if [ -z "$(DESTDIR)" ] && command -v ldconfig >/dev/null 2>&1; then \
		ldconfig; \
	fi
	@echo "==> Uninstalled. Remember to remove 'exec' from /etc/nsswitch.conf."

# ── Testing ──────────────────────────────────────────────────────────────
# Run Crystal spec suite (pure-Crystal unit tests, no root needed).
spec:
	@echo "==> Running specs ..."
	$(CRYSTAL) spec $(SPEC_DIR)/

# Alias
test: spec

# ── Linting & formatting ────────────────────────────────────────────────
# Check Crystal formatting (non-destructive).
check:
	@echo "==> Checking formatting ..."
	$(CRYSTAL) tool format --check $(SRC_DIR)/ $(SPEC_DIR)/ || \
		{ echo "Run 'make format' to fix."; exit 1; }
	@echo "==> Formatting OK."

# Auto-format Crystal source.
format:
	@echo "==> Formatting ..."
	$(CRYSTAL) tool format $(SRC_DIR)/ $(SPEC_DIR)/
	@echo "==> Done."

# Run Ameba static analysis.
lint: deps
	@echo "==> Running Ameba linter ..."
	./bin/ameba $(SRC_DIR)/ $(SPEC_DIR)/
	@echo "==> Ameba passed."

# ── Clean ────────────────────────────────────────────────────────────────
clean:
	@echo "==> Cleaning ..."
	$(RM) $(LIB_FILE) test_nss_exec *.o *.dwarf
	@echo "==> Clean."

# Deep clean including shard deps
distclean: clean
	$(RM) -r lib/ bin/ .shards/

# ── Help ─────────────────────────────────────────────────────────────────
help:
	@echo "libnss_exec Crystal Implementation"
	@echo ""
	@echo "Targets:"
	@echo "  build      Build the NSS shared library (default)"
	@echo "  install    Install to \$$(LIBDIR)"
	@echo "  uninstall  Remove the installed library"
	@echo "  deps       Install shard dependencies (Ameba)"
	@echo "  spec       Run Crystal spec test suite"
	@echo "  test       Alias for spec"
	@echo "  check      Verify code formatting"
	@echo "  format     Auto-format Crystal source"
	@echo "  lint       Run Ameba static analysis"
	@echo "  clean      Remove build artifacts"
	@echo "  distclean  Remove build artifacts and shard deps"
	@echo "  help       This message"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX=$(PREFIX)  LIBDIR=$(LIBDIR)  DESTDIR=$(DESTDIR)"
	@echo ""
	@echo "Examples:"
	@echo "  make                         # Build library"
	@echo "  make spec                    # Run unit tests"
	@echo "  make lint                    # Static analysis"
	@echo "  sudo make install            # Install to system"
	@echo "  make install PREFIX=/usr/local"
