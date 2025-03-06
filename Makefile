# Copyright © 2024 Intel Corporation. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

.PHONY: build build-realsense run down
.PHONY: build-telegraf run-telegraf run-portainer clean-all clean-results clean-telegraf clean-models down-portainer
.PHONY: download-models clean-test run-demo run-headless

MKDOCS_IMAGE ?= asc-mkdocs
PIPELINE_COUNT ?= 1
INIT_DURATION ?= 30
TARGET_FPS ?= 14.95
CONTAINER_NAMES ?= gst0
DOCKER_COMPOSE ?= docker-compose.yml
RESULTS_DIR ?= $(PWD)/results
RETAIL_USE_CASE_ROOT ?= $(PWD)
DENSITY_INCREMENT ?= 1

download-models:
	./download_models/downloadModels.sh

download-sample-videos:
	cd performance-tools/benchmark-scripts && ./download_sample_videos.sh

clean-models:
	@find ./models/ -mindepth 1 -maxdepth 1 -type d -exec sudo rm -r {} \;

run-smoke-tests: | download-models update-submodules download-sample-videos
	@echo "Running smoke tests for OVMS profiles"
	@./smoke_test.sh > smoke_tests_output.log
	@echo "results of smoke tests recorded in the file smoke_tests_output.log"
	@grep "Failed" ./smoke_tests_output.log || true
	@grep "===" ./smoke_tests_output.log || true

update-submodules:
	@git submodule update --init --recursive
	@git submodule update --remote --merge

build:
	docker build --build-arg HTTPS_PROXY=${HTTPS_PROXY} --build-arg HTTP_PROXY=${HTTP_PROXY} --target build-default -t dlstreamer:dev -f src/Dockerfile src/

build-realsense:
	docker build --build-arg HTTPS_PROXY=${HTTPS_PROXY} --build-arg HTTP_PROXY=${HTTP_PROXY} --target build-realsense -t dlstreamer:realsense -f src/Dockerfile src/

build-pipeline-server: | download-models update-submodules download-sample-videos
	docker build -t dlstreamer:pipeline-server -f src/pipeline-server/Dockerfile.pipeline-server src/pipeline-server

run:
	docker compose -f src/$(DOCKER_COMPOSE) up -d

run-render-mode:
	xhost +local:docker
	RENDER_MODE=1 docker compose -f src/$(DOCKER_COMPOSE) up -d

down:
	docker compose -f src/$(DOCKER_COMPOSE) down
	docker container stop grafana mqtt-broker
	docker container rm grafana mqtt-broker

run-demo: | download-models update-submodules download-sample-videos
	@echo "Building automated self checkout app"	
	$(MAKE) build
	@echo Running automated self checkout pipeline
	$(MAKE) run-render-mode
	

run-mqtt:
	# Check if python3 -m venv is available
	@echo "Checking if Python's venv module is available..."
	@python3 -m venv test-env > /dev/null 2>&1; \
	if [ $$? -ne 0 ]; then \
		echo "It looks like 'python3-venv' is not installed."; \
		if [ "$(shell uname)" = "Linux" ]; then \
			echo "To install it on Ubuntu/Debian, run: sudo apt install python3-venv"; \
		elif [ "$(shell uname)" = "Darwin" ]; then \
			echo "To install it on macOS, run: brew install python3"; \
		elif [ "$(shell uname)" = "MINGW64_NT" ]; then \
			echo "To install it on Windows, make sure you have Python 3 installed from https://www.python.org/downloads/"; \
		else \
			echo "Unsupported OS or environment."; \
		fi; \
		exit 1; \
	else \
		echo "Virtual environment module is available."; \
		rm -rf test-env; \
	fi
	
	docker compose up -d
	rm -f performance-tools/benchmark-scripts/results/* 2>/dev/null
	$(MAKE) benchmark-cmd
	# Create a virtual environment (if not already created)
	python3 -m venv venv
	
	# Activate the virtual environment and install dependencies
	. venv/bin/activate && pip install --upgrade pip paho-mqtt
	
	# Run the required Python scripts in the background
	. venv/bin/activate && python mqtt/publisher_intel.py &
	. venv/bin/activate && python mqtt/fps_extracter.py &
	
	@echo "To view the results, open the browser and navigate to http://localhost:3000"
	wait

benchmark-cmd:
	$(MAKE) PIPELINE_COUNT=2 DURATION=60 DEVICE_ENV=res/all-cpu.env RESULTS_DIR=cpu benchmark

run-headless: | download-models update-submodules download-sample-videos
	@echo "Building automated self checkout app"
	$(MAKE) build
	@echo Running automated self checkout pipeline
	$(MAKE) run

run-pipeline-server: | build-pipeline-server
	RETAIL_USE_CASE_ROOT=$(RETAIL_USE_CASE_ROOT) docker compose -f src/pipeline-server/docker-compose.pipeline-server.yml up -d

down-pipeline-server:
	docker compose -f src/pipeline-server/docker-compose.pipeline-server.yml down

build-benchmark:
	cd performance-tools && $(MAKE) build-benchmark-docker

benchmark: build-benchmark download-models
	cd performance-tools/benchmark-scripts && python benchmark.py --compose_file ../../src/docker-compose.yml --pipeline $(PIPELINE_COUNT)

benchmark-stream-density: build-benchmark download-models
	@cd performance-tools/benchmark-scripts && \
	python benchmark.py \
	  --compose_file ../../src/docker-compose.yml \
	  --init_duration $(INIT_DURATION) \
	  --target_fps $(TARGET_FPS) \
	  --container_names $(CONTAINER_NAMES) \
	  --density_increment $(DENSITY_INCREMENT) \
	  --results_dir $(RESULTS_DIR)

build-telegraf:
	cd telegraf && $(MAKE) build

run-telegraf:
	cd telegraf && $(MAKE) run

clean-telegraf: 
	./clean-containers.sh influxdb2
	./clean-containers.sh telegraf

run-portainer:
	docker compose -p portainer -f docker-compose-portainer.yml up -d

down-portainer:
	docker compose -p portainer -f docker-compose-portainer.yml down

clean-results:
	rm -rf results/*

clean-all: 
	docker rm -f $(docker ps -aq)

docs: clean-docs
	mkdocs build
	mkdocs serve -a localhost:8008

docs-builder-image:
	docker build \
		-f Dockerfile.docs \
		-t $(MKDOCS_IMAGE) \
		.

build-docs: docs-builder-image
	docker run --rm \
		-u $(shell id -u):$(shell id -g) \
		-v $(PWD):/docs \
		-w /docs \
		$(MKDOCS_IMAGE) \
		build

serve-docs: docs-builder-image
	docker run --rm \
		-it \
		-u $(shell id -u):$(shell id -g) \
		-p 8008:8000 \
		-v $(PWD):/docs \
		-w /docs \
		$(MKDOCS_IMAGE)

clean-docs:
	rm -rf docs/

helm-package:
	helm package helm/ -u -d .deploy
	helm package helm/
	helm repo index .
	helm repo index --url https://github.com/intel-retail/automated-self-checkout .