EDITORS ?= vim nvim
SPECS ?= $(wildcard tests/test_*.vim)

.PHONY: test

# Each spec runs in its own Vim and Neovim with isolated state, against the fake provider of tests/autoload/fake.vim
test:
	@failed=0; for editor in $(EDITORS); do \
		echo "== $$editor"; \
		case $$editor in \
			*nvim*) cmd="$$editor --headless -u NONE -i NONE";; \
			*) cmd="$$editor -Nu NONE -i NONE --not-a-term";; \
		esac; \
		for spec in $(SPECS); do \
			tmp=$$(mktemp -d); \
			TEST_RESULT=$$tmp/result XDG_STATE_HOME=$$tmp/state XDG_DATA_HOME=$$tmp/data XDG_CONFIG_HOME=$$tmp/config \
				$$cmd -S tests/runner.vim $$spec </dev/null >/dev/null || failed=1; \
			cat $$tmp/result 2>/dev/null || { echo "$$spec: did not finish"; failed=1; }; \
			rm -rf $$tmp; \
		done; \
	done; exit $$failed
