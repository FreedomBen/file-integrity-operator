# Operator variables
# ==================
export APP_NAME=file-integrity-operator
AIDE=aide

# Container image variables
# =========================
IMAGE_REPO?=quay.io/file-integrity-operator
RUNTIME?=podman

# Image path to use. Set this if you want to use a specific path for building
# or your e2e tests. This is overwritten if we bulid the image and push it to
# the cluster or if we're on CI.
RELATED_IMAGE_OPERATOR_PATH?=$(IMAGE_REPO)/$(APP_NAME)
RELATED_IMAGE_AIDE_PATH?=$(IMAGE_REPO)/$(AIDE)
AIDE_DOCKERFILE_PATH?=./images/aide/Dockerfile

# Image tag to use. Set this if you want to use a specific tag for building
# or your e2e tests.
TAG?=latest

# Build variables
# ===============
CURPATH=$(PWD)
TARGET_DIR=$(CURPATH)/build/_output
GO=GOFLAGS=-mod=vendor GO111MODULE=auto go
GOBUILD=$(GO) build
BUILD_GOPATH=$(TARGET_DIR):$(CURPATH)/cmd
TARGET_OPERATOR=$(TARGET_DIR)/bin/$(APP_NAME)
MAIN_PKG=cmd/manager/main.go
PKGS=$(shell go list ./... | grep -v -E '/vendor/|/test|/examples')

# go source files, ignore vendor directory
SRC = $(shell find . -type f -name '*.go' -not -path "./vendor/*" -not -path "./_output/*")


# Kubernetes variables
# ====================
KUBECONFIG?=$(HOME)/.kube/config
export NAMESPACE?=openshift-file-integrity

# Operator-sdk variables
# ======================
SDK_VERSION?=v0.18.1
OPERATOR_SDK_URL=https://github.com/operator-framework/operator-sdk/releases/download/$(SDK_VERSION)/operator-sdk-$(SDK_VERSION)-x86_64-linux-gnu

# Test variables
# ==============
TEST_OPTIONS?=
# Skip pushing the container to your cluster
E2E_SKIP_CONTAINER_PUSH?=false
# Use default images in the e2e test run. Note that this takes precedence over E2E_SKIP_CONTAINER_PUSH
E2E_USE_DEFAULT_IMAGES?=false

# Pass extra flags to the e2e test run.
# e.g. to run a specific test in the e2e test suite, do:
# 	make e2e E2E_GO_TEST_FLAGS="-v -run TestE2E/TestScanWithNodeSelectorFiltersCorrectly"
E2E_GO_TEST_FLAGS?=-v -timeout 30m

# operator-courier arguments for `make publish`.
# Before running `make publish`, install operator-courier with `pip3 install operator-courier` and create
# ~/.quay containing your quay.io token.
COURIER_CMD=operator-courier
COURIER_PACKAGE_NAME=file-integrity-operator-bundle
COURIER_OPERATOR_DIR=deploy/olm-catalog/file-integrity-operator
COURIER_QUAY_NAMESPACE=file-integrity-operator
COURIER_PACKAGE_VERSION?=
OLD_COURIER_PACKAGE_VERSION=$(shell find deploy/olm-catalog/file-integrity-operator/ -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -1)
COURIER_QUAY_TOKEN?= $(shell cat ~/.quay)
PACKAGE_CHANNEL?=alpha

.PHONY: all
all: build ## Test and Build the file-integrity-operator

.PHONY: help
help: ## Show this help screen
	@echo 'Usage: make <OPTIONS> ... <TARGETS>'
	@echo ''
	@echo 'Available targets are:'
	@echo ''
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)


.PHONY: image
image: operator-image aide-image fmt operator-sdk ## Build the file-integrity-operator container image

operator-image: operator-sdk
	$(GOPATH)/bin/operator-sdk build $(RELATED_IMAGE_OPERATOR_PATH):$(TAG) --image-builder $(RUNTIME)

aide-image:
	$(RUNTIME) build -f $(AIDE_DOCKERFILE_PATH) -t $(RELATED_IMAGE_AIDE_PATH):$(TAG) .

.PHONY: build
build: operator-bin ## Build the file-integrity-operator binaries

operator-bin:
	$(GO) build -race -o $(TARGET_OPERATOR) github.com/openshift/file-integrity-operator/cmd/manager

.PHONY: operator-sdk
operator-sdk: $(GOPATH)/bin/operator-sdk

$(GOPATH)/bin/operator-sdk:
	wget -nv $(OPERATOR_SDK_URL) -O $(GOPATH)/bin/operator-sdk || (echo "wget returned $$? trying to fetch operator-sdk. please install operator-sdk and try again"; exit 1)
	chmod +x $(GOPATH)/bin/operator-sdk

