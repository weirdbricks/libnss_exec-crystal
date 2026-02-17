# Makefile for libnss_exec — Crystal implementation (v3.0.0)
#
# Single-file build: src/libnss_exec.cr → libnss_exec.so.2
# No GC, no Crystal runtime dependencies. Safe for dlopen().
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# License: MIT

# ── Tools ────────────────────────────────────────────────────────────────
CRYSTAL  := crystal
INSTALL  := install
RM       := rm -f

# ── Installation paths ───────────────────────────────────────────────────
PREFIX   := /usr
LIBDIR   ?= $(shell pkg-config --variable=libdir libc 2>/dev/null || echo $(PREFIX)/lib)
SBINDIR  := $(PREFIX)/sbin
DESTDIR  :=

# ── Library details ──────────────────────────────────────────────────────
LIB_NAME    := libnss_exec
LIB_VERSION := 2
LIB_FILE    := $(LIB_NAME).so.$(LIB_VERSION)

# ── Source files ─────────────────────────────────────────────────────────
SRC_DIR  := src
SRC_FILE := $(SRC_DIR)/libnss_exec.cr

# ── Compiler flags ───────────────────────────────────────────────────────
CRYSTAL_FLAGS := --release --no-debug
LINK_FLAGS    := -shared -Wl,-soname,$(LIB_FILE)

# ── Phony targets ────────────────────────────────────────────────────────
.PHONY: all build clean install uninstall format check symbols deps lint help

# ── Default ──────────────────────────────────────────────────────────────
all: build

# ── Build the shared library ─────────────────────────────────────────────
build: $(LIB_FILE)

$(LIB_FILE): $(SRC_FILE)
	@echo "==> Building $(LIB_FILE) ..."
	$(CRYSTAL) build $(CRYSTAL_FLAGS) \
		--link-flags "$(LINK_FLAGS)" \
		-o $(LIB_FILE) \
		$(SRC_FILE)
	@echo "==> $(LIB_FILE) built successfully."

# ── Verify exported symbols ──────────────────────────────────────────────
symbols: $(LIB_FILE)
	@echo "==> Exported NSS symbols:"
	@nm -D $(LIB_FILE) | grep ' T _nss_exec' | sort
	@count=$$(nm -D $(LIB_FILE) | grep -c ' T _nss_exec'); \
		echo "==> $$count symbols exported (expected: 14)"

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

# ── Formatting ───────────────────────────────────────────────────────────
check:
	@echo "==> Checking formatting ..."
	$(CRYSTAL) tool format --check $(SRC_DIR)/ || \
		{ echo "Run 'make format' to fix."; exit 1; }
	@echo "==> Formatting OK."

format:
	@echo "==> Formatting ..."
	$(CRYSTAL) tool format $(SRC_DIR)/
	@echo "==> Done."

# ── Linting ───────────────────────────────────────────────────────────
deps:
	@echo "==> Installing shard dependencies ..."
	shards install

lint: deps
	@echo "==> Running Ameba linter ..."
	./bin/ameba $(SRC_DIR)/
	@echo "==> Ameba passed."

# ── Clean ────────────────────────────────────────────────────────────────
clean:
	@echo "==> Cleaning ..."
	$(RM) $(LIB_FILE) *.o *.dwarf
	@echo "==> Clean."

distclean: clean
	$(RM) -r lib/ bin/ .shards/

# ── Help ─────────────────────────────────────────────────────────────────
help:
	@echo "libnss_exec — Crystal NSS module (v3.0.0, no-GC)"
	@echo ""
	@echo "Targets:"
	@echo "  build      Build the NSS shared library (default)"
	@echo "  symbols    Show exported NSS entry points"
	@echo "  install    Install to \$$(LIBDIR)"
	@echo "  uninstall  Remove the installed library"
	@echo "  check      Verify code formatting"
	@echo "  format     Auto-format Crystal source"
	@echo "  deps       Install shard dependencies (Ameba)"
	@echo "  lint       Run Ameba static analysis"
	@echo "  clean      Remove build artifacts"
	@echo "  distclean  Remove build artifacts and shard deps"
	@echo "  help       This message"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX=$(PREFIX)  LIBDIR=$(LIBDIR)  DESTDIR=$(DESTDIR)"
	@echo ""
	@echo "Quick start:"
	@echo "  make                         # Build library"
	@echo "  make symbols                 # Verify NSS symbols"
	@echo "  sudo make install            # Install to system"
	@echo ""
	@echo "Testing:"
	@echo "  cd test && ./generate_test_data.sh"
	@echo "  cd test && ./stress_test.sh -N     # Script-only"
	@echo "  cd test && ./stress_test.sh        # Full NSS integration"
