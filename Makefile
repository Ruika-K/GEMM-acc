RTL := $(wildcard rtl/*.sv)

.PHONY: lint test clean

lint:
	verilator --lint-only -Wall --top-module gemm_top $(RTL)

test:
	python3 -m pytest tb/ -v

clean:
	rm -rf sim_build tb/__pycache__ .pytest_cache tb/*.xml