.PHONY: run
run: operator-sdk ## Run the file-integrity-operator locally
	WATCH_NAMESPACE=$(NAMESPACE) \
	KUBERNETES_CONFIG=$(KUBECONFIG) \
	OPERATOR_NAME=$(APP_NAME) \
	$(GOPATH)/bin/operator-sdk run --local --watch-namespace $(NAMESPACE) --operator-flags operator

.PHONY: clean
clean: clean-modcache clean-cache clean-output ## Clean the golang environment

.PHONY: clean-output
clean-output:
	rm -rf $(TARGET_DIR)

.PHONY: clean-cache
clean-cache:
	$(GO) clean -cache -testcache $(PKGS)

.PHONY: clean-modcache
clean-modcache:
	$(GO) clean -modcache $(PKGS)

.PHONY: fmt
fmt:  ## Run the `go fmt` tool
	@$(GO) fmt $(PKGS)

.PHONY: simplify
simplify:
	@gofmt -s -l -w $(SRC)

.PHONY: verify
verify: vet mod-verify gosec ## Run code lint checks

.PHONY: vet
vet:
	@$(GO) vet $(PKGS)

.PHONY: mod-verify
mod-verify:
	@$(GO) mod verify

.PHONY: gosec
gosec:
	@$(GO) run github.com/securego/gosec/cmd/gosec -severity medium -confidence medium -quiet ./...

.PHONY: generate
generate: operator-sdk ## Run operator-sdk's code generation (k8s and crds)
	$(GOPATH)/bin/operator-sdk generate k8s
	$(GOPATH)/bin/operator-sdk generate crds

.PHONY: test-unit
test-unit: fmt ## Run the unit tests
	@$(GO) test $(TEST_OPTIONS) $(PKGS)

.PHONY: deploy-to-cluster
ifeq ($(E2E_SKIP_CONTAINER_PUSH), false)
deploy-to-cluster: namespace image-to-cluster openshift-user
else
deploy-to-cluster: namespace
endif
	@echo "Deploying the local branch to cluster"
	@echo "WARNING: This will temporarily modify deploy/operator.yaml"
	@echo "Replacing workload references in deploy/operator.yaml"
	@sed -i 's%$(IMAGE_REPO)/$(AIDE):latest%$(RELATED_IMAGE_AIDE_PATH)%' deploy/operator.yaml
	@sed -i 's%$(IMAGE_REPO)/$(APP_NAME):latest%$(RELATED_IMAGE_OPERATOR_PATH)%' deploy/operator.yaml
	@oc create -f deploy/crds/fileintegrity.openshift.io_fileintegrities_crd.yaml || true
	@oc create -f deploy/crds/fileintegrity.openshift.io_fileintegritynodestatuses_crd.yaml || true
	@oc create -f deploy/role.yaml || true
	@oc create -f deploy/role_binding.yaml || true
	@oc create -f deploy/service_account.yaml || true
	@oc create -f deploy/operator.yaml || true
	@echo "Restoring image references in deploy/operator.yaml"
	@sed -i 's%$(RELATED_IMAGE_AIDE_PATH)%$(IMAGE_REPO)/$(AIDE):latest%' deploy/operator.yaml
	@sed -i 's%$(RELATED_IMAGE_OPERATOR_PATH)%$(IMAGE_REPO)/$(APP_NAME):latest%' deploy/operator.yaml

# This runs the end-to-end tests. If not running this on CI, it'll try to
# push the operator image to the cluster's registry. This behavior can be
# avoided with the E2E_SKIP_CONTAINER_PUSH environment variable.
.PHONY: e2e
ifeq ($(E2E_SKIP_CONTAINER_PUSH), false)
e2e: namespace operator-sdk image-to-cluster openshift-user ## Run the end-to-end tests
else
e2e: namespace operator-sdk
endif
	@echo "Running e2e tests"
	@echo "WARNING: This will temporarily modify deploy/operator.yaml"
	@echo "Replacing workload references in deploy/operator.yaml"
	@sed -i 's%$(IMAGE_REPO)/$(AIDE):latest%$(RELATED_IMAGE_AIDE_PATH)%' deploy/operator.yaml
	@sed -i 's%$(IMAGE_REPO)/$(APP_NAME):latest%$(RELATED_IMAGE_OPERATOR_PATH)%' deploy/operator.yaml
	unset GOFLAGS && $(GOPATH)/bin/operator-sdk test local ./tests/e2e --skip-cleanup-error --image "$(RELATED_IMAGE_OPERATOR_PATH)" --operator-namespace "$(NAMESPACE)" --go-test-flags "$(E2E_GO_TEST_FLAGS)"
	@echo "Restoring image references in deploy/operator.yaml"
	@sed -i 's%$(RELATED_IMAGE_AIDE_PATH)%$(IMAGE_REPO)/$(AIDE):latest%' deploy/operator.yaml
	@sed -i 's%$(RELATED_IMAGE_OPERATOR_PATH)%$(IMAGE_REPO)/$(APP_NAME):latest%' deploy/operator.yaml

