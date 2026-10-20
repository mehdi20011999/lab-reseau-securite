# Raccourcis : make install | up | test | status | down | all
.PHONY: install up test status down all
install: ; sudo ./scripts/install.sh
up:      ; sudo ./lab.sh up
test:    ; sudo ./lab.sh test
status:  ; sudo ./lab.sh status
down:    ; sudo ./lab.sh down
all: up test
