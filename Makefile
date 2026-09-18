.PHONY: up down restart ps logs build toolbox scenarios adb clean reset status
COMPOSE ?= docker compose

up:            ## build and start the bench
	$(COMPOSE) up -d --build --wait
down:          ## stop and remove containers (keeps traces/)
	$(COMPOSE) down --remove-orphans
restart:       ## restart with a fresh state
	$(COMPOSE) down --remove-orphans && $(COMPOSE) up -d --wait
ps:
	$(COMPOSE) ps
logs:          ## follow all container logs
	$(COMPOSE) logs -f --tail=50
build:
	$(COMPOSE) --profile tools build
toolbox:       ## interactive tester shell (adb, tshark, robot)
	$(COMPOSE) run --rm --no-deps toolbox
scenarios:     ## run the scenario runner -> traces/pcap/scenarios/<ts>/
	$(COMPOSE) run --rm --no-deps scenario-runner
adb:           ## quick adb check from the toolbox
	$(COMPOSE) run --rm --no-deps toolbox sh -c 'adb connect ecu-gateway:5555 && adb -s ecu-gateway:5555 shell getprop ro.product.model'
status:        ## vehicle status via REST
	curl -s -H "X-API-Key: dev-key-001" http://localhost:8000/vehicle/status | python3 -m json.tool
reset:         ## reset vehicle + backend state
	curl -s -X POST -H "X-API-Key: dev-key-001" http://localhost:8000/bench/reset
clean: down    ## also delete generated traces
	rm -rf traces/logs/* traces/pcap
