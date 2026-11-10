RTL := $(wildcard rtl/*.sv)

.PHONY: lint test syn-ecp5 clean

lint:
	verilator --lint-only -Wall --top-module gemm_top $(RTL)

test:
	python3 -m pytest tb/ -v

syn-ecp5:
	python3 syn/ecp5/run.py

clean:
	rm -rf sim_build syn/build tb/__pycache__ .pytest_cache tb/*.xml
