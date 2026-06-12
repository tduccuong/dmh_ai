# Builds the vendored spellfix1 SQLite extension (fuzzy typo repair,
# spec §3.4) into priv/spellfix1.so on every `mix compile` via
# elixir_make. Compiled against exqlite's vendored sqlite3ext.h so the
# ABI matches the runtime SQLite exactly, in dev / test / CI / image.

EXQLITE_INCLUDE = deps/exqlite/c_src
SPELLFIX_SO  = priv/spellfix1.so
SPELLFIX_SRC = priv/sqlite_ext/spellfix1.c

all: $(SPELLFIX_SO)

$(SPELLFIX_SO): $(SPELLFIX_SRC)
	@mkdir -p priv
	$(CC) -fPIC -shared -O3 -I $(EXQLITE_INCLUDE) $(SPELLFIX_SRC) -o $(SPELLFIX_SO)

clean:
	rm -f $(SPELLFIX_SO)

.PHONY: all clean
