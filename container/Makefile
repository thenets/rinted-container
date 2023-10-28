IMAGE_TAG ?= quay.io/thenets/rinetd:latest

.PHONY: build
build:
	podman build -t $(IMAGE_TAG) \
		-f ./Dockerfile \
		$(ADDITIONAL_BUILD_ARGS) \
		./../

.PHONY: run
run:
	podman run --rm -it --net=host \
		-v $(PWD)/rinetd.conf:/etc/rinetd.conf:Z \
		$(IMAGE_TAG) \
		rinetd -f -c /etc/rinetd.conf

.PHONY: shell
shell:
	podman run --rm -it --net=host \
		-v $(PWD)/rinetd.conf:/etc/rinetd.conf:Z \
		$(IMAGE_TAG) \
		/bin/bash

.PHONY: release-build
release-build:
	make build ADDITIONAL_BUILD_ARGS="--squash" --no-print-directory

.PHONY: release-push
release-push:
	podman push $(IMAGE_TAG)
