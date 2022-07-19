.PHONY: aur init

aur:
	@gprbuild -j0 -P src/aur/aur

init:
	@git submodule update --init --recursive
	@cd src/aur/ada-toml && make
	@cd src/aur/ada-util && ./configure && make