# If IMAGE_FORMAT is not defined, it means that we're not running on CI, so we
# probably want to push the file-integrity-operator image to the cluster we're
# developing on. This target exposes temporarily the image registry, pushes the
# image, and remove the route in the end.
#
# The IMAGE_FORMAT variable comes from CI. It is of the format:
#     <image path in CI registry>:${component}
# Here define the `component` variable, so, when we overwrite the
# RELATED_IMAGE_OPERATOR_PATH variable, it'll expand to the component we need.
#
# If the E2E_SKIP_CONTAINER_PUSH environment variable is used, the target will
# assume that you've pushed images beforehand, and will merely set the
# necessary variables to use them.
#
# If the E2E_USE_DEFAULT_IMAGES environment variable is used, this will do
# nothing, and the default images will be used.
.PHONY: image-to-cluster
ifdef IMAGE_FORMAT
image-to-cluster:
	@echo "IMAGE_FORMAT variable detected. We're in a CI enviornment."
	@echo "Skipping image-to-cluster target."
	$(eval component = $(APP_NAME))
	$(eval RELATED_IMAGE_OPERATOR_PATH = $(IMAGE_FORMAT))
	# TODO(jaosorior): Add AIDE image to release repo and subsequently add it here.
else ifeq ($(E2E_USE_DEFAULT_IMAGES), true)
image-to-cluster:
	@echo "E2E_USE_DEFAULT_IMAGES variable detected. Using default images."
else ifeq ($(E2E_SKIP_CONTAINER_PUSH), true)
image-to-cluster:
	@echo "E2E_SKIP_CONTAINER_PUSH variable detected. Using previously pushed images."
	$(eval RELATED_IMAGE_OPERATOR_PATH = image-registry.openshift-image-registry.svc:5000/$(NAMESPACE)/$(APP_NAME):$(TAG))
	$(eval RELATED_IMAGE_AIDE_PATH = image-registry.openshift-image-registry.svc:5000/$(NAMESPACE)/$(AIDE):$(TAG))
else
image-to-cluster: namespace openshift-user image
	@echo "IMAGE_FORMAT variable missing. We're in local enviornment."
	@echo "Temporarily exposing the default route to the image registry"
	@oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
	@echo "Pushing image $(RELATED_IMAGE_OPERATOR_PATH):$(TAG) to the image registry"
	IMAGE_REGISTRY_HOST=$$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}'); \
		$(RUNTIME) login --tls-verify=false -u $(OPENSHIFT_USER) -p $(shell oc whoami -t) $${IMAGE_REGISTRY_HOST}; \
		$(RUNTIME) push --tls-verify=false $(RELATED_IMAGE_OPERATOR_PATH):$(TAG) $${IMAGE_REGISTRY_HOST}/$(NAMESPACE)/$(APP_NAME):$(TAG); \
		$(RUNTIME) push --tls-verify=false $(RELATED_IMAGE_AIDE_PATH):$(TAG) $${IMAGE_REGISTRY_HOST}/$(NAMESPACE)/$(AIDE):$(TAG)
	@echo "Removing the route from the image registry"
	@oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":false}}' --type=merge
	$(eval RELATED_IMAGE_OPERATOR_PATH = image-registry.openshift-image-registry.svc:5000/$(NAMESPACE)/$(APP_NAME):$(TAG))
	$(eval RELATED_IMAGE_AIDE_PATH = image-registry.openshift-image-registry.svc:5000/$(NAMESPACE)/$(AIDE):$(TAG))
endif

.PHONY: namespace
namespace:
	@echo "Creating '$(NAMESPACE)' namespace/project"
	@oc create -f deploy/ns.yaml || true

.PHONY: deploy
deploy: namespace deploy-crds ## Deploy the operator from the manifests in the deploy/ directory
	@oc apply -n $(NAMESPACE) -f deploy/

.PHONY: deploy-local
deploy-local: namespace image-to-cluster deploy-crds ## Deploy the operator from the manifests in the deploy/ directory and the images from a local build
	@sed -i 's%$(IMAGE_REPO)/$(APP_NAME):latest%$(RELATED_IMAGE_OPERATOR_PATH)%' deploy/operator.yaml
	@oc apply -n $(NAMESPACE) -f deploy/
	@sed -i 's%$(RELATED_IMAGE_OPERATOR_PATH)%$(IMAGE_REPO)/$(APP_NAME):latest%' deploy/operator.yaml

