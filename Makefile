ELIXIR_DIR := elixir
.DEFAULT_GOAL := default

.PHONY: default FORCE

Makefile: ;

define ELIXIR_MAKE
cd $(ELIXIR_DIR) && if command -v mise >/dev/null 2>&1; then mise exec -- $(MAKE) $(1); else $(MAKE) $(1); fi
endef

default:
	$(call ELIXIR_MAKE)

%: FORCE
	$(call ELIXIR_MAKE,$@)

FORCE:
