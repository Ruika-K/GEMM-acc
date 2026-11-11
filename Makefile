RTL := $(wildcard rtl/*.sv)

.PHONY: lint test syn-ecp5 syn-asic clean clean-syn

lint:
	verilator --lint-only -Wall --top-module gemm_top $(RTL)

test:
	python3 -m pytest tb/ -v

syn-ecp5:
	python3 syn/ecp5/run.py

syn-asic:
	python3 syn/asic/run.py

clean:
	rm -rf sim_build tb/__pycache__ .pytest_cache tb/*.xml

# Synthesis runs take long and their reports are not kept anywhere else.
clean-syn:
	rm -rf syn/build