.PHONY: deploy-crds
deploy-crds:
	@for crd in $(shell ls -1 deploy/crds/*crd.yaml) ; do \
		oc apply -f $$crd ; \
	done

.PHONY: tear-down
tear-down: tear-down-crds tear-down-operator ## Tears down all objects required for the operator except the namespace


.PHONY: tear-down-crds
tear-down-crds:
	@for crd in $(shell ls -1 deploy/crds/*crd.yaml) ; do \
		oc delete --ignore-not-found -f $$crd ; \
	done

.PHONY: tear-down-operator
tear-down-operator:
	@for manifest in $(shell ls -1 deploy/*.yaml | grep -v ns.yaml) ; do \
		oc delete --ignore-not-found -f $$manifest ; \
	done

.PHONY: openshift-user
openshift-user:
ifeq ($(shell oc whoami 2>/dev/null),kube:admin)
	$(eval OPENSHIFT_USER = kubeadmin)
else
	$(eval OPENSHIFT_USER = $(oc whoami))
endif

.PHONY: push
push: image
	$(RUNTIME) push $(RELATED_IMAGE_OPERATOR_PATH):$(TAG)
	$(RUNTIME) push $(RELATED_IMAGE_AIDE_PATH):$(TAG)

.PHONY: publish
publish: csv publish-bundle

.PHONY: check-package-version
check-package-version:
ifndef COURIER_PACKAGE_VERSION
	$(error COURIER_PACKAGE_VERSION must be defined)
endif

.PHONY: csv
csv: deploy/olm-catalog/file-integrity-operator/$(COURIER_PACKAGE_VERSION) check-package-version operator-sdk ## Generate the CSV and packaging for the specific version (NOTE: Gotta specify the version with the COURIER_PACKAGE_VERSION environment variable)

deploy/olm-catalog/file-integrity-operator/$(COURIER_PACKAGE_VERSION):
	$(GOPATH)/bin/operator-sdk generate csv --make-manifests=false --csv-channel $(PACKAGE_CHANNEL) --csv-version "$(COURIER_PACKAGE_VERSION)" --from-version "$(OLD_COURIER_PACKAGE_VERSION)" --update-crds

.PHONY: publish-bundle
publish-bundle: check-package-version
	# If the validation fails, make sure you are running operator-courier
	# 2.1.8, but also make sure the patches from https://github.com/operator-framework/operator-courier/pull/189
	# are included. On Fedora, feel free to use https://copr.fedorainfracloud.org/coprs/jhrozek/python-operator-courier/
	$(COURIER_CMD) push "$(COURIER_OPERATOR_DIR)" "$(COURIER_QUAY_NAMESPACE)" "$(COURIER_PACKAGE_NAME)" "$(COURIER_PACKAGE_VERSION)" "basic $(COURIER_QUAY_TOKEN)"

.PHONY: package-version-to-tag
package-version-to-tag: check-package-version
	@echo "Overriding default tag '$(TAG)' with release tag '$(COURIER_PACKAGE_VERSION)'"
	$(eval TAG = $(COURIER_PACKAGE_VERSION))

.PHONY: release-tag-image
release-tag-image: package-version-to-tag
	@echo "Temporarily overriding image tags in deploy/operator.yaml"
	@sed -i 's%$(IMAGE_REPO)/$(AIDE):latest%$(RELATED_IMAGE_AIDE_PATH):$(TAG)%' deploy/operator.yaml
	@sed -i 's%$(IMAGE_REPO)/$(APP_NAME):latest%$(RELATED_IMAGE_OPERATOR_PATH):$(TAG)%' deploy/operator.yaml

.PHONY: undo-deploy-tag-image
undo-deploy-tag-image: package-version-to-tag
	@echo "Restoring image tags in deploy/operator.yaml"
	@sed -i 's%$(RELATED_IMAGE_AIDE_PATH):$(TAG)%$(IMAGE_REPO)/$(AIDE):latest%' deploy/operator.yaml
	@sed -i 's%$(RELATED_IMAGE_OPERATOR_PATH):$(TAG)%$(IMAGE_REPO)/$(APP_NAME):latest%' deploy/operator.yaml

.PHONY: git-release
git-release: package-version-to-tag
	git checkout -b "release-v$(TAG)"
	git add "deploy/olm-catalog/file-integrity-operator/$(TAG)"
	git add "deploy/olm-catalog/file-integrity-operator/file-integrity-operator.package.yaml"
	git commit -m "Release v$(TAG)"
	git tag "v$(TAG)"
	git push origin "v$(TAG)"
	git push origin "release-v$(TAG)"

.PHONY: release
release: release-tag-image push publish undo-deploy-tag-image git-release ## Do an official release (Requires permissions)
